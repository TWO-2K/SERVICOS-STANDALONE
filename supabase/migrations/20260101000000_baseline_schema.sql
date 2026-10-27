


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";


CREATE SCHEMA IF NOT EXISTS "gestao_crm";


ALTER SCHEMA "gestao_crm" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "gestao_plataforma";


ALTER SCHEMA "gestao_plataforma" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "gestao_servicos";


ALTER SCHEMA "gestao_servicos" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "integracoes";


ALTER SCHEMA "integracoes" OWNER TO "postgres";


CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






CREATE SCHEMA IF NOT EXISTS "notificacoes";


ALTER SCHEMA "notificacoes" OWNER TO "postgres";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "citext" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";


CREATE OR REPLACE FUNCTION "gestao_plataforma"."hook_verificacao_senha"("event" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_usuario_id uuid := (event->>'user_id')::uuid;
  v_valido boolean := (event->>'valid')::boolean;
  v_row gestao_plataforma.bloqueios_login%rowtype;
  v_novas_tentativas integer;
  v_bloqueio_segundos integer;
begin
  select * into v_row from gestao_plataforma.bloqueios_login where usuario_id = v_usuario_id;

  if v_row.bloqueado_ate is not null and v_row.bloqueado_ate > now() then
    -- Conta travada: rejeita mesmo se a senha enviada agora estiver correta.
    return jsonb_build_object(
      'decision', 'reject',
      'message', 'Muitas tentativas de login. Tente novamente em alguns minutos.'
    );
  end if;

  if v_valido then
    insert into gestao_plataforma.bloqueios_login (usuario_id, tentativas_falhas, bloqueado_ate, ultima_falha_em, atualizado_em)
    values (v_usuario_id, 0, null, null, now())
    on conflict (usuario_id) do update
      set tentativas_falhas = 0, bloqueado_ate = null, ultima_falha_em = null, atualizado_em = now();
    return jsonb_build_object('decision', 'continue');
  end if;

  if v_row.usuario_id is null or v_row.ultima_falha_em is null or now() - v_row.ultima_falha_em > interval '30 minutes' then
    v_novas_tentativas := 1;
  else
    v_novas_tentativas := v_row.tentativas_falhas + 1;
  end if;

  v_bloqueio_segundos := case
    when v_novas_tentativas >= 20 then 3600
    when v_novas_tentativas >= 15 then 1800
    when v_novas_tentativas >= 10 then 300
    when v_novas_tentativas >= 5 then 60
    else 0
  end;

  insert into gestao_plataforma.bloqueios_login (usuario_id, tentativas_falhas, bloqueado_ate, ultima_falha_em, atualizado_em)
  values (
    v_usuario_id,
    v_novas_tentativas,
    case when v_bloqueio_segundos > 0 then now() + make_interval(secs => v_bloqueio_segundos) else null end,
    now(),
    now()
  )
  on conflict (usuario_id) do update
    set tentativas_falhas = excluded.tentativas_falhas,
        bloqueado_ate = excluded.bloqueado_ate,
        ultima_falha_em = excluded.ultima_falha_em,
        atualizado_em = now();

  -- Sempre 'continue' numa falha (sem bloqueio novo ainda) -- deixa o GoTrue emitir o erro padrao
  -- de credencial invalida, sem revelar que existe lockout logo na primeira tentativa errada.
  return jsonb_build_object('decision', 'continue');
end;
$$;


ALTER FUNCTION "gestao_plataforma"."hook_verificacao_senha"("event" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "gestao_servicos"."parcelas_pagamento_rollup"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'gestao_servicos'
    AS $$
begin
  if new.status in ('pago', 'cancelado') and not exists (
    select 1
    from gestao_servicos.parcelas_pagamento
    where solicitacao_id = new.solicitacao_id
      and status = 'pendente'
  ) and exists (
    select 1
    from gestao_servicos.parcelas_pagamento
    where solicitacao_id = new.solicitacao_id
      and status = 'pago'
  ) then
    update gestao_servicos.solicitacoes_pagamento
    set status = 'pago', pago_em = now(), pago_por = coalesce(pago_por, new.pago_por)
    where id = new.solicitacao_id
      and status <> 'pago';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "gestao_servicos"."parcelas_pagamento_rollup"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "integracoes"."get_credenciais"("p_chave" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'integracoes', 'vault', 'pg_temp'
    AS $$
declare
  integracao_row integracoes.integracoes%rowtype;
  result jsonb;
  secret_row record;
begin
  select * into integracao_row
  from integracoes.integracoes
  where chave = p_chave
    and ativo = true
  limit 1;

  if not found then
    return null;
  end if;

  result := integracao_row.config;
  if result is null or jsonb_typeof(result) <> 'object' then
    result := '{}'::jsonb;
  end if;

  for secret_row in
    select s.chave, d.decrypted_secret
    from integracoes.integracoes_secrets s
    join vault.decrypted_secrets d on d.id = s.secret_id
    where s.integracao_id = integracao_row.id
  loop
    result := jsonb_set(result, array[secret_row.chave], to_jsonb(secret_row.decrypted_secret));
  end loop;

  return result;
end;
$$;


ALTER FUNCTION "integracoes"."get_credenciais"("p_chave" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "notificacoes"."limpar_notificacoes_antigas"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'notificacoes', 'public'
    AS $$
declare
  deleted_count integer;
begin
  delete from notificacoes.notificacoes
  where (lida_em is not null and criado_em < now() - interval '90 days')
     or (lida_em is null and criado_em < now() - interval '180 days');

  get diagnostics deleted_count = row_count;
  return deleted_count;
end;
$$;


ALTER FUNCTION "notificacoes"."limpar_notificacoes_antigas"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."auto_create_servicos_permissoes"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.ativo and new.sistema_id = (select id from public.sistemas where slug = 'servicos') then
    insert into gestao_servicos.permissoes_modulo (colaborador_id, modulo, papel)
    values (new.colaborador_id, 'financeiro', 'nenhum')
    on conflict (colaborador_id, modulo) do nothing;

    insert into gestao_servicos.permissoes_modulo (colaborador_id, modulo, papel)
    values (new.colaborador_id, 'oficina', 'nenhum')
    on conflict (colaborador_id, modulo) do nothing;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."auto_create_servicos_permissoes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cliente_identidade_access_level"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select aus.nivel_acesso
  from public.acessos_usuario_sistema aus
  join public.sistemas s on s.id = aus.sistema_id
  where aus.colaborador_id = public.current_colaborador_id()
    and aus.ativo = true
    and s.slug in ('crm', 'servicos')
    and s.ativo = true
  order by case aus.nivel_acesso when 'admin' then 0 when 'gestor' then 1 else 2 end
  limit 1;
$$;


ALTER FUNCTION "public"."cliente_identidade_access_level"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cliente_identidade_has_access"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(public.cliente_identidade_access_level() in ('admin', 'gestor', 'usuario'), false);
$$;


ALTER FUNCTION "public"."cliente_identidade_has_access"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."crm_access_level"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select aus.nivel_acesso
  from public.acessos_usuario_sistema aus
  join public.sistemas s on s.id = aus.sistema_id
  where aus.colaborador_id = public.current_colaborador_id()
    and aus.ativo = true
    and s.slug = 'crm'
    and s.ativo = true
  limit 1;
$$;


ALTER FUNCTION "public"."crm_access_level"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."crm_can_manage"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(public.crm_access_level() in ('admin', 'gestor', 'usuario'), false);
$$;


ALTER FUNCTION "public"."crm_can_manage"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."crm_current_colaborador_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select c.id
  from public.colaboradores c
  where c.id = auth.uid()
     or lower(c.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  order by case when c.id = auth.uid() then 0 else 1 end
  limit 1;
$$;


ALTER FUNCTION "public"."crm_current_colaborador_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."crm_current_unidade_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select c.unidade_id
  from public.colaboradores c
  where c.id = public.crm_current_colaborador_id();
$$;


ALTER FUNCTION "public"."crm_current_unidade_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."crm_has_access"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(public.crm_access_level() in ('admin', 'gestor', 'usuario'), false);
$$;


ALTER FUNCTION "public"."crm_has_access"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_colaborador_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select c.id
  from public.colaboradores c
  where c.id = auth.uid()
     or lower(c.email) = lower(auth.email())
  order by case when c.id = auth.uid() then 0 else 1 end
  limit 1;
$$;


ALTER FUNCTION "public"."current_colaborador_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."grant_intranet_access"("p_email" "text", "p_nivel_acesso" "text" DEFAULT 'user'::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_colaborador_id uuid;
  v_sistema_id uuid;
  v_level text;
begin
  v_level := case p_nivel_acesso
    when 'user' then 'usuario'
    when 'manager' then 'gestor'
    else p_nivel_acesso
  end;

  if v_level not in ('admin', 'gestor', 'usuario') then
    raise exception 'Nivel de acesso invalido: %', p_nivel_acesso;
  end if;

  select id
    into v_colaborador_id
  from public.colaboradores
  where lower(email) = lower(trim(p_email))
  limit 1;

  if v_colaborador_id is null then
    raise exception 'Nenhum colaborador encontrado para o e-mail %', p_email;
  end if;

  select id
    into v_sistema_id
  from public.sistemas
  where slug = 'intranet'
  limit 1;

  if v_sistema_id is null then
    raise exception 'Sistema intranet nao encontrado.';
  end if;

  insert into public.acessos_usuario_sistema (
    colaborador_id,
    sistema_id,
    nivel_acesso,
    ativo
  )
  values (
    v_colaborador_id,
    v_sistema_id,
    v_level,
    true
  )
  on conflict (colaborador_id, sistema_id) do update
    set nivel_acesso = excluded.nivel_acesso,
        ativo = true,
        atualizado_em = now();

  return v_colaborador_id;
end;
$$;


ALTER FUNCTION "public"."grant_intranet_access"("p_email" "text", "p_nivel_acesso" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.colaboradores (
    id,
    nome,
    email,
    funcao,
    status
  )
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    new.email,
    coalesce(new.raw_user_meta_data ->> 'funcao', 'usuario'),
    'ativo'
  )
  on conflict (id) do update
  set
    nome = excluded.nome,
    email = excluded.email,
    funcao = excluded.funcao,
    status = coalesce(public.colaboradores.status, 'ativo'),
    atualizado_em = now();

  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_system_access"("system_slug" "text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1
    from public.acessos_usuario_sistema aus
    join public.sistemas s on s.id = aus.sistema_id
    where aus.colaborador_id = public.current_colaborador_id()
      and aus.ativo = true
      and s.ativo = true
      and s.slug = system_slug
  );
$$;


ALTER FUNCTION "public"."has_system_access"("system_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_intranet_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.intranet_is_admin();
$$;


ALTER FUNCTION "public"."is_intranet_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."relatorios_access_level"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select aus.nivel_acesso
  from public.acessos_usuario_sistema aus
  join public.sistemas s on s.id = aus.sistema_id
  where aus.colaborador_id = public.current_colaborador_id()
    and aus.ativo = true
    and s.slug = 'relatorios'
    and s.ativo = true
  limit 1;
$$;


ALTER FUNCTION "public"."relatorios_access_level"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."relatorios_is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.relatorios_access_level() = 'admin';
$$;


ALTER FUNCTION "public"."relatorios_is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."rls_auto_enable"() RETURNS "event_trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."rls_auto_enable"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."servicos_access_level"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select aus.nivel_acesso
  from public.acessos_usuario_sistema aus
  join public.sistemas s on s.id = aus.sistema_id
  where aus.colaborador_id = public.current_colaborador_id()
    and aus.ativo = true
    and s.slug = 'servicos'
    and s.ativo = true
  limit 1;
$$;


ALTER FUNCTION "public"."servicos_access_level"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."servicos_can_access_solicitacao"("p_solicitante_id" "uuid", "p_aprovador_destino_id" "uuid", "p_departamento_id" "uuid", "p_forma_pagamento" "text" DEFAULT NULL::"text", "p_unidade_id" "uuid" DEFAULT NULL::"uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    case
      when p_forma_pagamento = 'dinheiro' and public.servicos_restringe_visibilidade_dinheiro() then
        p_solicitante_id = public.current_colaborador_id()
        or public.servicos_is_financeiro()
        or (
          public.servicos_module_role() = 'aprovador'
          and p_aprovador_destino_id = public.current_colaborador_id()
        )
      else
        public.servicos_is_pagador()
        or p_solicitante_id = public.current_colaborador_id()
        or (
          public.servicos_module_role() = 'aprovador'
          and p_aprovador_destino_id = public.current_colaborador_id()
        )
        or (
          p_departamento_id is not null
          and p_departamento_id = public.servicos_current_department_id()
          and (
            p_unidade_id is null
            or public.servicos_current_unit_id() is null
            or p_unidade_id = public.servicos_current_unit_id()
          )
        )
    end;
$$;


ALTER FUNCTION "public"."servicos_can_access_solicitacao"("p_solicitante_id" "uuid", "p_aprovador_destino_id" "uuid", "p_departamento_id" "uuid", "p_forma_pagamento" "text", "p_unidade_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."servicos_current_department_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select c.departamento_id
  from public.colaboradores c
  where c.id = public.current_colaborador_id()
  limit 1;
$$;


ALTER FUNCTION "public"."servicos_current_department_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."servicos_current_unit_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select c.unidade_id
  from public.colaboradores c
  where c.id = public.current_colaborador_id()
  limit 1;
$$;


ALTER FUNCTION "public"."servicos_current_unit_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."servicos_has_access"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(public.servicos_access_level() in ('admin', 'gestor', 'usuario'), false);
$$;


ALTER FUNCTION "public"."servicos_has_access"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."servicos_is_aprovador"("p_modulo" "text" DEFAULT 'financeiro'::"text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(public.servicos_module_role(p_modulo) in ('financeiro', 'aprovador'), false);
$$;


ALTER FUNCTION "public"."servicos_is_aprovador"("p_modulo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."servicos_is_financeiro"("p_modulo" "text" DEFAULT 'financeiro'::"text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.servicos_module_role(p_modulo) = 'financeiro';
$$;


ALTER FUNCTION "public"."servicos_is_financeiro"("p_modulo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."servicos_is_pagador"("p_modulo" "text" DEFAULT 'financeiro'::"text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(public.servicos_module_role(p_modulo) in ('financeiro', 'contas_a_pagar'), false);
$$;


ALTER FUNCTION "public"."servicos_is_pagador"("p_modulo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."servicos_module_role"("p_modulo" "text" DEFAULT 'financeiro'::"text") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select case
    when public.servicos_access_level() = 'admin' then 'admin'
    when public.servicos_access_level() is null then null
    else coalesce(
      (select pm.papel
       from gestao_servicos.permissoes_modulo pm
       where pm.colaborador_id = public.current_colaborador_id()
         and pm.modulo = p_modulo),
      case when p_modulo = 'oficina' then 'nenhum' else 'usuario' end
    )
  end;
$$;


ALTER FUNCTION "public"."servicos_module_role"("p_modulo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."servicos_oficina_pode_editar"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(public.servicos_module_role('oficina') in ('inspetor', 'gestor', 'admin'), false);
$$;


ALTER FUNCTION "public"."servicos_oficina_pode_editar"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."servicos_oficina_pode_ver"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.servicos_module_role('oficina') is distinct from 'nenhum'
    and public.servicos_module_role('oficina') is not null;
$$;


ALTER FUNCTION "public"."servicos_oficina_pode_ver"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."servicos_restringe_visibilidade_dinheiro"("p_modulo" "text" DEFAULT 'financeiro'::"text") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(
    (select cm.restringir_visibilidade_pagamento_dinheiro
     from gestao_servicos.configuracoes_modulo cm
     where cm.modulo = p_modulo),
    true
  );
$$;


ALTER FUNCTION "public"."servicos_restringe_visibilidade_dinheiro"("p_modulo" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.atualizado_em = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_auth_user_to_colaborador"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_intranet_system_id uuid;
begin
  insert into public.colaboradores (
    id,
    nome,
    email,
    funcao,
    status
  )
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    new.email,
    'usuario',
    'ativo'
  )
  on conflict (id) do update
    set nome = excluded.nome,
        email = excluded.email,
        atualizado_em = now();

  select id
    into v_intranet_system_id
  from public.sistemas
  where slug = 'intranet'
    and ativo = true
  limit 1;

  if v_intranet_system_id is not null then
    insert into public.acessos_usuario_sistema (
      colaborador_id,
      sistema_id,
      nivel_acesso,
      ativo
    )
    values (
      new.id,
      v_intranet_system_id,
      'usuario',
      true
    )
    on conflict (colaborador_id, sistema_id) do update
      set ativo = true,
          atualizado_em = now();
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."sync_auth_user_to_colaborador"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_colaborador_cargo_from_cargo_id"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if new.cargo_id is not null then
    select c.nome
      into new.cargo
    from public.cargos c
    where c.id = new.cargo_id;
  elsif tg_op = 'UPDATE' and old.cargo_id is not null and new.cargo_id is null then
    new.cargo := null;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."sync_colaborador_cargo_from_cargo_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."system_access_level"("system_slug" "text") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select aus.nivel_acesso
  from public.acessos_usuario_sistema aus
  join public.sistemas s on s.id = aus.sistema_id
  where aus.colaborador_id = public.current_colaborador_id()
    and aus.ativo = true
    and s.ativo = true
    and s.slug = system_slug
  limit 1;
$$;


ALTER FUNCTION "public"."system_access_level"("system_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."veiculo_catalogo_access_level"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select aus.nivel_acesso
  from public.acessos_usuario_sistema aus
  join public.sistemas s on s.id = aus.sistema_id
  where aus.colaborador_id = public.current_colaborador_id()
    and aus.ativo = true
    and s.slug in ('crm', 'servicos')
    and s.ativo = true
  order by case aus.nivel_acesso when 'admin' then 0 when 'gestor' then 1 else 2 end
  limit 1;
$$;


ALTER FUNCTION "public"."veiculo_catalogo_access_level"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."veiculo_catalogo_has_access"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(public.veiculo_catalogo_access_level() in ('admin', 'gestor', 'usuario'), false);
$$;


ALTER FUNCTION "public"."veiculo_catalogo_has_access"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "gestao_crm"."clientes_crm" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "empresa" "text" DEFAULT 'Matriz'::"text" NOT NULL,
    "status_relacionamento" "text" DEFAULT 'lead'::"text" NOT NULL,
    "observacoes" "text",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "criado_por" "uuid",
    "unidade_id" "uuid",
    CONSTRAINT "clientes_status_relacionamento_check" CHECK (("status_relacionamento" = ANY (ARRAY['lead'::"text", 'cliente'::"text", 'pos_venda'::"text"])))
);

ALTER TABLE ONLY "gestao_crm"."clientes_crm" REPLICA IDENTITY FULL;


ALTER TABLE "gestao_crm"."clientes_crm" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_crm"."propostas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "lead_id" "uuid" NOT NULL,
    "cliente_id" "uuid" NOT NULL,
    "veiculo_estoque_id" "uuid",
    "veiculo_descricao" "text",
    "valor_veiculo" numeric(12,2) NOT NULL,
    "desconto_valor" numeric(12,2) DEFAULT 0 NOT NULL,
    "valor_final" numeric(12,2) NOT NULL,
    "forma_pagamento" "text" NOT NULL,
    "valor_entrada" numeric(12,2),
    "status" "text" DEFAULT 'rascunho'::"text" NOT NULL,
    "vendedor_id" "uuid",
    "validade_ate" "date",
    "observacoes" "text",
    "criado_por" "uuid",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "aceita_em" timestamp with time zone,
    "recusada_em" timestamp with time zone,
    "eh_teste" boolean DEFAULT false NOT NULL,
    CONSTRAINT "propostas_desconto_valor_check" CHECK (("desconto_valor" >= (0)::numeric)),
    CONSTRAINT "propostas_forma_pagamento_check" CHECK (("forma_pagamento" = ANY (ARRAY['a_vista'::"text", 'financiamento'::"text", 'consorcio'::"text", 'troca'::"text"]))),
    CONSTRAINT "propostas_status_check" CHECK (("status" = ANY (ARRAY['rascunho'::"text", 'enviada'::"text", 'aceita'::"text", 'recusada'::"text"]))),
    CONSTRAINT "propostas_valor_entrada_check" CHECK (("valor_entrada" >= (0)::numeric)),
    CONSTRAINT "propostas_valor_final_check" CHECK (("valor_final" >= (0)::numeric)),
    CONSTRAINT "propostas_valor_veiculo_check" CHECK (("valor_veiculo" >= (0)::numeric)),
    CONSTRAINT "propostas_veiculo_check" CHECK ((("veiculo_estoque_id" IS NOT NULL) OR (NULLIF(TRIM(BOTH FROM COALESCE("veiculo_descricao", ''::"text")), ''::"text") IS NOT NULL)))
);

ALTER TABLE ONLY "gestao_crm"."propostas" REPLICA IDENTITY FULL;


ALTER TABLE "gestao_crm"."propostas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_crm"."veiculos_estoque" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "condicao" "text" DEFAULT 'novo'::"text" NOT NULL,
    "status" "text" DEFAULT 'disponivel'::"text" NOT NULL,
    "preco" numeric(12,2),
    "observacoes" "text",
    "criado_por" "uuid",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "veiculo_id" "uuid" NOT NULL,
    "situacao" "text" DEFAULT 'estoque'::"text" NOT NULL,
    "vendedor_reserva_id" "uuid",
    "cliente_reserva_id" "uuid",
    "reserva_expira_em" timestamp with time zone,
    CONSTRAINT "chk_veiculos_estoque_reserva_consistente" CHECK (((("status" = 'reservado'::"text") AND ("vendedor_reserva_id" IS NOT NULL) AND ("cliente_reserva_id" IS NOT NULL)) OR (("status" <> 'reservado'::"text") AND ("vendedor_reserva_id" IS NULL) AND ("cliente_reserva_id" IS NULL)))),
    CONSTRAINT "veiculos_estoque_condicao_check" CHECK (("condicao" = ANY (ARRAY['novo'::"text", 'seminovo'::"text", 'usado'::"text"]))),
    CONSTRAINT "veiculos_estoque_preco_check" CHECK ((("preco" IS NULL) OR ("preco" >= (0)::numeric))),
    CONSTRAINT "veiculos_estoque_situacao_check" CHECK (("situacao" = ANY (ARRAY['estoque'::"text", 'saida_demonstracao'::"text", 'transito'::"text", 'imobilizado'::"text"]))),
    CONSTRAINT "veiculos_estoque_status_check" CHECK (("status" = ANY (ARRAY['disponivel'::"text", 'reservado'::"text", 'vendido'::"text"])))
);

ALTER TABLE ONLY "gestao_crm"."veiculos_estoque" REPLICA IDENTITY FULL;


ALTER TABLE "gestao_crm"."veiculos_estoque" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_crm"."vendas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "proposta_id" "uuid",
    "lead_id" "uuid" NOT NULL,
    "cliente_id" "uuid" NOT NULL,
    "veiculo_estoque_id" "uuid" NOT NULL,
    "vendedor_id" "uuid" NOT NULL,
    "valor_final" numeric(12,2) NOT NULL,
    "forma_pagamento" "text" NOT NULL,
    "desconto_valor" numeric(12,2) DEFAULT 0 NOT NULL,
    "data_venda" "date" DEFAULT CURRENT_DATE NOT NULL,
    "motivo_status_id" "uuid" NOT NULL,
    "observacoes" "text",
    "criado_por" "uuid",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "text" DEFAULT 'concluida'::"text" NOT NULL,
    "cancelada_em" timestamp with time zone,
    "motivo_cancelamento" "text",
    "cancelada_por" "uuid",
    CONSTRAINT "vendas_desconto_valor_check" CHECK (("desconto_valor" >= (0)::numeric)),
    CONSTRAINT "vendas_forma_pagamento_check" CHECK (("forma_pagamento" = ANY (ARRAY['a_vista'::"text", 'financiamento'::"text", 'consorcio'::"text", 'troca'::"text"]))),
    CONSTRAINT "vendas_status_check" CHECK (("status" = ANY (ARRAY['concluida'::"text", 'cancelada'::"text"]))),
    CONSTRAINT "vendas_valor_final_check" CHECK (("valor_final" >= (0)::numeric))
);

ALTER TABLE ONLY "gestao_crm"."vendas" REPLICA IDENTITY FULL;


ALTER TABLE "gestao_crm"."vendas" OWNER TO "postgres";


COMMENT ON COLUMN "gestao_crm"."vendas"."status" IS 'concluida (padrao) ou cancelada (soft cancel via action cancel_venda). Nunca apagar a linha -- e dado financeiro/auditavel. O indice unico em veiculo_estoque_id so vale para status=concluida (idx_crm_vendas_veiculo_estoque_ativo), permitindo vender o mesmo veiculo de novo apos um cancelamento.';


CREATE TABLE IF NOT EXISTS "gestao_plataforma"."alertas_seguranca_enviados" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tipo" "text" NOT NULL,
    "chave" "text" NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "gestao_plataforma"."alertas_seguranca_enviados" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_plataforma"."bloqueios_login" (
    "usuario_id" "uuid" NOT NULL,
    "tentativas_falhas" integer DEFAULT 0 NOT NULL,
    "bloqueado_ate" timestamp with time zone,
    "ultima_falha_em" timestamp with time zone,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "gestao_plataforma"."bloqueios_login" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_plataforma"."logs_acesso" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "colaborador_id" "uuid",
    "sistema_id" "uuid" NOT NULL,
    "evento" "text" DEFAULT 'login'::"text" NOT NULL,
    "ip_address" "inet",
    "user_agent" "text",
    "metadados" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "gestao_plataforma"."logs_acesso" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_plataforma"."logs_auditoria" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "entidade" "text" NOT NULL,
    "acao" "text" NOT NULL,
    "registro_id" "uuid",
    "responsavel_colaborador_id" "uuid",
    "responsavel_email" "text",
    "antes" "jsonb",
    "depois" "jsonb",
    "metadados" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "gestao_plataforma"."logs_auditoria" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_servicos"."anexos_solicitacao" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "solicitacao_id" "uuid" NOT NULL,
    "parcela_id" "uuid",
    "nome_arquivo" "text" NOT NULL,
    "tipo_mime" "text" NOT NULL,
    "tamanho_bytes" bigint NOT NULL,
    "storage_path" "text" NOT NULL,
    "criado_por" "uuid",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sigiloso" boolean DEFAULT false NOT NULL,
    "assinaturas_necessarias" smallint DEFAULT 1 NOT NULL,
    "tipo_anexo" "text" NOT NULL,
    CONSTRAINT "anexos_solicitacao_assinaturas_necessarias_check" CHECK ((("assinaturas_necessarias" >= 1) AND ("assinaturas_necessarias" <= 2))),
    CONSTRAINT "anexos_solicitacao_tipo_anexo_check" CHECK (("tipo_anexo" = ANY (ARRAY['orcamento'::"text", 'nota_fiscal'::"text", 'boleto'::"text", 'recibo'::"text", 'comprovante_pix'::"text", 'comprovante_pagamento'::"text", 'documento_rh'::"text", 'pdf_unificado'::"text", 'fatura'::"text", 'contrato'::"text", 'comprovante_abastecimento'::"text", 'comprovante_hospedagem'::"text", 'comprovante_passagem'::"text", 'comprovante_pedagio'::"text", 'conta_agua'::"text", 'conta_energia'::"text", 'conta_telefone'::"text", 'folha_comissao'::"text", 'comunicado_interno'::"text", 'proposta'::"text", 'ordem_servico'::"text", 'outros'::"text"])))
);


ALTER TABLE "gestao_servicos"."anexos_solicitacao" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_servicos"."assinaturas_anexo" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "anexo_id" "uuid" NOT NULL,
    "colaborador_id" "uuid" NOT NULL,
    "papel" "text" NOT NULL,
    "posicao" "jsonb" NOT NULL,
    "assinado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "assinaturas_anexo_papel_check" CHECK (("papel" = ANY (ARRAY['solicitante'::"text", 'aprovador'::"text", 'financeiro'::"text"])))
);


ALTER TABLE "gestao_servicos"."assinaturas_anexo" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_servicos"."categorias" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" "text" NOT NULL,
    "ativo" boolean DEFAULT true NOT NULL,
    "criado_por" "uuid",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "gestao_servicos"."categorias" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "gestao_servicos"."checklist_avaliacao_numero_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "gestao_servicos"."checklist_avaliacao_numero_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_servicos"."checklist_avaliacoes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "numero" integer NOT NULL,
    "colaborador_id" "uuid" NOT NULL,
    "cliente_id" "uuid",
    "veiculo_id" "uuid" NOT NULL,
    "os" "text",
    "data" "date" DEFAULT CURRENT_DATE NOT NULL,
    "km" integer,
    "nivel_combustivel" numeric DEFAULT 0.5 NOT NULL,
    "pintura_suja" boolean DEFAULT false NOT NULL,
    "entrega_conferida" boolean DEFAULT false NOT NULL,
    "observacoes" "text",
    "entrega_observacoes" "text",
    "comunicacoes" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "status" "text" DEFAULT 'em_andamento'::"text" NOT NULL,
    "data_entrada" timestamp with time zone DEFAULT "now"() NOT NULL,
    "data_saida" timestamp with time zone,
    "assinatura_entrada" "text",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "assinatura_saida" "text",
    "unidade_id" "uuid" NOT NULL,
    "eh_teste" boolean DEFAULT false NOT NULL,
    "assinatura_entrada_nome" "text",
    "assinatura_entrada_vinculo" "text",
    "assinatura_entrada_detalhe_vinculo" "text",
    "assinatura_saida_nome" "text",
    "assinatura_saida_vinculo" "text",
    "assinatura_saida_detalhe_vinculo" "text",
    CONSTRAINT "checklist_avaliacoes_status_check" CHECK (("status" = ANY (ARRAY['em_andamento'::"text", 'avaliado'::"text", 'finalizado'::"text"])))
);


ALTER TABLE "gestao_servicos"."checklist_avaliacoes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_servicos"."checklist_avarias" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "avaliacao_id" "uuid" NOT NULL,
    "tipo" "text" NOT NULL,
    "pos_x" numeric NOT NULL,
    "pos_y" numeric NOT NULL,
    "area" "text",
    "observacao" "text",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "checklist_avarias_tipo_check" CHECK (("tipo" = ANY (ARRAY['quebrado'::"text", 'amassado'::"text", 'riscado'::"text", 'mancha'::"text"])))
);


ALTER TABLE "gestao_servicos"."checklist_avarias" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_servicos"."checklist_fotos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "avaliacao_id" "uuid" NOT NULL,
    "storage_path" "text" NOT NULL,
    "categoria" "text",
    "legenda" "text",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "avaria_id" "uuid"
);


ALTER TABLE "gestao_servicos"."checklist_fotos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_servicos"."checklist_itens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "avaliacao_id" "uuid" NOT NULL,
    "categoria" "text" NOT NULL,
    "item" "text" NOT NULL,
    "status" "text",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "checklist_itens_categoria_check" CHECK (("categoria" = ANY (ARRAY['documentacao'::"text", 'seguranca'::"text", 'pneus'::"text"])))
);


ALTER TABLE "gestao_servicos"."checklist_itens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_servicos"."configuracoes_modulo" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "modulo" "text" DEFAULT 'financeiro'::"text" NOT NULL,
    "restringir_visibilidade_pagamento_dinheiro" boolean DEFAULT true NOT NULL,
    "atualizado_por" "uuid",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "suprimento_caixa_sem_aprovador" boolean DEFAULT false NOT NULL,
    "suprimento_caixa_auto_aprovar" boolean DEFAULT false NOT NULL,
    "suprimento_caixa_departamentos_permitidos" "uuid"[],
    "restringir_reprovacao_contas_a_pagar" boolean DEFAULT true NOT NULL
);


ALTER TABLE "gestao_servicos"."configuracoes_modulo" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_servicos"."fornecedores" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" "text" NOT NULL,
    "criado_por" "uuid",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ativo" boolean DEFAULT true NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "tipo_pessoa" "text",
    "documento" "text",
    "inscricao_estadual" "text",
    "email" "text",
    "telefone" "text",
    "endereco" "text",
    "cidade" "text",
    "uf" "text",
    "cep" "text",
    "banco" "text",
    "agencia" "text",
    "conta" "text",
    "tipo_conta" "text",
    "chave_pix" "text",
    CONSTRAINT "fornecedores_tipo_pessoa_check" CHECK (("tipo_pessoa" = ANY (ARRAY['fisica'::"text", 'juridica'::"text"])))
);


ALTER TABLE "gestao_servicos"."fornecedores" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_servicos"."historico_checklist" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "checklist_id" "uuid" NOT NULL,
    "evento" "text" NOT NULL,
    "autor_id" "uuid",
    "observacao" "text",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "gestao_servicos"."historico_checklist" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_servicos"."historico_solicitacao" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "solicitacao_id" "uuid" NOT NULL,
    "evento" "text" NOT NULL,
    "autor_id" "uuid",
    "observacao" "text",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "gestao_servicos"."historico_solicitacao" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_servicos"."notificacoes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "colaborador_id" "uuid" NOT NULL,
    "tipo" "text" DEFAULT 'geral'::"text" NOT NULL,
    "titulo" "text" NOT NULL,
    "mensagem" "text",
    "link" "text",
    "referencia_tipo" "text",
    "referencia_id" "uuid",
    "lida_em" timestamp with time zone,
    "criado_por" "uuid",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE ONLY "gestao_servicos"."notificacoes" REPLICA IDENTITY FULL;


ALTER TABLE "gestao_servicos"."notificacoes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_servicos"."parcelas_pagamento" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "solicitacao_id" "uuid" NOT NULL,
    "numero" smallint NOT NULL,
    "valor" numeric(12,2) NOT NULL,
    "data_vencimento" "date",
    "status" "text" DEFAULT 'pendente'::"text" NOT NULL,
    "data_pagamento" timestamp with time zone,
    "pago_por" "uuid",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "parcelas_pagamento_status_check" CHECK (("status" = ANY (ARRAY['pendente'::"text", 'pago'::"text", 'cancelado'::"text"]))),
    CONSTRAINT "parcelas_pagamento_valor_check" CHECK (("valor" > (0)::numeric))
);


ALTER TABLE "gestao_servicos"."parcelas_pagamento" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_servicos"."permissoes_modulo" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "colaborador_id" "uuid" NOT NULL,
    "modulo" "text" NOT NULL,
    "papel" "text" DEFAULT 'usuario'::"text" NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "criado_por" "uuid",
    CONSTRAINT "permissoes_modulo_papel_check" CHECK (("papel" = ANY (ARRAY['nenhum'::"text", 'usuario'::"text", 'aprovador'::"text", 'financeiro'::"text", 'contas_a_pagar'::"text", 'inspetor'::"text", 'gestor'::"text"])))
);


ALTER TABLE "gestao_servicos"."permissoes_modulo" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "gestao_servicos"."solicitacoes_pagamento" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "solicitante_id" "uuid" NOT NULL,
    "fornecedor" "text" NOT NULL,
    "descricao" "text" NOT NULL,
    "valor" numeric(12,2) NOT NULL,
    "categoria" "text" DEFAULT 'outros'::"text" NOT NULL,
    "comprovante_path" "text",
    "status" "text" DEFAULT 'pendente'::"text" NOT NULL,
    "observacao_analise" "text",
    "analisado_por" "uuid",
    "analisado_em" timestamp with time zone,
    "pago_por" "uuid",
    "pago_em" timestamp with time zone,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "criado_por" "uuid",
    "data_vencimento" "date",
    "forma_pagamento" "text" NOT NULL,
    "numero" bigint NOT NULL,
    "titulo" "text" DEFAULT ''::"text" NOT NULL,
    "empresa_id" "uuid",
    "departamento_id" "uuid",
    "observacao" "text",
    "aprovador_destino_id" "uuid",
    "fornecedor_id" "uuid",
    "categoria_id" "uuid" NOT NULL,
    "lembrete_aprovador_em" timestamp with time zone,
    "pendencia_bloqueio" boolean DEFAULT false NOT NULL,
    "pendencia_motivo" "text",
    "pendencia_aberta_por" "uuid",
    "pendencia_aberta_em" timestamp with time zone,
    "pendencia_atualizada_em" timestamp with time zone,
    "eh_teste" boolean DEFAULT false NOT NULL,
    "unidade_id" "uuid",
    "tipo_beneficiario" "text" DEFAULT 'fornecedor'::"text" NOT NULL,
    "colaborador_beneficiario_id" "uuid",
    "possui_nota_fiscal" boolean DEFAULT false NOT NULL,
    CONSTRAINT "chk_servicos_solicitacoes_beneficiario" CHECK (((("tipo_beneficiario" = 'fornecedor'::"text") AND ("fornecedor_id" IS NOT NULL) AND ("colaborador_beneficiario_id" IS NULL)) OR (("tipo_beneficiario" = 'colaborador'::"text") AND ("fornecedor_id" IS NULL)))),
    CONSTRAINT "solicitacoes_pagamento_forma_pagamento_check" CHECK (("forma_pagamento" = ANY (ARRAY['pix'::"text", 'boleto'::"text", 'transferencia'::"text", 'cartao'::"text", 'dinheiro'::"text", 'cheque'::"text", 'arquivo_bancario'::"text", 'deposito_bancario'::"text", 'outros'::"text"]))),
    CONSTRAINT "solicitacoes_pagamento_status_check" CHECK (("status" = ANY (ARRAY['pendente'::"text", 'aprovado'::"text", 'reprovado'::"text", 'pago'::"text", 'cancelado'::"text"]))),
    CONSTRAINT "solicitacoes_pagamento_tipo_beneficiario_check" CHECK (("tipo_beneficiario" = ANY (ARRAY['fornecedor'::"text", 'colaborador'::"text"]))),
    CONSTRAINT "solicitacoes_pagamento_titulo_not_blank" CHECK (("titulo" <> ''::"text")),
    CONSTRAINT "solicitacoes_pagamento_valor_check" CHECK (("valor" > (0)::numeric))
);

ALTER TABLE ONLY "gestao_servicos"."solicitacoes_pagamento" REPLICA IDENTITY FULL;


ALTER TABLE "gestao_servicos"."solicitacoes_pagamento" OWNER TO "postgres";


COMMENT ON COLUMN "gestao_servicos"."solicitacoes_pagamento"."possui_nota_fiscal" IS 'Indica se o solicitante espera anexar nota fiscal para esta solicitacao (pode ser ate a data de pagamento). Usado pelo financeiro para identificar de antemao pagamentos que nao terao NF (reembolso, suprimento de caixa, etc).';



ALTER TABLE "gestao_servicos"."solicitacoes_pagamento" ALTER COLUMN "numero" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "gestao_servicos"."solicitacoes_pagamento_numero_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "integracoes"."integracoes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "chave" "text" NOT NULL,
    "provider" "text" NOT NULL,
    "descricao" "text",
    "ativo" boolean DEFAULT true NOT NULL,
    "config" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_por" "uuid"
);


ALTER TABLE "integracoes"."integracoes" OWNER TO "postgres";


COMMENT ON TABLE "integracoes"."integracoes" IS 'Configuracao generica de integracoes externas. `chave` identifica a instancia (ex.: gmail_notificacoes, google_calendar); `config` guarda apenas campos nao sensiveis. Valores sensiveis ficam em integracoes.integracoes_secrets + Vault.';



COMMENT ON COLUMN "integracoes"."integracoes"."chave" IS 'Identificador estavel usado pelas Edge Functions para buscar a config (ex.: gmail_notificacoes).';



COMMENT ON COLUMN "integracoes"."integracoes"."provider" IS 'Nome do provedor/tipo de integracao (ex.: gmail, google_calendar, whatsapp_api).';



COMMENT ON COLUMN "integracoes"."integracoes"."config" IS 'Campos de configuracao NAO sensiveis (client_id, remetente, escopos, flags). Nunca guardar segredo aqui.';



CREATE TABLE IF NOT EXISTS "integracoes"."integracoes_secrets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "integracao_id" "uuid" NOT NULL,
    "chave" "text" NOT NULL,
    "secret_id" "uuid" NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "integracoes"."integracoes_secrets" OWNER TO "postgres";


COMMENT ON TABLE "integracoes"."integracoes_secrets" IS 'Referencias a valores sensiveis de cada integracao (ex.: client_secret, refresh_token), guardados de fato no Supabase Vault (vault.secrets). Ler via vault.decrypted_secrets.';



COMMENT ON COLUMN "integracoes"."integracoes_secrets"."chave" IS 'Nome do campo sensivel dentro da integracao (ex.: client_secret, refresh_token, api_key).';



CREATE TABLE IF NOT EXISTS "notificacoes"."fila_emails" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tipo" "text" DEFAULT 'termo_posse'::"text" NOT NULL,
    "destinatario" "text" NOT NULL,
    "assunto" "text" NOT NULL,
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "status" "text" DEFAULT 'pendente'::"text" NOT NULL,
    "tentativas" integer DEFAULT 0 NOT NULL,
    "max_tentativas" integer DEFAULT 5 NOT NULL,
    "agendado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "erro" "text",
    "enviado_em" timestamp with time zone,
    "processado_em" timestamp with time zone,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "fila_emails_max_tentativas_check" CHECK (("max_tentativas" >= 1)),
    CONSTRAINT "fila_emails_status_check" CHECK (("status" = ANY (ARRAY['pendente'::"text", 'processando'::"text", 'enviado'::"text", 'erro'::"text", 'cancelado'::"text"]))),
    CONSTRAINT "fila_emails_tentativas_check" CHECK (("tentativas" >= 0))
);


ALTER TABLE "notificacoes"."fila_emails" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "notificacoes"."notificacoes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "sistema" "text" NOT NULL,
    "colaborador_id" "uuid" NOT NULL,
    "tipo" "text" DEFAULT 'geral'::"text" NOT NULL,
    "titulo" "text" NOT NULL,
    "mensagem" "text",
    "link" "text",
    "referencia_tipo" "text",
    "referencia_id" "uuid",
    "lida_em" timestamp with time zone,
    "criado_por" "uuid",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE ONLY "notificacoes"."notificacoes" REPLICA IDENTITY FULL;


ALTER TABLE "notificacoes"."notificacoes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."acessos_usuario_sistema" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "colaborador_id" "uuid" NOT NULL,
    "sistema_id" "uuid" NOT NULL,
    "nivel_acesso" "text" NOT NULL,
    "ativo" boolean DEFAULT true NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "acessos_usuario_sistema_nivel_acesso_check" CHECK (("nivel_acesso" = ANY (ARRAY['admin'::"text", 'gestor'::"text", 'usuario'::"text"])))
);


ALTER TABLE "public"."acessos_usuario_sistema" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."avisos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "sistema_slug" "text" NOT NULL,
    "titulo" "text" NOT NULL,
    "mensagem" "text" NOT NULL,
    "versao" integer DEFAULT 1 NOT NULL,
    "obrigatorio" boolean DEFAULT true NOT NULL,
    "ativo" boolean DEFAULT true NOT NULL,
    "criado_por" "uuid",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "modo_teste" boolean DEFAULT false NOT NULL,
    "requer_atualizacao" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."avisos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."avisos_aceites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "aviso_id" "uuid" NOT NULL,
    "colaborador_id" "uuid" NOT NULL,
    "versao_aceita" integer NOT NULL,
    "aceito_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."avisos_aceites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cargos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" "text" NOT NULL,
    "departamento_id" "uuid",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."cargos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."categorias_veiculo" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" "text" NOT NULL,
    "ativo" boolean DEFAULT true NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "campos_extra" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL
);

ALTER TABLE ONLY "public"."categorias_veiculo" REPLICA IDENTITY FULL;


ALTER TABLE "public"."categorias_veiculo" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."clientes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" "text" NOT NULL,
    "telefone" "text" NOT NULL,
    "telefone_normalizado" "text" NOT NULL,
    "email" "text",
    "email_normalizado" "text",
    "cpf_cnpj" "text",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "cpf_cnpj_normalizado" "text",
    "endereco" "text",
    "bairro" "text",
    "municipio" "text",
    "uf" "text",
    "cep" "text",
    "eh_teste" boolean DEFAULT false NOT NULL,
    "origem_cadastro" "text" DEFAULT 'desconhecida'::"text" NOT NULL,
    CONSTRAINT "clientes_origem_cadastro_check" CHECK (("origem_cadastro" = ANY (ARRAY['crm_lead'::"text", 'crm_manual'::"text", 'servicos_manual'::"text", 'importacao_lote'::"text", 'desconhecida'::"text"])))
);


ALTER TABLE "public"."clientes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."clientes_telefones_adicionais" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "cliente_id" "uuid" NOT NULL,
    "telefone" "text" NOT NULL,
    "telefone_normalizado" "text" NOT NULL,
    "tipo" "text",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."clientes_telefones_adicionais" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."colaboradores" (
    "id" "uuid" NOT NULL,
    "nome" "text" NOT NULL,
    "email" "text",
    "funcao" "text" DEFAULT 'usuario'::"text" NOT NULL,
    "cpf" "text",
    "telefone" "text",
    "departamento_id" "uuid",
    "cargo" "text",
    "data_admissao" "date",
    "status" "text" DEFAULT 'ativo'::"text" NOT NULL,
    "unidade_id" "uuid",
    "criado_em" timestamp with time zone DEFAULT "now"(),
    "atualizado_em" timestamp with time zone DEFAULT "now"(),
    "data_nascimento" "date",
    "cargo_id" "uuid",
    "empresa_id" "uuid",
    "precisa_trocar_senha" boolean DEFAULT false NOT NULL,
    "foto_url" "text",
    "foto_path" "text",
    "assinatura_url" "text",
    "assinatura_path" "text",
    CONSTRAINT "perfis_funcao_check" CHECK (("funcao" = ANY (ARRAY['usuario'::"text", 'admin'::"text", 'gestor'::"text"]))),
    CONSTRAINT "perfis_status_check" CHECK (("status" = ANY (ARRAY['ativo'::"text", 'inativo'::"text", 'afastado'::"text"])))
);


ALTER TABLE "public"."colaboradores" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."comunicados" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "sistema_slug" "text" NOT NULL,
    "tipo" "text" DEFAULT 'geral'::"text" NOT NULL,
    "titulo" "text" NOT NULL,
    "mensagem" "text",
    "foto_path" "text",
    "colaborador_id" "uuid",
    "ativo_de" "date" DEFAULT CURRENT_DATE NOT NULL,
    "ativo_ate" "date" DEFAULT CURRENT_DATE NOT NULL,
    "criado_por" "uuid",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "comunicados_janela_valida" CHECK (("ativo_ate" >= "ativo_de"))
);


ALTER TABLE "public"."comunicados" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."cores_veiculo" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" "text" NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."cores_veiculo" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."departamentos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" "text" NOT NULL,
    "descricao" "text",
    "criado_em" timestamp with time zone DEFAULT "now"(),
    "atualizado_em" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."departamentos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."empresas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" "text" NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "slug" "text" NOT NULL
);


ALTER TABLE "public"."empresas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."marcas_veiculo" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" "text" NOT NULL,
    "ativo" boolean DEFAULT true NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE ONLY "public"."marcas_veiculo" REPLICA IDENTITY FULL;


ALTER TABLE "public"."marcas_veiculo" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."modelos_veiculo" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "marca_id" "uuid" NOT NULL,
    "categoria_veiculo_id" "uuid" NOT NULL,
    "nome" "text" NOT NULL,
    "ativo" boolean DEFAULT true NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ano_inicio" integer,
    "ano_fim" integer,
    CONSTRAINT "modelos_veiculo_ano_check" CHECK ((("ano_fim" IS NULL) OR ("ano_inicio" IS NULL) OR ("ano_fim" >= "ano_inicio")))
);

ALTER TABLE ONLY "public"."modelos_veiculo" REPLICA IDENTITY FULL;


ALTER TABLE "public"."modelos_veiculo" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."push_subscriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "colaborador_id" "uuid" NOT NULL,
    "sistema" "text" NOT NULL,
    "endpoint" "text" NOT NULL,
    "p256dh" "text" NOT NULL,
    "auth" "text" NOT NULL,
    "user_agent" "text",
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "last_seen_em" timestamp with time zone,
    "tipo_dispositivo" "text",
    "sistema_operacional" "text",
    "navegador" "text"
);


ALTER TABLE "public"."push_subscriptions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sistemas" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slug" "text" NOT NULL,
    "nome" "text" NOT NULL,
    "descricao" "text",
    "ativo" boolean DEFAULT true NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sistemas" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."unidades" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "nome" "text" NOT NULL,
    "cidade" "text",
    "ativo" boolean DEFAULT true NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"(),
    "atualizado_em" timestamp with time zone DEFAULT "now"(),
    "endereco" "text",
    "telefone" "text",
    "responsavel" "text",
    "cnpj" "text",
    "empresa_id" "uuid"
);


ALTER TABLE "public"."unidades" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."veiculos" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "modelo_id" "uuid" NOT NULL,
    "versao_id" "uuid",
    "chassi" "text" NOT NULL,
    "placa" "text",
    "km" integer,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "cliente_atual_id" "uuid",
    "cor_id" "uuid",
    "ano" integer,
    "eh_teste" boolean DEFAULT false NOT NULL,
    "origem_cadastro" "text" DEFAULT 'desconhecida'::"text" NOT NULL,
    CONSTRAINT "veiculos_origem_cadastro_check" CHECK (("origem_cadastro" = ANY (ARRAY['crm_lead'::"text", 'crm_manual'::"text", 'servicos_manual'::"text", 'importacao_lote'::"text", 'desconhecida'::"text"])))
);

ALTER TABLE ONLY "public"."veiculos" REPLICA IDENTITY FULL;


ALTER TABLE "public"."veiculos" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."veiculos_proprietarios" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "veiculo_id" "uuid" NOT NULL,
    "cliente_id" "uuid" NOT NULL,
    "desde" timestamp with time zone DEFAULT "now"() NOT NULL,
    "ate" timestamp with time zone
);


ALTER TABLE "public"."veiculos_proprietarios" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."versoes_veiculo" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "modelo_id" "uuid" NOT NULL,
    "nome" "text" NOT NULL,
    "ativo" boolean DEFAULT true NOT NULL,
    "criado_em" timestamp with time zone DEFAULT "now"() NOT NULL,
    "atualizado_em" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE ONLY "public"."versoes_veiculo" REPLICA IDENTITY FULL;


ALTER TABLE "public"."versoes_veiculo" OWNER TO "postgres";



ALTER TABLE ONLY "gestao_crm"."clientes_crm"
    ADD CONSTRAINT "clientes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_crm"."propostas"
    ADD CONSTRAINT "propostas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_crm"."veiculos_estoque"
    ADD CONSTRAINT "veiculos_estoque_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_crm"."veiculos_estoque"
    ADD CONSTRAINT "veiculos_estoque_veiculo_id_key" UNIQUE ("veiculo_id");



ALTER TABLE ONLY "gestao_crm"."vendas"
    ADD CONSTRAINT "vendas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_plataforma"."alertas_seguranca_enviados"
    ADD CONSTRAINT "alertas_seguranca_enviados_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_plataforma"."bloqueios_login"
    ADD CONSTRAINT "bloqueios_login_pkey" PRIMARY KEY ("usuario_id");



ALTER TABLE ONLY "gestao_plataforma"."logs_acesso"
    ADD CONSTRAINT "logs_acesso_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_plataforma"."logs_auditoria"
    ADD CONSTRAINT "logs_auditoria_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_servicos"."anexos_solicitacao"
    ADD CONSTRAINT "anexos_solicitacao_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_servicos"."assinaturas_anexo"
    ADD CONSTRAINT "assinaturas_anexo_anexo_id_colaborador_id_key" UNIQUE ("anexo_id", "colaborador_id");



ALTER TABLE ONLY "gestao_servicos"."assinaturas_anexo"
    ADD CONSTRAINT "assinaturas_anexo_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_servicos"."categorias"
    ADD CONSTRAINT "categorias_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_servicos"."checklist_avaliacoes"
    ADD CONSTRAINT "checklist_avaliacoes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_servicos"."checklist_avaliacoes"
    ADD CONSTRAINT "checklist_avaliacoes_unidade_numero_unique" UNIQUE ("unidade_id", "numero");



ALTER TABLE ONLY "gestao_servicos"."checklist_avarias"
    ADD CONSTRAINT "checklist_avarias_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_servicos"."checklist_fotos"
    ADD CONSTRAINT "checklist_fotos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_servicos"."checklist_fotos"
    ADD CONSTRAINT "checklist_fotos_storage_path_key" UNIQUE ("storage_path");



ALTER TABLE ONLY "gestao_servicos"."checklist_itens"
    ADD CONSTRAINT "checklist_itens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_servicos"."configuracoes_modulo"
    ADD CONSTRAINT "configuracoes_modulo_modulo_unico" UNIQUE ("modulo");



ALTER TABLE ONLY "gestao_servicos"."configuracoes_modulo"
    ADD CONSTRAINT "configuracoes_modulo_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_servicos"."fornecedores"
    ADD CONSTRAINT "fornecedores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_servicos"."historico_checklist"
    ADD CONSTRAINT "historico_checklist_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_servicos"."historico_solicitacao"
    ADD CONSTRAINT "historico_solicitacao_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_servicos"."notificacoes"
    ADD CONSTRAINT "notificacoes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_servicos"."parcelas_pagamento"
    ADD CONSTRAINT "parcelas_pagamento_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_servicos"."parcelas_pagamento"
    ADD CONSTRAINT "parcelas_pagamento_solicitacao_id_numero_key" UNIQUE ("solicitacao_id", "numero");



ALTER TABLE ONLY "gestao_servicos"."permissoes_modulo"
    ADD CONSTRAINT "permissoes_modulo_colaborador_id_modulo_key" UNIQUE ("colaborador_id", "modulo");



ALTER TABLE ONLY "gestao_servicos"."permissoes_modulo"
    ADD CONSTRAINT "permissoes_modulo_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "gestao_servicos"."solicitacoes_pagamento"
    ADD CONSTRAINT "solicitacoes_pagamento_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "integracoes"."integracoes"
    ADD CONSTRAINT "integracoes_chave_key" UNIQUE ("chave");



ALTER TABLE ONLY "integracoes"."integracoes"
    ADD CONSTRAINT "integracoes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "integracoes"."integracoes_secrets"
    ADD CONSTRAINT "integracoes_secrets_integracao_id_chave_key" UNIQUE ("integracao_id", "chave");



ALTER TABLE ONLY "integracoes"."integracoes_secrets"
    ADD CONSTRAINT "integracoes_secrets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "notificacoes"."fila_emails"
    ADD CONSTRAINT "fila_emails_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "notificacoes"."notificacoes"
    ADD CONSTRAINT "notificacoes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."acessos_usuario_sistema"
    ADD CONSTRAINT "acessos_usuario_sistema_colaborador_sistema_unique" UNIQUE ("colaborador_id", "sistema_id");



ALTER TABLE ONLY "public"."acessos_usuario_sistema"
    ADD CONSTRAINT "acessos_usuario_sistema_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."avisos_aceites"
    ADD CONSTRAINT "avisos_aceites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."avisos_aceites"
    ADD CONSTRAINT "avisos_aceites_unique" UNIQUE ("aviso_id", "colaborador_id");



ALTER TABLE ONLY "public"."avisos"
    ADD CONSTRAINT "avisos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cargos"
    ADD CONSTRAINT "cargos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."categorias_veiculo"
    ADD CONSTRAINT "categorias_veiculo_nome_key" UNIQUE ("nome");



ALTER TABLE ONLY "public"."categorias_veiculo"
    ADD CONSTRAINT "categorias_veiculo_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clientes"
    ADD CONSTRAINT "clientes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clientes_telefones_adicionais"
    ADD CONSTRAINT "clientes_telefones_adicionais_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."colaboradores"
    ADD CONSTRAINT "colaboradores_cpf_key" UNIQUE ("cpf");



ALTER TABLE ONLY "public"."colaboradores"
    ADD CONSTRAINT "colaboradores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."colaboradores"
    ADD CONSTRAINT "colaboradores_telefone_key" UNIQUE ("telefone");



ALTER TABLE ONLY "public"."comunicados"
    ADD CONSTRAINT "comunicados_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."cores_veiculo"
    ADD CONSTRAINT "cores_veiculo_nome_key" UNIQUE ("nome");



ALTER TABLE ONLY "public"."cores_veiculo"
    ADD CONSTRAINT "cores_veiculo_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."departamentos"
    ADD CONSTRAINT "departamentos_nome_key" UNIQUE ("nome");



ALTER TABLE ONLY "public"."departamentos"
    ADD CONSTRAINT "departamentos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."empresas"
    ADD CONSTRAINT "empresas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."marcas_veiculo"
    ADD CONSTRAINT "marcas_veiculo_nome_key" UNIQUE ("nome");



ALTER TABLE ONLY "public"."marcas_veiculo"
    ADD CONSTRAINT "marcas_veiculo_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."modelos_veiculo"
    ADD CONSTRAINT "modelos_veiculo_marca_id_categoria_veiculo_id_nome_key" UNIQUE ("marca_id", "categoria_veiculo_id", "nome");



ALTER TABLE ONLY "public"."modelos_veiculo"
    ADD CONSTRAINT "modelos_veiculo_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."push_subscriptions"
    ADD CONSTRAINT "push_subscriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."push_subscriptions"
    ADD CONSTRAINT "push_subscriptions_sistema_endpoint_key" UNIQUE ("sistema", "endpoint");



ALTER TABLE ONLY "public"."sistemas"
    ADD CONSTRAINT "sistemas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sistemas"
    ADD CONSTRAINT "sistemas_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."unidades"
    ADD CONSTRAINT "unidades_nome_key" UNIQUE ("nome");



ALTER TABLE ONLY "public"."unidades"
    ADD CONSTRAINT "unidades_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."veiculos"
    ADD CONSTRAINT "veiculos_chassi_key" UNIQUE ("chassi");



ALTER TABLE ONLY "public"."veiculos"
    ADD CONSTRAINT "veiculos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."veiculos_proprietarios"
    ADD CONSTRAINT "veiculos_proprietarios_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."versoes_veiculo"
    ADD CONSTRAINT "versoes_veiculo_modelo_id_nome_key" UNIQUE ("modelo_id", "nome");



ALTER TABLE ONLY "public"."versoes_veiculo"
    ADD CONSTRAINT "versoes_veiculo_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_crm_clientes_atualizado_em" ON "gestao_crm"."clientes_crm" USING "btree" ("atualizado_em" DESC);



CREATE INDEX "idx_crm_clientes_criado_em" ON "gestao_crm"."clientes_crm" USING "btree" ("criado_em" DESC);



CREATE INDEX "idx_crm_clientes_crm_criado_por" ON "gestao_crm"."clientes_crm" USING "btree" ("criado_por");



CREATE INDEX "idx_crm_clientes_empresa" ON "gestao_crm"."clientes_crm" USING "btree" ("empresa");



CREATE INDEX "idx_crm_clientes_empresa_criado_em" ON "gestao_crm"."clientes_crm" USING "btree" ("empresa", "criado_em" DESC);



CREATE INDEX "idx_crm_clientes_status_relacionamento" ON "gestao_crm"."clientes_crm" USING "btree" ("status_relacionamento");



CREATE INDEX "idx_crm_clientes_unidade_id" ON "gestao_crm"."clientes_crm" USING "btree" ("unidade_id");



CREATE INDEX "idx_crm_propostas_cliente_id" ON "gestao_crm"."propostas" USING "btree" ("cliente_id");



CREATE UNIQUE INDEX "idx_crm_propostas_cliente_veiculo_descricao_ativa_unique" ON "gestao_crm"."propostas" USING "btree" ("cliente_id", "lower"(TRIM(BOTH FROM "veiculo_descricao"))) WHERE (("status" = ANY (ARRAY['rascunho'::"text", 'enviada'::"text"])) AND ("veiculo_estoque_id" IS NULL) AND (NULLIF(TRIM(BOTH FROM COALESCE("veiculo_descricao", ''::"text")), ''::"text") IS NOT NULL));



CREATE UNIQUE INDEX "idx_crm_propostas_cliente_veiculo_estoque_ativa_unique" ON "gestao_crm"."propostas" USING "btree" ("cliente_id", "veiculo_estoque_id") WHERE (("status" = ANY (ARRAY['rascunho'::"text", 'enviada'::"text"])) AND ("veiculo_estoque_id" IS NOT NULL));



CREATE INDEX "idx_crm_propostas_lead_id" ON "gestao_crm"."propostas" USING "btree" ("lead_id");



CREATE INDEX "idx_crm_propostas_status" ON "gestao_crm"."propostas" USING "btree" ("status");



CREATE INDEX "idx_crm_propostas_vendedor_id" ON "gestao_crm"."propostas" USING "btree" ("vendedor_id");



CREATE INDEX "idx_crm_veiculos_estoque_cliente_reserva_id" ON "gestao_crm"."veiculos_estoque" USING "btree" ("cliente_reserva_id");



CREATE INDEX "idx_crm_veiculos_estoque_situacao" ON "gestao_crm"."veiculos_estoque" USING "btree" ("situacao");



CREATE INDEX "idx_crm_veiculos_estoque_status" ON "gestao_crm"."veiculos_estoque" USING "btree" ("status");



CREATE INDEX "idx_crm_veiculos_estoque_veiculo_id" ON "gestao_crm"."veiculos_estoque" USING "btree" ("veiculo_id");



CREATE INDEX "idx_crm_veiculos_estoque_vendedor_reserva_id" ON "gestao_crm"."veiculos_estoque" USING "btree" ("vendedor_reserva_id");



CREATE INDEX "idx_crm_vendas_cliente_id" ON "gestao_crm"."vendas" USING "btree" ("cliente_id");



CREATE INDEX "idx_crm_vendas_lead_id" ON "gestao_crm"."vendas" USING "btree" ("lead_id");



CREATE INDEX "idx_crm_vendas_proposta_id" ON "gestao_crm"."vendas" USING "btree" ("proposta_id");



CREATE UNIQUE INDEX "idx_crm_vendas_veiculo_estoque_ativo" ON "gestao_crm"."vendas" USING "btree" ("veiculo_estoque_id") WHERE ("status" = 'concluida'::"text");



CREATE INDEX "idx_crm_vendas_vendedor_id" ON "gestao_crm"."vendas" USING "btree" ("vendedor_id");



CREATE INDEX "alertas_seguranca_enviados_tipo_chave_criado_em_idx" ON "gestao_plataforma"."alertas_seguranca_enviados" USING "btree" ("tipo", "chave", "criado_em" DESC);



CREATE INDEX "logs_acesso_plataforma_colaborador_id_idx" ON "gestao_plataforma"."logs_acesso" USING "btree" ("colaborador_id");



CREATE INDEX "logs_acesso_plataforma_criado_em_idx" ON "gestao_plataforma"."logs_acesso" USING "btree" ("criado_em" DESC);



CREATE INDEX "logs_acesso_plataforma_evento_criado_em_idx" ON "gestao_plataforma"."logs_acesso" USING "btree" ("evento", "criado_em" DESC);



CREATE INDEX "logs_acesso_plataforma_evento_email_idx" ON "gestao_plataforma"."logs_acesso" USING "btree" ("evento", "lower"(("metadados" ->> 'email'::"text")), "criado_em" DESC);



CREATE INDEX "logs_acesso_plataforma_ip_address_idx" ON "gestao_plataforma"."logs_acesso" USING "btree" ("ip_address");



CREATE INDEX "logs_acesso_plataforma_sistema_id_idx" ON "gestao_plataforma"."logs_acesso" USING "btree" ("sistema_id");



CREATE INDEX "logs_auditoria_plataforma_acao_idx" ON "gestao_plataforma"."logs_auditoria" USING "btree" ("acao");



CREATE INDEX "logs_auditoria_plataforma_criado_em_idx" ON "gestao_plataforma"."logs_auditoria" USING "btree" ("criado_em" DESC);



CREATE INDEX "logs_auditoria_plataforma_entidade_idx" ON "gestao_plataforma"."logs_auditoria" USING "btree" ("entidade");



CREATE INDEX "logs_auditoria_plataforma_registro_id_idx" ON "gestao_plataforma"."logs_auditoria" USING "btree" ("registro_id");



CREATE INDEX "logs_auditoria_plataforma_responsavel_colaborador_id_idx" ON "gestao_plataforma"."logs_auditoria" USING "btree" ("responsavel_colaborador_id");



CREATE INDEX "idx_checklist_avaliacoes_cliente_id" ON "gestao_servicos"."checklist_avaliacoes" USING "btree" ("cliente_id");



CREATE INDEX "idx_checklist_avaliacoes_colaborador_id" ON "gestao_servicos"."checklist_avaliacoes" USING "btree" ("colaborador_id");



CREATE INDEX "idx_checklist_avaliacoes_data_entrada" ON "gestao_servicos"."checklist_avaliacoes" USING "btree" ("data_entrada" DESC);



CREATE INDEX "idx_checklist_avaliacoes_status" ON "gestao_servicos"."checklist_avaliacoes" USING "btree" ("status");



CREATE INDEX "idx_checklist_avaliacoes_unidade_id" ON "gestao_servicos"."checklist_avaliacoes" USING "btree" ("unidade_id");



CREATE INDEX "idx_checklist_avaliacoes_veiculo_id" ON "gestao_servicos"."checklist_avaliacoes" USING "btree" ("veiculo_id");



CREATE INDEX "idx_checklist_avarias_avaliacao_id" ON "gestao_servicos"."checklist_avarias" USING "btree" ("avaliacao_id");



CREATE INDEX "idx_checklist_fotos_avaliacao_id" ON "gestao_servicos"."checklist_fotos" USING "btree" ("avaliacao_id");



CREATE INDEX "idx_checklist_fotos_avaria_id" ON "gestao_servicos"."checklist_fotos" USING "btree" ("avaria_id");



CREATE INDEX "idx_checklist_itens_avaliacao_id" ON "gestao_servicos"."checklist_itens" USING "btree" ("avaliacao_id");



CREATE INDEX "idx_pagamentos_solicitacoes_criado_em" ON "gestao_servicos"."solicitacoes_pagamento" USING "btree" ("criado_em" DESC);



CREATE INDEX "idx_pagamentos_solicitacoes_solicitante_id" ON "gestao_servicos"."solicitacoes_pagamento" USING "btree" ("solicitante_id");



CREATE INDEX "idx_pagamentos_solicitacoes_status" ON "gestao_servicos"."solicitacoes_pagamento" USING "btree" ("status");



CREATE INDEX "idx_pagamentos_solicitacoes_vencimento" ON "gestao_servicos"."solicitacoes_pagamento" USING "btree" ("data_vencimento");



CREATE INDEX "idx_servicos_anexos_parcela_id" ON "gestao_servicos"."anexos_solicitacao" USING "btree" ("parcela_id");



CREATE INDEX "idx_servicos_anexos_solicitacao_id" ON "gestao_servicos"."anexos_solicitacao" USING "btree" ("solicitacao_id");



CREATE INDEX "idx_servicos_assinaturas_anexo_anexo_id" ON "gestao_servicos"."assinaturas_anexo" USING "btree" ("anexo_id");



CREATE UNIQUE INDEX "idx_servicos_categorias_nome" ON "gestao_servicos"."categorias" USING "btree" ("lower"("nome"));



CREATE UNIQUE INDEX "idx_servicos_fornecedores_documento" ON "gestao_servicos"."fornecedores" USING "btree" ("documento") WHERE (("documento" IS NOT NULL) AND ("documento" <> ''::"text"));



CREATE UNIQUE INDEX "idx_servicos_fornecedores_nome" ON "gestao_servicos"."fornecedores" USING "btree" ("lower"("nome"));



CREATE INDEX "idx_servicos_historico_checklist_id" ON "gestao_servicos"."historico_checklist" USING "btree" ("checklist_id", "criado_em" DESC);



CREATE INDEX "idx_servicos_historico_solicitacao_id" ON "gestao_servicos"."historico_solicitacao" USING "btree" ("solicitacao_id", "criado_em" DESC);



CREATE INDEX "idx_servicos_notificacoes_colaborador_criado" ON "gestao_servicos"."notificacoes" USING "btree" ("colaborador_id", "criado_em" DESC);



CREATE INDEX "idx_servicos_notificacoes_colaborador_lida" ON "gestao_servicos"."notificacoes" USING "btree" ("colaborador_id", "lida_em");



CREATE INDEX "idx_servicos_parcelas_solicitacao_id" ON "gestao_servicos"."parcelas_pagamento" USING "btree" ("solicitacao_id");



CREATE INDEX "idx_servicos_solicitacoes_categoria_id" ON "gestao_servicos"."solicitacoes_pagamento" USING "btree" ("categoria_id");



CREATE INDEX "idx_servicos_solicitacoes_colaborador_beneficiario_id" ON "gestao_servicos"."solicitacoes_pagamento" USING "btree" ("colaborador_beneficiario_id");



CREATE INDEX "idx_servicos_solicitacoes_fornecedor_id" ON "gestao_servicos"."solicitacoes_pagamento" USING "btree" ("fornecedor_id");



CREATE UNIQUE INDEX "idx_servicos_solicitacoes_numero" ON "gestao_servicos"."solicitacoes_pagamento" USING "btree" ("numero");



CREATE INDEX "idx_servicos_solicitacoes_unidade_id" ON "gestao_servicos"."solicitacoes_pagamento" USING "btree" ("unidade_id");



CREATE INDEX "integracoes_integracoes_secrets_integracao_id_idx" ON "integracoes"."integracoes_secrets" USING "btree" ("integracao_id");



CREATE INDEX "idx_notificacoes_fila_emails_agendado_em" ON "notificacoes"."fila_emails" USING "btree" ("agendado_em");



CREATE INDEX "idx_notificacoes_fila_emails_criado_em" ON "notificacoes"."fila_emails" USING "btree" ("criado_em" DESC);



CREATE INDEX "idx_notificacoes_fila_emails_destinatario" ON "notificacoes"."fila_emails" USING "btree" ("destinatario");



CREATE INDEX "idx_notificacoes_fila_emails_status" ON "notificacoes"."fila_emails" USING "btree" ("status");



CREATE INDEX "idx_notificacoes_fila_emails_tipo" ON "notificacoes"."fila_emails" USING "btree" ("tipo");



CREATE INDEX "idx_notificacoes_notificacoes_colaborador_sistema_criado" ON "notificacoes"."notificacoes" USING "btree" ("colaborador_id", "sistema", "criado_em" DESC);



CREATE INDEX "idx_notificacoes_notificacoes_criado_por" ON "notificacoes"."notificacoes" USING "btree" ("criado_por");



CREATE INDEX "idx_notificacoes_notificacoes_nao_lidas" ON "notificacoes"."notificacoes" USING "btree" ("colaborador_id", "sistema") WHERE ("lida_em" IS NULL);



CREATE UNIQUE INDEX "avisos_one_active_per_sistema_idx" ON "public"."avisos" USING "btree" ("sistema_slug") WHERE ("ativo" = true);



CREATE UNIQUE INDEX "cargos_nome_departamento_unique" ON "public"."cargos" USING "btree" ("lower"("nome"), "departamento_id") WHERE ("departamento_id" IS NOT NULL);



CREATE UNIQUE INDEX "cargos_nome_sem_departamento_unique" ON "public"."cargos" USING "btree" ("lower"("nome")) WHERE ("departamento_id" IS NULL);



CREATE UNIQUE INDEX "colaboradores_email_unique_idx" ON "public"."colaboradores" USING "btree" ("lower"(NULLIF("btrim"("email"), ''::"text"))) WHERE (NULLIF("btrim"("email"), ''::"text") IS NOT NULL);



CREATE UNIQUE INDEX "colaboradores_telefone_unique_idx" ON "public"."colaboradores" USING "btree" ("telefone") WHERE ("telefone" IS NOT NULL);



CREATE UNIQUE INDEX "empresas_nome_unique" ON "public"."empresas" USING "btree" ("lower"("nome"));



CREATE UNIQUE INDEX "empresas_slug_unique" ON "public"."empresas" USING "btree" ("slug");



CREATE INDEX "idx_acessos_usuario_sistema_ativo" ON "public"."acessos_usuario_sistema" USING "btree" ("ativo");



CREATE INDEX "idx_acessos_usuario_sistema_colaborador_id" ON "public"."acessos_usuario_sistema" USING "btree" ("colaborador_id");



CREATE INDEX "idx_acessos_usuario_sistema_sistema_id" ON "public"."acessos_usuario_sistema" USING "btree" ("sistema_id");



CREATE INDEX "idx_avisos_aceites_colaborador_id" ON "public"."avisos_aceites" USING "btree" ("colaborador_id");



CREATE INDEX "idx_cargos_departamento_id" ON "public"."cargos" USING "btree" ("departamento_id");



CREATE INDEX "idx_cargos_nome" ON "public"."cargos" USING "btree" ("nome");



CREATE INDEX "idx_clientes_cpf_cnpj_trgm" ON "public"."clientes" USING "gin" ("cpf_cnpj" "public"."gin_trgm_ops");



CREATE UNIQUE INDEX "idx_clientes_cpf_cnpj_unique" ON "public"."clientes" USING "btree" ("cpf_cnpj_normalizado") WHERE (("cpf_cnpj_normalizado" IS NOT NULL) AND ("cpf_cnpj_normalizado" <> ''::"text"));



CREATE UNIQUE INDEX "idx_clientes_email_unique" ON "public"."clientes" USING "btree" ("email_normalizado") WHERE (("email_normalizado" IS NOT NULL) AND ("email_normalizado" <> ''::"text"));



CREATE INDEX "idx_clientes_nome_trgm" ON "public"."clientes" USING "gin" ("lower"("nome") "public"."gin_trgm_ops");



CREATE UNIQUE INDEX "idx_clientes_telefone_unique" ON "public"."clientes" USING "btree" ("telefone_normalizado");



CREATE INDEX "idx_clientes_telefones_adicionais_cliente_id" ON "public"."clientes_telefones_adicionais" USING "btree" ("cliente_id");



CREATE UNIQUE INDEX "idx_clientes_telefones_adicionais_normalizado_unique" ON "public"."clientes_telefones_adicionais" USING "btree" ("telefone_normalizado");



CREATE INDEX "idx_colaboradores_cargo_id" ON "public"."colaboradores" USING "btree" ("cargo_id");



CREATE INDEX "idx_colaboradores_empresa_id" ON "public"."colaboradores" USING "btree" ("empresa_id");



CREATE INDEX "idx_comunicados_sistema_slug_janela" ON "public"."comunicados" USING "btree" ("sistema_slug", "ativo_de", "ativo_ate");



CREATE INDEX "idx_crm_modelos_veiculo_categoria_veiculo_id" ON "public"."modelos_veiculo" USING "btree" ("categoria_veiculo_id");



CREATE INDEX "idx_crm_modelos_veiculo_marca_id" ON "public"."modelos_veiculo" USING "btree" ("marca_id");



CREATE INDEX "idx_crm_versoes_veiculo_modelo_id" ON "public"."versoes_veiculo" USING "btree" ("modelo_id");



CREATE INDEX "idx_push_subscriptions_colaborador_sistema" ON "public"."push_subscriptions" USING "btree" ("colaborador_id", "sistema");



CREATE INDEX "idx_sistemas_ativo" ON "public"."sistemas" USING "btree" ("ativo");



CREATE INDEX "idx_sistemas_slug" ON "public"."sistemas" USING "btree" ("slug");



CREATE INDEX "idx_unidades_empresa_id" ON "public"."unidades" USING "btree" ("empresa_id");



CREATE INDEX "idx_veiculos_chassi_trgm" ON "public"."veiculos" USING "gin" ("lower"("chassi") "public"."gin_trgm_ops");



CREATE INDEX "idx_veiculos_cor_id" ON "public"."veiculos" USING "btree" ("cor_id");



CREATE INDEX "idx_veiculos_modelo_id" ON "public"."veiculos" USING "btree" ("modelo_id");



CREATE INDEX "idx_veiculos_placa_trgm" ON "public"."veiculos" USING "gin" ("lower"("placa") "public"."gin_trgm_ops");



CREATE UNIQUE INDEX "idx_veiculos_placa_unique" ON "public"."veiculos" USING "btree" ("placa") WHERE (("placa" IS NOT NULL) AND ("placa" <> ''::"text"));



CREATE UNIQUE INDEX "idx_veiculos_proprietarios_atual" ON "public"."veiculos_proprietarios" USING "btree" ("veiculo_id") WHERE ("ate" IS NULL);



CREATE INDEX "idx_veiculos_proprietarios_veiculo_id" ON "public"."veiculos_proprietarios" USING "btree" ("veiculo_id");



CREATE INDEX "idx_veiculos_versao_id" ON "public"."veiculos" USING "btree" ("versao_id");



CREATE OR REPLACE TRIGGER "trg_crm_clientes_set_updated_at" BEFORE UPDATE ON "gestao_crm"."clientes_crm" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_crm_propostas_set_updated_at" BEFORE UPDATE ON "gestao_crm"."propostas" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_crm_veiculos_estoque_set_updated_at" BEFORE UPDATE ON "gestao_crm"."veiculos_estoque" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_crm_vendas_set_updated_at" BEFORE UPDATE ON "gestao_crm"."vendas" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_checklist_avaliacoes_set_updated_at" BEFORE UPDATE ON "gestao_servicos"."checklist_avaliacoes" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_pagamentos_solicitacoes_set_updated_at" BEFORE UPDATE ON "gestao_servicos"."solicitacoes_pagamento" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_servicos_parcelas_rollup" AFTER UPDATE OF "status" ON "gestao_servicos"."parcelas_pagamento" FOR EACH ROW WHEN (("new"."status" = ANY (ARRAY['pago'::"text", 'cancelado'::"text"]))) EXECUTE FUNCTION "gestao_servicos"."parcelas_pagamento_rollup"();



CREATE OR REPLACE TRIGGER "trg_servicos_permissoes_modulo_set_updated_at" BEFORE UPDATE ON "gestao_servicos"."permissoes_modulo" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_auto_create_servicos_permissoes" AFTER INSERT OR UPDATE ON "public"."acessos_usuario_sistema" FOR EACH ROW EXECUTE FUNCTION "public"."auto_create_servicos_permissoes"();



CREATE OR REPLACE TRIGGER "trg_avisos_set_updated_at" BEFORE UPDATE ON "public"."avisos" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_cargos_set_updated_at" BEFORE UPDATE ON "public"."cargos" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_clientes_set_updated_at" BEFORE UPDATE ON "public"."clientes" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_colaboradores_sync_cargo_id" BEFORE INSERT OR UPDATE OF "cargo_id" ON "public"."colaboradores" FOR EACH ROW EXECUTE FUNCTION "public"."sync_colaborador_cargo_from_cargo_id"();



CREATE OR REPLACE TRIGGER "trg_comunicados_set_updated_at" BEFORE UPDATE ON "public"."comunicados" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_crm_categorias_veiculo_set_updated_at" BEFORE UPDATE ON "public"."categorias_veiculo" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_crm_marcas_veiculo_set_updated_at" BEFORE UPDATE ON "public"."marcas_veiculo" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_crm_modelos_veiculo_set_updated_at" BEFORE UPDATE ON "public"."modelos_veiculo" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_crm_versoes_veiculo_set_updated_at" BEFORE UPDATE ON "public"."versoes_veiculo" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_empresas_set_updated_at" BEFORE UPDATE ON "public"."empresas" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_veiculos_set_updated_at" BEFORE UPDATE ON "public"."veiculos" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



ALTER TABLE ONLY "gestao_crm"."clientes_crm"
    ADD CONSTRAINT "clientes_criado_por_fkey" FOREIGN KEY ("criado_por") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_crm"."clientes_crm"
    ADD CONSTRAINT "clientes_crm_unidade_id_fkey" FOREIGN KEY ("unidade_id") REFERENCES "public"."unidades"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "gestao_crm"."clientes_crm"
    ADD CONSTRAINT "clientes_id_fkey" FOREIGN KEY ("id") REFERENCES "public"."clientes"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "gestao_crm"."propostas"
    ADD CONSTRAINT "propostas_cliente_id_fkey" FOREIGN KEY ("cliente_id") REFERENCES "gestao_crm"."clientes_crm"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "gestao_crm"."propostas"
    ADD CONSTRAINT "propostas_criado_por_fkey" FOREIGN KEY ("criado_por") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_crm"."propostas"
    ADD CONSTRAINT "propostas_veiculo_estoque_id_fkey" FOREIGN KEY ("veiculo_estoque_id") REFERENCES "gestao_crm"."veiculos_estoque"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "gestao_crm"."propostas"
    ADD CONSTRAINT "propostas_vendedor_id_fkey" FOREIGN KEY ("vendedor_id") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_crm"."veiculos_estoque"
    ADD CONSTRAINT "veiculos_estoque_cliente_reserva_id_fkey" FOREIGN KEY ("cliente_reserva_id") REFERENCES "gestao_crm"."clientes_crm"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_crm"."veiculos_estoque"
    ADD CONSTRAINT "veiculos_estoque_criado_por_fkey" FOREIGN KEY ("criado_por") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_crm"."veiculos_estoque"
    ADD CONSTRAINT "veiculos_estoque_veiculo_id_fkey" FOREIGN KEY ("veiculo_id") REFERENCES "public"."veiculos"("id");



ALTER TABLE ONLY "gestao_crm"."veiculos_estoque"
    ADD CONSTRAINT "veiculos_estoque_vendedor_reserva_id_fkey" FOREIGN KEY ("vendedor_reserva_id") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_crm"."vendas"
    ADD CONSTRAINT "vendas_cancelada_por_fkey" FOREIGN KEY ("cancelada_por") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_crm"."vendas"
    ADD CONSTRAINT "vendas_cliente_id_fkey" FOREIGN KEY ("cliente_id") REFERENCES "gestao_crm"."clientes_crm"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "gestao_crm"."vendas"
    ADD CONSTRAINT "vendas_criado_por_fkey" FOREIGN KEY ("criado_por") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_crm"."vendas"
    ADD CONSTRAINT "vendas_proposta_id_fkey" FOREIGN KEY ("proposta_id") REFERENCES "gestao_crm"."propostas"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_crm"."vendas"
    ADD CONSTRAINT "vendas_veiculo_estoque_id_fkey" FOREIGN KEY ("veiculo_estoque_id") REFERENCES "gestao_crm"."veiculos_estoque"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "gestao_crm"."vendas"
    ADD CONSTRAINT "vendas_vendedor_id_fkey" FOREIGN KEY ("vendedor_id") REFERENCES "public"."colaboradores"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "gestao_plataforma"."bloqueios_login"
    ADD CONSTRAINT "bloqueios_login_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao_plataforma"."logs_acesso"
    ADD CONSTRAINT "logs_acesso_colaborador_id_fkey" FOREIGN KEY ("colaborador_id") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_plataforma"."logs_acesso"
    ADD CONSTRAINT "logs_acesso_sistema_id_fkey" FOREIGN KEY ("sistema_id") REFERENCES "public"."sistemas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao_plataforma"."logs_auditoria"
    ADD CONSTRAINT "logs_auditoria_responsavel_colaborador_id_fkey" FOREIGN KEY ("responsavel_colaborador_id") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."anexos_solicitacao"
    ADD CONSTRAINT "anexos_solicitacao_criado_por_fkey" FOREIGN KEY ("criado_por") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."anexos_solicitacao"
    ADD CONSTRAINT "anexos_solicitacao_parcela_id_fkey" FOREIGN KEY ("parcela_id") REFERENCES "gestao_servicos"."parcelas_pagamento"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao_servicos"."anexos_solicitacao"
    ADD CONSTRAINT "anexos_solicitacao_solicitacao_id_fkey" FOREIGN KEY ("solicitacao_id") REFERENCES "gestao_servicos"."solicitacoes_pagamento"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao_servicos"."assinaturas_anexo"
    ADD CONSTRAINT "assinaturas_anexo_anexo_id_fkey" FOREIGN KEY ("anexo_id") REFERENCES "gestao_servicos"."anexos_solicitacao"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao_servicos"."assinaturas_anexo"
    ADD CONSTRAINT "assinaturas_anexo_colaborador_id_fkey" FOREIGN KEY ("colaborador_id") REFERENCES "public"."colaboradores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao_servicos"."categorias"
    ADD CONSTRAINT "categorias_criado_por_fkey" FOREIGN KEY ("criado_por") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."checklist_avaliacoes"
    ADD CONSTRAINT "checklist_avaliacoes_cliente_id_fkey" FOREIGN KEY ("cliente_id") REFERENCES "public"."clientes"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "gestao_servicos"."checklist_avaliacoes"
    ADD CONSTRAINT "checklist_avaliacoes_colaborador_id_fkey" FOREIGN KEY ("colaborador_id") REFERENCES "public"."colaboradores"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "gestao_servicos"."checklist_avaliacoes"
    ADD CONSTRAINT "checklist_avaliacoes_unidade_id_fkey" FOREIGN KEY ("unidade_id") REFERENCES "public"."unidades"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."checklist_avaliacoes"
    ADD CONSTRAINT "checklist_avaliacoes_veiculo_id_fkey" FOREIGN KEY ("veiculo_id") REFERENCES "public"."veiculos"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "gestao_servicos"."checklist_avarias"
    ADD CONSTRAINT "checklist_avarias_avaliacao_id_fkey" FOREIGN KEY ("avaliacao_id") REFERENCES "gestao_servicos"."checklist_avaliacoes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao_servicos"."checklist_fotos"
    ADD CONSTRAINT "checklist_fotos_avaliacao_id_fkey" FOREIGN KEY ("avaliacao_id") REFERENCES "gestao_servicos"."checklist_avaliacoes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao_servicos"."checklist_fotos"
    ADD CONSTRAINT "checklist_fotos_avaria_id_fkey" FOREIGN KEY ("avaria_id") REFERENCES "gestao_servicos"."checklist_avarias"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."checklist_itens"
    ADD CONSTRAINT "checklist_itens_avaliacao_id_fkey" FOREIGN KEY ("avaliacao_id") REFERENCES "gestao_servicos"."checklist_avaliacoes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao_servicos"."configuracoes_modulo"
    ADD CONSTRAINT "configuracoes_modulo_atualizado_por_fkey" FOREIGN KEY ("atualizado_por") REFERENCES "public"."colaboradores"("id");



ALTER TABLE ONLY "gestao_servicos"."fornecedores"
    ADD CONSTRAINT "fornecedores_criado_por_fkey" FOREIGN KEY ("criado_por") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."historico_checklist"
    ADD CONSTRAINT "historico_checklist_autor_id_fkey" FOREIGN KEY ("autor_id") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."historico_checklist"
    ADD CONSTRAINT "historico_checklist_checklist_id_fkey" FOREIGN KEY ("checklist_id") REFERENCES "gestao_servicos"."checklist_avaliacoes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao_servicos"."historico_solicitacao"
    ADD CONSTRAINT "historico_solicitacao_autor_id_fkey" FOREIGN KEY ("autor_id") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."historico_solicitacao"
    ADD CONSTRAINT "historico_solicitacao_solicitacao_id_fkey" FOREIGN KEY ("solicitacao_id") REFERENCES "gestao_servicos"."solicitacoes_pagamento"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao_servicos"."notificacoes"
    ADD CONSTRAINT "notificacoes_colaborador_id_fkey" FOREIGN KEY ("colaborador_id") REFERENCES "public"."colaboradores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao_servicos"."notificacoes"
    ADD CONSTRAINT "notificacoes_criado_por_fkey" FOREIGN KEY ("criado_por") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."parcelas_pagamento"
    ADD CONSTRAINT "parcelas_pagamento_pago_por_fkey" FOREIGN KEY ("pago_por") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."parcelas_pagamento"
    ADD CONSTRAINT "parcelas_pagamento_solicitacao_id_fkey" FOREIGN KEY ("solicitacao_id") REFERENCES "gestao_servicos"."solicitacoes_pagamento"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao_servicos"."permissoes_modulo"
    ADD CONSTRAINT "permissoes_modulo_colaborador_id_fkey" FOREIGN KEY ("colaborador_id") REFERENCES "public"."colaboradores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "gestao_servicos"."permissoes_modulo"
    ADD CONSTRAINT "permissoes_modulo_criado_por_fkey" FOREIGN KEY ("criado_por") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."solicitacoes_pagamento"
    ADD CONSTRAINT "solicitacoes_pagamento_analisado_por_fkey" FOREIGN KEY ("analisado_por") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."solicitacoes_pagamento"
    ADD CONSTRAINT "solicitacoes_pagamento_aprovador_destino_id_fkey" FOREIGN KEY ("aprovador_destino_id") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."solicitacoes_pagamento"
    ADD CONSTRAINT "solicitacoes_pagamento_categoria_id_fkey" FOREIGN KEY ("categoria_id") REFERENCES "gestao_servicos"."categorias"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."solicitacoes_pagamento"
    ADD CONSTRAINT "solicitacoes_pagamento_colaborador_beneficiario_id_fkey" FOREIGN KEY ("colaborador_beneficiario_id") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."solicitacoes_pagamento"
    ADD CONSTRAINT "solicitacoes_pagamento_criado_por_fkey" FOREIGN KEY ("criado_por") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."solicitacoes_pagamento"
    ADD CONSTRAINT "solicitacoes_pagamento_departamento_id_fkey" FOREIGN KEY ("departamento_id") REFERENCES "public"."departamentos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."solicitacoes_pagamento"
    ADD CONSTRAINT "solicitacoes_pagamento_empresa_id_fkey" FOREIGN KEY ("empresa_id") REFERENCES "public"."empresas"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."solicitacoes_pagamento"
    ADD CONSTRAINT "solicitacoes_pagamento_fornecedor_id_fkey" FOREIGN KEY ("fornecedor_id") REFERENCES "gestao_servicos"."fornecedores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."solicitacoes_pagamento"
    ADD CONSTRAINT "solicitacoes_pagamento_pago_por_fkey" FOREIGN KEY ("pago_por") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "gestao_servicos"."solicitacoes_pagamento"
    ADD CONSTRAINT "solicitacoes_pagamento_pendencia_aberta_por_fkey" FOREIGN KEY ("pendencia_aberta_por") REFERENCES "public"."colaboradores"("id");



ALTER TABLE ONLY "gestao_servicos"."solicitacoes_pagamento"
    ADD CONSTRAINT "solicitacoes_pagamento_solicitante_id_fkey" FOREIGN KEY ("solicitante_id") REFERENCES "public"."colaboradores"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "gestao_servicos"."solicitacoes_pagamento"
    ADD CONSTRAINT "solicitacoes_pagamento_unidade_id_fkey" FOREIGN KEY ("unidade_id") REFERENCES "public"."unidades"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "integracoes"."integracoes"
    ADD CONSTRAINT "integracoes_atualizado_por_fkey" FOREIGN KEY ("atualizado_por") REFERENCES "public"."colaboradores"("id");



ALTER TABLE ONLY "integracoes"."integracoes_secrets"
    ADD CONSTRAINT "integracoes_secrets_integracao_id_fkey" FOREIGN KEY ("integracao_id") REFERENCES "integracoes"."integracoes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "integracoes"."integracoes_secrets"
    ADD CONSTRAINT "integracoes_secrets_secret_id_fkey" FOREIGN KEY ("secret_id") REFERENCES "vault"."secrets"("id");



ALTER TABLE ONLY "notificacoes"."notificacoes"
    ADD CONSTRAINT "notificacoes_colaborador_id_fkey" FOREIGN KEY ("colaborador_id") REFERENCES "public"."colaboradores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "notificacoes"."notificacoes"
    ADD CONSTRAINT "notificacoes_criado_por_fkey" FOREIGN KEY ("criado_por") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."acessos_usuario_sistema"
    ADD CONSTRAINT "acessos_usuario_sistema_colaborador_id_fkey" FOREIGN KEY ("colaborador_id") REFERENCES "public"."colaboradores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."acessos_usuario_sistema"
    ADD CONSTRAINT "acessos_usuario_sistema_sistema_id_fkey" FOREIGN KEY ("sistema_id") REFERENCES "public"."sistemas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."avisos_aceites"
    ADD CONSTRAINT "avisos_aceites_aviso_id_fkey" FOREIGN KEY ("aviso_id") REFERENCES "public"."avisos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."avisos_aceites"
    ADD CONSTRAINT "avisos_aceites_colaborador_id_fkey" FOREIGN KEY ("colaborador_id") REFERENCES "public"."colaboradores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."avisos"
    ADD CONSTRAINT "avisos_criado_por_fkey" FOREIGN KEY ("criado_por") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."cargos"
    ADD CONSTRAINT "cargos_departamento_id_fkey" FOREIGN KEY ("departamento_id") REFERENCES "public"."departamentos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."clientes_telefones_adicionais"
    ADD CONSTRAINT "clientes_telefones_adicionais_cliente_id_fkey" FOREIGN KEY ("cliente_id") REFERENCES "public"."clientes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."colaboradores"
    ADD CONSTRAINT "colaboradores_cargo_id_fkey" FOREIGN KEY ("cargo_id") REFERENCES "public"."cargos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."colaboradores"
    ADD CONSTRAINT "colaboradores_departamento_id_fkey" FOREIGN KEY ("departamento_id") REFERENCES "public"."departamentos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."colaboradores"
    ADD CONSTRAINT "colaboradores_empresa_id_fkey" FOREIGN KEY ("empresa_id") REFERENCES "public"."empresas"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."colaboradores"
    ADD CONSTRAINT "colaboradores_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."colaboradores"
    ADD CONSTRAINT "colaboradores_unidade_id_fkey" FOREIGN KEY ("unidade_id") REFERENCES "public"."unidades"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."comunicados"
    ADD CONSTRAINT "comunicados_colaborador_id_fkey" FOREIGN KEY ("colaborador_id") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."comunicados"
    ADD CONSTRAINT "comunicados_criado_por_fkey" FOREIGN KEY ("criado_por") REFERENCES "public"."colaboradores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."modelos_veiculo"
    ADD CONSTRAINT "modelos_veiculo_categoria_veiculo_id_fkey" FOREIGN KEY ("categoria_veiculo_id") REFERENCES "public"."categorias_veiculo"("id");



ALTER TABLE ONLY "public"."modelos_veiculo"
    ADD CONSTRAINT "modelos_veiculo_marca_id_fkey" FOREIGN KEY ("marca_id") REFERENCES "public"."marcas_veiculo"("id");



ALTER TABLE ONLY "public"."push_subscriptions"
    ADD CONSTRAINT "push_subscriptions_colaborador_id_fkey" FOREIGN KEY ("colaborador_id") REFERENCES "public"."colaboradores"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."unidades"
    ADD CONSTRAINT "unidades_empresa_id_fkey" FOREIGN KEY ("empresa_id") REFERENCES "public"."empresas"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."veiculos"
    ADD CONSTRAINT "veiculos_cliente_atual_id_fkey" FOREIGN KEY ("cliente_atual_id") REFERENCES "public"."clientes"("id");



ALTER TABLE ONLY "public"."veiculos"
    ADD CONSTRAINT "veiculos_cor_id_fkey" FOREIGN KEY ("cor_id") REFERENCES "public"."cores_veiculo"("id");



ALTER TABLE ONLY "public"."veiculos"
    ADD CONSTRAINT "veiculos_modelo_id_fkey" FOREIGN KEY ("modelo_id") REFERENCES "public"."modelos_veiculo"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."veiculos_proprietarios"
    ADD CONSTRAINT "veiculos_proprietarios_cliente_id_fkey" FOREIGN KEY ("cliente_id") REFERENCES "public"."clientes"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."veiculos_proprietarios"
    ADD CONSTRAINT "veiculos_proprietarios_veiculo_id_fkey" FOREIGN KEY ("veiculo_id") REFERENCES "public"."veiculos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."veiculos"
    ADD CONSTRAINT "veiculos_versao_id_fkey" FOREIGN KEY ("versao_id") REFERENCES "public"."versoes_veiculo"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."versoes_veiculo"
    ADD CONSTRAINT "versoes_veiculo_modelo_id_fkey" FOREIGN KEY ("modelo_id") REFERENCES "public"."modelos_veiculo"("id");


ALTER TABLE "gestao_crm"."clientes_crm" ENABLE ROW LEVEL SECURITY;



CREATE POLICY "crm_clientes_manage" ON "gestao_crm"."clientes_crm" TO "authenticated" USING ("public"."crm_has_access"()) WITH CHECK ("public"."crm_has_access"());



CREATE POLICY "crm_clientes_select" ON "gestao_crm"."clientes_crm" FOR SELECT TO "authenticated" USING ("public"."crm_has_access"());



CREATE POLICY "crm_propostas_manage" ON "gestao_crm"."propostas" TO "authenticated" USING ("public"."crm_has_access"()) WITH CHECK ("public"."crm_has_access"());



CREATE POLICY "crm_propostas_select" ON "gestao_crm"."propostas" FOR SELECT TO "authenticated" USING ("public"."crm_has_access"());



CREATE POLICY "crm_veiculos_estoque_delete" ON "gestao_crm"."veiculos_estoque" FOR DELETE TO "authenticated" USING (("public"."crm_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"])));



CREATE POLICY "crm_veiculos_estoque_insert" ON "gestao_crm"."veiculos_estoque" FOR INSERT TO "authenticated" WITH CHECK (("public"."crm_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"])));



CREATE POLICY "crm_veiculos_estoque_select" ON "gestao_crm"."veiculos_estoque" FOR SELECT TO "authenticated" USING ("public"."crm_has_access"());



CREATE POLICY "crm_veiculos_estoque_update" ON "gestao_crm"."veiculos_estoque" FOR UPDATE TO "authenticated" USING (("public"."crm_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"]))) WITH CHECK (("public"."crm_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"])));



CREATE POLICY "crm_vendas_manage" ON "gestao_crm"."vendas" TO "authenticated" USING ("public"."crm_has_access"()) WITH CHECK ("public"."crm_has_access"());



CREATE POLICY "crm_vendas_select" ON "gestao_crm"."vendas" FOR SELECT TO "authenticated" USING ("public"."crm_has_access"());


ALTER TABLE "gestao_crm"."propostas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao_crm"."veiculos_estoque" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao_crm"."vendas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao_plataforma"."alertas_seguranca_enviados" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "alertas_seguranca_enviados_insert_service_role" ON "gestao_plataforma"."alertas_seguranca_enviados" FOR INSERT TO "service_role" WITH CHECK (true);



CREATE POLICY "alertas_seguranca_enviados_select_admin_console" ON "gestao_plataforma"."alertas_seguranca_enviados" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."colaboradores" "c"
  WHERE (("c"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("c"."status" <> 'inativo'::"text") AND ("c"."funcao" = ANY (ARRAY['admin'::"text", 'gestor'::"text"]))))));



ALTER TABLE "gestao_plataforma"."bloqueios_login" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao_plataforma"."logs_acesso" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "logs_acesso_plataforma_insert_service_role" ON "gestao_plataforma"."logs_acesso" FOR INSERT TO "service_role" WITH CHECK (true);



CREATE POLICY "logs_acesso_plataforma_select_admin_console" ON "gestao_plataforma"."logs_acesso" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."colaboradores" "c"
  WHERE (("c"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("c"."status" <> 'inativo'::"text") AND ("c"."funcao" = ANY (ARRAY['admin'::"text", 'gestor'::"text"]))))) OR (EXISTS ( SELECT 1
   FROM ("public"."acessos_usuario_sistema" "aus"
     JOIN "public"."sistemas" "s" ON (("s"."id" = "aus"."sistema_id")))
  WHERE (("aus"."colaborador_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("aus"."ativo" = true) AND ("aus"."nivel_acesso" = ANY (ARRAY['admin'::"text", 'gestor'::"text"])) AND ("s"."slug" = 'central'::"text") AND ("s"."ativo" = true))))));



ALTER TABLE "gestao_plataforma"."logs_auditoria" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "logs_auditoria_plataforma_insert_service_role" ON "gestao_plataforma"."logs_auditoria" FOR INSERT TO "service_role" WITH CHECK (true);



CREATE POLICY "logs_auditoria_plataforma_select_admin_console" ON "gestao_plataforma"."logs_auditoria" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."colaboradores" "c"
  WHERE (("c"."id" = ( SELECT "auth"."uid"() AS "uid")) AND ("c"."status" <> 'inativo'::"text") AND ("c"."funcao" = ANY (ARRAY['admin'::"text", 'gestor'::"text"]))))) OR (EXISTS ( SELECT 1
   FROM ("public"."acessos_usuario_sistema" "aus"
     JOIN "public"."sistemas" "s" ON (("s"."id" = "aus"."sistema_id")))
  WHERE (("aus"."colaborador_id" = ( SELECT "auth"."uid"() AS "uid")) AND ("aus"."ativo" = true) AND ("aus"."nivel_acesso" = ANY (ARRAY['admin'::"text", 'gestor'::"text"])) AND ("s"."slug" = 'central'::"text") AND ("s"."ativo" = true))))));



ALTER TABLE "gestao_servicos"."anexos_solicitacao" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao_servicos"."assinaturas_anexo" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao_servicos"."categorias" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao_servicos"."checklist_avaliacoes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao_servicos"."checklist_avarias" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao_servicos"."checklist_fotos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao_servicos"."checklist_itens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao_servicos"."configuracoes_modulo" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao_servicos"."fornecedores" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao_servicos"."historico_checklist" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao_servicos"."historico_solicitacao" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao_servicos"."notificacoes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao_servicos"."parcelas_pagamento" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "gestao_servicos"."permissoes_modulo" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "servicos_anexos_delete" ON "gestao_servicos"."anexos_solicitacao" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "gestao_servicos"."solicitacoes_pagamento" "sp"
  WHERE (("sp"."id" = "anexos_solicitacao"."solicitacao_id") AND (("sp"."status" = 'pendente'::"text") OR ("sp"."pendencia_bloqueio" = true)) AND ("public"."servicos_is_financeiro"() OR ("sp"."solicitante_id" = "public"."current_colaborador_id"()))))));



CREATE POLICY "servicos_anexos_insert" ON "gestao_servicos"."anexos_solicitacao" FOR INSERT TO "authenticated" WITH CHECK ((("criado_por" = "public"."current_colaborador_id"()) AND (EXISTS ( SELECT 1
   FROM "gestao_servicos"."solicitacoes_pagamento" "sp"
  WHERE (("sp"."id" = "anexos_solicitacao"."solicitacao_id") AND "public"."servicos_can_access_solicitacao"("sp"."solicitante_id", "sp"."aprovador_destino_id", "sp"."departamento_id", "sp"."forma_pagamento", "sp"."unidade_id"))))));



CREATE POLICY "servicos_anexos_select" ON "gestao_servicos"."anexos_solicitacao" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "gestao_servicos"."solicitacoes_pagamento" "sp"
  WHERE (("sp"."id" = "anexos_solicitacao"."solicitacao_id") AND "public"."servicos_can_access_solicitacao"("sp"."solicitante_id", "sp"."aprovador_destino_id", "sp"."departamento_id", "sp"."forma_pagamento", "sp"."unidade_id")))) AND ((NOT "sigiloso") OR (EXISTS ( SELECT 1
   FROM "gestao_servicos"."solicitacoes_pagamento" "sp"
  WHERE (("sp"."id" = "anexos_solicitacao"."solicitacao_id") AND
        CASE
            WHEN (("sp"."forma_pagamento" = 'dinheiro'::"text") AND "public"."servicos_restringe_visibilidade_dinheiro"()) THEN ("public"."servicos_is_financeiro"() OR ("sp"."solicitante_id" = "public"."current_colaborador_id"()) OR (("public"."servicos_module_role"() = 'aprovador'::"text") AND ("sp"."aprovador_destino_id" = "public"."current_colaborador_id"())))
            ELSE ("public"."servicos_is_financeiro"() OR ("sp"."solicitante_id" = "public"."current_colaborador_id"()) OR (("public"."servicos_module_role"() = 'aprovador'::"text") AND ("sp"."aprovador_destino_id" = "public"."current_colaborador_id"())) OR (("sp"."departamento_id" IS NOT NULL) AND ("sp"."departamento_id" = "public"."servicos_current_department_id"()) AND (("sp"."unidade_id" IS NULL) OR ("public"."servicos_current_unit_id"() IS NULL) OR ("sp"."unidade_id" = "public"."servicos_current_unit_id"()))))
        END))))));



CREATE POLICY "servicos_assinaturas_anexo_select" ON "gestao_servicos"."assinaturas_anexo" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("gestao_servicos"."anexos_solicitacao" "an"
     JOIN "gestao_servicos"."solicitacoes_pagamento" "sp" ON (("sp"."id" = "an"."solicitacao_id")))
  WHERE (("an"."id" = "assinaturas_anexo"."anexo_id") AND ("public"."servicos_is_aprovador"() OR ("public"."servicos_has_access"() AND ("sp"."solicitante_id" = "public"."current_colaborador_id"())))))));



CREATE POLICY "servicos_categorias_insert" ON "gestao_servicos"."categorias" FOR INSERT TO "authenticated" WITH CHECK (("public"."servicos_is_financeiro"() AND ("criado_por" = "public"."current_colaborador_id"())));



CREATE POLICY "servicos_categorias_select" ON "gestao_servicos"."categorias" FOR SELECT TO "authenticated" USING ("public"."servicos_has_access"());



CREATE POLICY "servicos_categorias_update" ON "gestao_servicos"."categorias" FOR UPDATE TO "authenticated" USING ("public"."servicos_is_financeiro"()) WITH CHECK ("public"."servicos_is_financeiro"());



CREATE POLICY "servicos_configuracoes_modulo_select" ON "gestao_servicos"."configuracoes_modulo" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "servicos_fornecedores_insert" ON "gestao_servicos"."fornecedores" FOR INSERT TO "authenticated" WITH CHECK (("public"."servicos_has_access"() AND ("criado_por" = "public"."current_colaborador_id"())));



CREATE POLICY "servicos_fornecedores_select" ON "gestao_servicos"."fornecedores" FOR SELECT TO "authenticated" USING ("public"."servicos_has_access"());



CREATE POLICY "servicos_fornecedores_update" ON "gestao_servicos"."fornecedores" FOR UPDATE TO "authenticated" USING ("public"."servicos_is_financeiro"()) WITH CHECK ("public"."servicos_is_financeiro"());



CREATE POLICY "servicos_historico_insert" ON "gestao_servicos"."historico_solicitacao" FOR INSERT TO "authenticated" WITH CHECK ((("autor_id" = "public"."current_colaborador_id"()) AND (EXISTS ( SELECT 1
   FROM "gestao_servicos"."solicitacoes_pagamento" "sp"
  WHERE (("sp"."id" = "historico_solicitacao"."solicitacao_id") AND "public"."servicos_can_access_solicitacao"("sp"."solicitante_id", "sp"."aprovador_destino_id", "sp"."departamento_id", "sp"."forma_pagamento", "sp"."unidade_id"))))));



CREATE POLICY "servicos_historico_select" ON "gestao_servicos"."historico_solicitacao" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "gestao_servicos"."solicitacoes_pagamento" "sp"
  WHERE (("sp"."id" = "historico_solicitacao"."solicitacao_id") AND "public"."servicos_can_access_solicitacao"("sp"."solicitante_id", "sp"."aprovador_destino_id", "sp"."departamento_id", "sp"."forma_pagamento", "sp"."unidade_id")))));



CREATE POLICY "servicos_notificacoes_select_self" ON "gestao_servicos"."notificacoes" FOR SELECT USING (("colaborador_id" = "public"."current_colaborador_id"()));



CREATE POLICY "servicos_notificacoes_update_self" ON "gestao_servicos"."notificacoes" FOR UPDATE USING (("colaborador_id" = "public"."current_colaborador_id"())) WITH CHECK (("colaborador_id" = "public"."current_colaborador_id"()));



CREATE POLICY "servicos_oficina_checklist_avaliacoes_insert" ON "gestao_servicos"."checklist_avaliacoes" FOR INSERT TO "authenticated" WITH CHECK ("public"."servicos_oficina_pode_editar"());



CREATE POLICY "servicos_oficina_checklist_avaliacoes_select" ON "gestao_servicos"."checklist_avaliacoes" FOR SELECT TO "authenticated" USING ("public"."servicos_oficina_pode_ver"());



CREATE POLICY "servicos_oficina_checklist_avaliacoes_update" ON "gestao_servicos"."checklist_avaliacoes" FOR UPDATE TO "authenticated" USING ("public"."servicos_oficina_pode_editar"()) WITH CHECK ("public"."servicos_oficina_pode_editar"());



CREATE POLICY "servicos_oficina_checklist_avarias_select" ON "gestao_servicos"."checklist_avarias" FOR SELECT TO "authenticated" USING ("public"."servicos_oficina_pode_ver"());



CREATE POLICY "servicos_oficina_checklist_avarias_write" ON "gestao_servicos"."checklist_avarias" TO "authenticated" USING ("public"."servicos_oficina_pode_editar"()) WITH CHECK ("public"."servicos_oficina_pode_editar"());



CREATE POLICY "servicos_oficina_checklist_fotos_select" ON "gestao_servicos"."checklist_fotos" FOR SELECT TO "authenticated" USING ("public"."servicos_oficina_pode_ver"());



CREATE POLICY "servicos_oficina_checklist_fotos_write" ON "gestao_servicos"."checklist_fotos" TO "authenticated" USING ("public"."servicos_oficina_pode_editar"()) WITH CHECK ("public"."servicos_oficina_pode_editar"());



CREATE POLICY "servicos_oficina_checklist_itens_select" ON "gestao_servicos"."checklist_itens" FOR SELECT TO "authenticated" USING ("public"."servicos_oficina_pode_ver"());



CREATE POLICY "servicos_oficina_checklist_itens_write" ON "gestao_servicos"."checklist_itens" TO "authenticated" USING ("public"."servicos_oficina_pode_editar"()) WITH CHECK ("public"."servicos_oficina_pode_editar"());



CREATE POLICY "servicos_oficina_historico_checklist_insert" ON "gestao_servicos"."historico_checklist" FOR INSERT TO "authenticated" WITH CHECK ("public"."servicos_oficina_pode_ver"());



CREATE POLICY "servicos_oficina_historico_checklist_select" ON "gestao_servicos"."historico_checklist" FOR SELECT TO "authenticated" USING ("public"."servicos_oficina_pode_ver"());



CREATE POLICY "servicos_parcelas_delete" ON "gestao_servicos"."parcelas_pagamento" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "gestao_servicos"."solicitacoes_pagamento" "sp"
  WHERE (("sp"."id" = "parcelas_pagamento"."solicitacao_id") AND
        CASE
            WHEN (("sp"."forma_pagamento" = 'dinheiro'::"text") AND "public"."servicos_restringe_visibilidade_dinheiro"()) THEN "public"."servicos_is_financeiro"()
            ELSE "public"."servicos_is_pagador"()
        END))));



CREATE POLICY "servicos_parcelas_insert" ON "gestao_servicos"."parcelas_pagamento" FOR INSERT TO "authenticated" WITH CHECK (((EXISTS ( SELECT 1
   FROM "gestao_servicos"."solicitacoes_pagamento" "sp"
  WHERE (("sp"."id" = "parcelas_pagamento"."solicitacao_id") AND ("sp"."solicitante_id" = "public"."current_colaborador_id"()) AND ("sp"."status" = 'pendente'::"text")))) OR (EXISTS ( SELECT 1
   FROM "gestao_servicos"."solicitacoes_pagamento" "sp"
  WHERE (("sp"."id" = "parcelas_pagamento"."solicitacao_id") AND
        CASE
            WHEN (("sp"."forma_pagamento" = 'dinheiro'::"text") AND "public"."servicos_restringe_visibilidade_dinheiro"()) THEN "public"."servicos_is_financeiro"()
            ELSE "public"."servicos_is_pagador"()
        END)))));



CREATE POLICY "servicos_parcelas_select" ON "gestao_servicos"."parcelas_pagamento" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "gestao_servicos"."solicitacoes_pagamento" "sp"
  WHERE (("sp"."id" = "parcelas_pagamento"."solicitacao_id") AND "public"."servicos_can_access_solicitacao"("sp"."solicitante_id", "sp"."aprovador_destino_id", "sp"."departamento_id", "sp"."forma_pagamento", "sp"."unidade_id")))));



CREATE POLICY "servicos_parcelas_update" ON "gestao_servicos"."parcelas_pagamento" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "gestao_servicos"."solicitacoes_pagamento" "sp"
  WHERE (("sp"."id" = "parcelas_pagamento"."solicitacao_id") AND
        CASE
            WHEN (("sp"."forma_pagamento" = 'dinheiro'::"text") AND "public"."servicos_restringe_visibilidade_dinheiro"()) THEN "public"."servicos_is_financeiro"()
            ELSE "public"."servicos_is_pagador"()
        END)))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "gestao_servicos"."solicitacoes_pagamento" "sp"
  WHERE (("sp"."id" = "parcelas_pagamento"."solicitacao_id") AND
        CASE
            WHEN (("sp"."forma_pagamento" = 'dinheiro'::"text") AND "public"."servicos_restringe_visibilidade_dinheiro"()) THEN "public"."servicos_is_financeiro"()
            ELSE "public"."servicos_is_pagador"()
        END))));



CREATE POLICY "servicos_permissoes_modulo_insert" ON "gestao_servicos"."permissoes_modulo" FOR INSERT TO "authenticated" WITH CHECK (("public"."servicos_access_level"() = 'admin'::"text"));



CREATE POLICY "servicos_permissoes_modulo_select" ON "gestao_servicos"."permissoes_modulo" FOR SELECT TO "authenticated" USING (("public"."servicos_access_level"() = 'admin'::"text"));



CREATE POLICY "servicos_permissoes_modulo_update" ON "gestao_servicos"."permissoes_modulo" FOR UPDATE TO "authenticated" USING (("public"."servicos_access_level"() = 'admin'::"text")) WITH CHECK (("public"."servicos_access_level"() = 'admin'::"text"));



CREATE POLICY "servicos_solicitacoes_insert" ON "gestao_servicos"."solicitacoes_pagamento" FOR INSERT TO "authenticated" WITH CHECK (("public"."servicos_has_access"() AND ("solicitante_id" = "public"."current_colaborador_id"())));



CREATE POLICY "servicos_solicitacoes_select" ON "gestao_servicos"."solicitacoes_pagamento" FOR SELECT TO "authenticated" USING ("public"."servicos_can_access_solicitacao"("solicitante_id", "aprovador_destino_id", "departamento_id", "forma_pagamento", "unidade_id"));



CREATE POLICY "servicos_solicitacoes_update" ON "gestao_servicos"."solicitacoes_pagamento" FOR UPDATE TO "authenticated" USING (("public"."servicos_is_financeiro"() OR (("public"."servicos_module_role"() = 'aprovador'::"text") AND ("aprovador_destino_id" = "public"."current_colaborador_id"())) OR ("public"."servicos_has_access"() AND ("solicitante_id" = "public"."current_colaborador_id"()) AND ("status" = 'pendente'::"text")))) WITH CHECK (("public"."servicos_is_financeiro"() OR (("public"."servicos_module_role"() = 'aprovador'::"text") AND ("aprovador_destino_id" = "public"."current_colaborador_id"())) OR (("solicitante_id" = "public"."current_colaborador_id"()) AND ("status" = 'pendente'::"text"))));



ALTER TABLE "gestao_servicos"."solicitacoes_pagamento" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "integracoes"."integracoes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "integracoes"."integracoes_secrets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "notificacoes"."notificacoes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "notificacoes_select_self" ON "notificacoes"."notificacoes" FOR SELECT TO "authenticated" USING (("colaborador_id" = ( SELECT "public"."current_colaborador_id"() AS "current_colaborador_id")));



CREATE POLICY "notificacoes_update_self" ON "notificacoes"."notificacoes" FOR UPDATE TO "authenticated" USING (("colaborador_id" = ( SELECT "public"."current_colaborador_id"() AS "current_colaborador_id"))) WITH CHECK (("colaborador_id" = ( SELECT "public"."current_colaborador_id"() AS "current_colaborador_id")));



CREATE POLICY "acessos_admin_manage" ON "public"."acessos_usuario_sistema" TO "authenticated" USING ("public"."is_intranet_admin"()) WITH CHECK ("public"."is_intranet_admin"());



CREATE POLICY "acessos_read_self_or_admin" ON "public"."acessos_usuario_sistema" FOR SELECT TO "authenticated" USING ((("colaborador_id" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."is_intranet_admin"()));



ALTER TABLE "public"."acessos_usuario_sistema" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."avisos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."avisos_aceites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cargos" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cargos_select_authenticated" ON "public"."cargos" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."categorias_veiculo" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cliente_identidade_manage" ON "public"."clientes" TO "authenticated" USING (("public"."cliente_identidade_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text", 'usuario'::"text"]))) WITH CHECK (("public"."cliente_identidade_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text", 'usuario'::"text"])));



CREATE POLICY "cliente_identidade_select" ON "public"."clientes" FOR SELECT TO "authenticated" USING ("public"."cliente_identidade_has_access"());



CREATE POLICY "cliente_telefones_adicionais_manage" ON "public"."clientes_telefones_adicionais" TO "authenticated" USING (("public"."cliente_identidade_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text", 'usuario'::"text"]))) WITH CHECK (("public"."cliente_identidade_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text", 'usuario'::"text"])));



CREATE POLICY "cliente_telefones_adicionais_select" ON "public"."clientes_telefones_adicionais" FOR SELECT TO "authenticated" USING ("public"."cliente_identidade_has_access"());



ALTER TABLE "public"."clientes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."clientes_telefones_adicionais" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."colaboradores" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."comunicados" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."cores_veiculo" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "cores_veiculo_manage" ON "public"."cores_veiculo" TO "authenticated" USING (("public"."crm_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"]))) WITH CHECK (("public"."crm_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"])));



CREATE POLICY "cores_veiculo_select" ON "public"."cores_veiculo" FOR SELECT TO "authenticated" USING ("public"."crm_has_access"());



ALTER TABLE "public"."departamentos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."empresas" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "empresas_select_authenticated" ON "public"."empresas" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."marcas_veiculo" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."modelos_veiculo" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."push_subscriptions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "push_subscriptions_delete_self" ON "public"."push_subscriptions" FOR DELETE USING (("colaborador_id" = "public"."current_colaborador_id"()));



CREATE POLICY "push_subscriptions_insert_self" ON "public"."push_subscriptions" FOR INSERT WITH CHECK (("colaborador_id" = "public"."current_colaborador_id"()));



CREATE POLICY "push_subscriptions_select_self" ON "public"."push_subscriptions" FOR SELECT USING (("colaborador_id" = "public"."current_colaborador_id"()));



ALTER TABLE "public"."sistemas" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sistemas_admin_manage" ON "public"."sistemas" TO "authenticated" USING ("public"."is_intranet_admin"()) WITH CHECK ("public"."is_intranet_admin"());



CREATE POLICY "sistemas_read_authenticated" ON "public"."sistemas" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."unidades" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "veiculo_catalogo_categorias_manage" ON "public"."categorias_veiculo" TO "authenticated" USING (("public"."veiculo_catalogo_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"]))) WITH CHECK (("public"."veiculo_catalogo_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"])));



CREATE POLICY "veiculo_catalogo_categorias_select" ON "public"."categorias_veiculo" FOR SELECT TO "authenticated" USING ("public"."veiculo_catalogo_has_access"());



CREATE POLICY "veiculo_catalogo_marcas_manage" ON "public"."marcas_veiculo" TO "authenticated" USING (("public"."veiculo_catalogo_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"]))) WITH CHECK (("public"."veiculo_catalogo_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"])));



CREATE POLICY "veiculo_catalogo_marcas_select" ON "public"."marcas_veiculo" FOR SELECT TO "authenticated" USING ("public"."veiculo_catalogo_has_access"());



CREATE POLICY "veiculo_catalogo_modelos_manage" ON "public"."modelos_veiculo" TO "authenticated" USING (("public"."veiculo_catalogo_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"]))) WITH CHECK (("public"."veiculo_catalogo_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"])));



CREATE POLICY "veiculo_catalogo_modelos_select" ON "public"."modelos_veiculo" FOR SELECT TO "authenticated" USING ("public"."veiculo_catalogo_has_access"());



CREATE POLICY "veiculo_catalogo_veiculos_delete" ON "public"."veiculos" FOR DELETE TO "authenticated" USING (("public"."veiculo_catalogo_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"])));



CREATE POLICY "veiculo_catalogo_veiculos_insert" ON "public"."veiculos" FOR INSERT TO "authenticated" WITH CHECK (("public"."veiculo_catalogo_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"])));



CREATE POLICY "veiculo_catalogo_veiculos_select" ON "public"."veiculos" FOR SELECT TO "authenticated" USING ("public"."veiculo_catalogo_has_access"());



CREATE POLICY "veiculo_catalogo_veiculos_update" ON "public"."veiculos" FOR UPDATE TO "authenticated" USING (("public"."veiculo_catalogo_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"]))) WITH CHECK (("public"."veiculo_catalogo_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"])));



CREATE POLICY "veiculo_catalogo_versoes_manage" ON "public"."versoes_veiculo" TO "authenticated" USING (("public"."veiculo_catalogo_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"]))) WITH CHECK (("public"."veiculo_catalogo_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text"])));



CREATE POLICY "veiculo_catalogo_versoes_select" ON "public"."versoes_veiculo" FOR SELECT TO "authenticated" USING ("public"."veiculo_catalogo_has_access"());



ALTER TABLE "public"."veiculos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."veiculos_proprietarios" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "veiculos_proprietarios_manage" ON "public"."veiculos_proprietarios" TO "authenticated" USING (("public"."cliente_identidade_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text", 'usuario'::"text"]))) WITH CHECK (("public"."cliente_identidade_access_level"() = ANY (ARRAY['admin'::"text", 'gestor'::"text", 'usuario'::"text"])));



CREATE POLICY "veiculos_proprietarios_select" ON "public"."veiculos_proprietarios" FOR SELECT TO "authenticated" USING ("public"."cliente_identidade_has_access"());



ALTER TABLE "public"."versoes_veiculo" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "gestao_crm"."clientes_crm";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "gestao_crm"."propostas";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "gestao_crm"."veiculos_estoque";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "gestao_crm"."vendas";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "gestao_servicos"."notificacoes";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "gestao_servicos"."solicitacoes_pagamento";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "notificacoes"."notificacoes";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."categorias_veiculo";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."marcas_veiculo";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."modelos_veiculo";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."veiculos";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."versoes_veiculo";



GRANT USAGE ON SCHEMA "gestao_crm" TO "authenticated";
GRANT USAGE ON SCHEMA "gestao_crm" TO "service_role";



GRANT USAGE ON SCHEMA "gestao_plataforma" TO "authenticated";
GRANT USAGE ON SCHEMA "gestao_plataforma" TO "service_role";
GRANT USAGE ON SCHEMA "gestao_plataforma" TO "supabase_auth_admin";



GRANT USAGE ON SCHEMA "gestao_servicos" TO "authenticated";
GRANT USAGE ON SCHEMA "gestao_servicos" TO "service_role";



GRANT USAGE ON SCHEMA "integracoes" TO "service_role";






GRANT USAGE ON SCHEMA "notificacoes" TO "service_role";
GRANT USAGE ON SCHEMA "notificacoes" TO "authenticated";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";
GRANT USAGE ON SCHEMA "public" TO "authenticator";



GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_in"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_out"("public"."gtrgm") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."citext"(character) TO "postgres";
GRANT ALL ON FUNCTION "public"."citext"(character) TO "anon";
GRANT ALL ON FUNCTION "public"."citext"(character) TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext"(character) TO "service_role";



GRANT ALL ON FUNCTION "public"."citext"("inet") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext"("inet") TO "anon";
GRANT ALL ON FUNCTION "public"."citext"("inet") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext"("inet") TO "service_role";



REVOKE ALL ON FUNCTION "gestao_plataforma"."hook_verificacao_senha"("event" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "gestao_plataforma"."hook_verificacao_senha"("event" "jsonb") TO "supabase_auth_admin";



REVOKE ALL ON FUNCTION "integracoes"."get_credenciais"("p_chave" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "integracoes"."get_credenciais"("p_chave" "text") TO "service_role";



REVOKE ALL ON FUNCTION "notificacoes"."limpar_notificacoes_antigas"() FROM PUBLIC;



GRANT ALL ON FUNCTION "public"."auto_create_servicos_permissoes"() TO "anon";
GRANT ALL ON FUNCTION "public"."auto_create_servicos_permissoes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."auto_create_servicos_permissoes"() TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."cliente_identidade_access_level"() TO "anon";
GRANT ALL ON FUNCTION "public"."cliente_identidade_access_level"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cliente_identidade_access_level"() TO "service_role";



GRANT ALL ON FUNCTION "public"."cliente_identidade_has_access"() TO "anon";
GRANT ALL ON FUNCTION "public"."cliente_identidade_has_access"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cliente_identidade_has_access"() TO "service_role";



GRANT ALL ON FUNCTION "public"."crm_access_level"() TO "anon";
GRANT ALL ON FUNCTION "public"."crm_access_level"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."crm_access_level"() TO "service_role";



GRANT ALL ON FUNCTION "public"."crm_can_manage"() TO "anon";
GRANT ALL ON FUNCTION "public"."crm_can_manage"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."crm_can_manage"() TO "service_role";



GRANT ALL ON FUNCTION "public"."crm_current_colaborador_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."crm_current_colaborador_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."crm_current_colaborador_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."crm_current_unidade_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."crm_current_unidade_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."crm_current_unidade_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."crm_has_access"() TO "anon";
GRANT ALL ON FUNCTION "public"."crm_has_access"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."crm_has_access"() TO "service_role";



GRANT ALL ON FUNCTION "public"."current_colaborador_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."current_colaborador_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_colaborador_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_query_trgm"("text", "internal", smallint, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_extract_value_trgm"("text", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_consistent"("internal", smallint, "text", integer, "internal", "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gin_trgm_triconsistent"("internal", smallint, "text", integer, "internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."grant_intranet_access"("p_email" "text", "p_nivel_acesso" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."grant_intranet_access"("p_email" "text", "p_nivel_acesso" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."grant_intranet_access"("p_email" "text", "p_nivel_acesso" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_compress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_consistent"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_decompress"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_distance"("internal", "text", smallint, "oid", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_options"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_penalty"("internal", "internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_picksplit"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_same"("public"."gtrgm", "public"."gtrgm", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "anon";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."gtrgm_union"("internal", "internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."has_system_access"("system_slug" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."has_system_access"("system_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_system_access"("system_slug" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_intranet_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_intranet_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_intranet_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."relatorios_access_level"() TO "anon";
GRANT ALL ON FUNCTION "public"."relatorios_access_level"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."relatorios_access_level"() TO "service_role";



GRANT ALL ON FUNCTION "public"."relatorios_is_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."relatorios_is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."relatorios_is_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "anon";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."rls_auto_enable"() TO "service_role";



GRANT ALL ON FUNCTION "public"."servicos_access_level"() TO "anon";
GRANT ALL ON FUNCTION "public"."servicos_access_level"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."servicos_access_level"() TO "service_role";



GRANT ALL ON FUNCTION "public"."servicos_can_access_solicitacao"("p_solicitante_id" "uuid", "p_aprovador_destino_id" "uuid", "p_departamento_id" "uuid", "p_forma_pagamento" "text", "p_unidade_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."servicos_can_access_solicitacao"("p_solicitante_id" "uuid", "p_aprovador_destino_id" "uuid", "p_departamento_id" "uuid", "p_forma_pagamento" "text", "p_unidade_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."servicos_can_access_solicitacao"("p_solicitante_id" "uuid", "p_aprovador_destino_id" "uuid", "p_departamento_id" "uuid", "p_forma_pagamento" "text", "p_unidade_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."servicos_current_department_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."servicos_current_department_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."servicos_current_department_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."servicos_current_unit_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."servicos_current_unit_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."servicos_current_unit_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."servicos_has_access"() TO "anon";
GRANT ALL ON FUNCTION "public"."servicos_has_access"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."servicos_has_access"() TO "service_role";



GRANT ALL ON FUNCTION "public"."servicos_is_aprovador"("p_modulo" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."servicos_is_aprovador"("p_modulo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."servicos_is_aprovador"("p_modulo" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."servicos_is_financeiro"("p_modulo" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."servicos_is_financeiro"("p_modulo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."servicos_is_financeiro"("p_modulo" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."servicos_is_pagador"("p_modulo" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."servicos_is_pagador"("p_modulo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."servicos_is_pagador"("p_modulo" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."servicos_module_role"("p_modulo" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."servicos_module_role"("p_modulo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."servicos_module_role"("p_modulo" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."servicos_oficina_pode_editar"() TO "anon";
GRANT ALL ON FUNCTION "public"."servicos_oficina_pode_editar"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."servicos_oficina_pode_editar"() TO "service_role";



GRANT ALL ON FUNCTION "public"."servicos_oficina_pode_ver"() TO "anon";
GRANT ALL ON FUNCTION "public"."servicos_oficina_pode_ver"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."servicos_oficina_pode_ver"() TO "service_role";



GRANT ALL ON FUNCTION "public"."servicos_restringe_visibilidade_dinheiro"("p_modulo" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."servicos_restringe_visibilidade_dinheiro"("p_modulo" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."servicos_restringe_visibilidade_dinheiro"("p_modulo" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "postgres";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "anon";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_limit"(real) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."show_limit"() TO "postgres";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "anon";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_limit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "postgres";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "anon";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."show_trgm"("text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_dist"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."similarity_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strict_word_similarity_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_auth_user_to_colaborador"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_auth_user_to_colaborador"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_auth_user_to_colaborador"() TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_colaborador_cargo_from_cargo_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_colaborador_cargo_from_cargo_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_colaborador_cargo_from_cargo_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."system_access_level"("system_slug" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."system_access_level"("system_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."system_access_level"("system_slug" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."veiculo_catalogo_access_level"() TO "anon";
GRANT ALL ON FUNCTION "public"."veiculo_catalogo_access_level"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."veiculo_catalogo_access_level"() TO "service_role";



GRANT ALL ON FUNCTION "public"."veiculo_catalogo_has_access"() TO "anon";
GRANT ALL ON FUNCTION "public"."veiculo_catalogo_has_access"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."veiculo_catalogo_has_access"() TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_commutator_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_dist_op"("text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."word_similarity_op"("text", "text") TO "service_role";












GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_crm"."clientes_crm" TO "authenticated";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_crm"."clientes_crm" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_crm"."propostas" TO "authenticated";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_crm"."propostas" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_crm"."veiculos_estoque" TO "authenticated";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_crm"."veiculos_estoque" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_crm"."vendas" TO "authenticated";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_crm"."vendas" TO "service_role";



GRANT SELECT ON TABLE "gestao_plataforma"."alertas_seguranca_enviados" TO "authenticated";
GRANT SELECT,INSERT ON TABLE "gestao_plataforma"."alertas_seguranca_enviados" TO "service_role";



GRANT ALL ON TABLE "gestao_plataforma"."bloqueios_login" TO "supabase_auth_admin";



GRANT SELECT ON TABLE "gestao_plataforma"."logs_acesso" TO "authenticated";
GRANT SELECT,INSERT ON TABLE "gestao_plataforma"."logs_acesso" TO "service_role";



GRANT SELECT ON TABLE "gestao_plataforma"."logs_auditoria" TO "authenticated";
GRANT SELECT,INSERT ON TABLE "gestao_plataforma"."logs_auditoria" TO "service_role";



GRANT SELECT,INSERT,DELETE ON TABLE "gestao_servicos"."anexos_solicitacao" TO "authenticated";
GRANT SELECT,INSERT,DELETE ON TABLE "gestao_servicos"."anexos_solicitacao" TO "service_role";



GRANT SELECT ON TABLE "gestao_servicos"."assinaturas_anexo" TO "authenticated";
GRANT SELECT,INSERT ON TABLE "gestao_servicos"."assinaturas_anexo" TO "service_role";



GRANT SELECT,INSERT,UPDATE ON TABLE "gestao_servicos"."categorias" TO "authenticated";
GRANT SELECT,INSERT,UPDATE ON TABLE "gestao_servicos"."categorias" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_servicos"."checklist_avaliacoes" TO "authenticated";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_servicos"."checklist_avaliacoes" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_servicos"."checklist_avarias" TO "authenticated";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_servicos"."checklist_avarias" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_servicos"."checklist_fotos" TO "authenticated";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_servicos"."checklist_fotos" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_servicos"."checklist_itens" TO "authenticated";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_servicos"."checklist_itens" TO "service_role";



GRANT SELECT,INSERT,UPDATE ON TABLE "gestao_servicos"."fornecedores" TO "authenticated";
GRANT SELECT,INSERT,UPDATE ON TABLE "gestao_servicos"."fornecedores" TO "service_role";



GRANT SELECT,INSERT ON TABLE "gestao_servicos"."historico_checklist" TO "authenticated";
GRANT SELECT,INSERT ON TABLE "gestao_servicos"."historico_checklist" TO "service_role";



GRANT SELECT,INSERT ON TABLE "gestao_servicos"."historico_solicitacao" TO "authenticated";
GRANT SELECT,INSERT ON TABLE "gestao_servicos"."historico_solicitacao" TO "service_role";



GRANT SELECT,UPDATE ON TABLE "gestao_servicos"."notificacoes" TO "authenticated";
GRANT SELECT,UPDATE ON TABLE "gestao_servicos"."notificacoes" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_servicos"."parcelas_pagamento" TO "authenticated";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_servicos"."parcelas_pagamento" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_servicos"."permissoes_modulo" TO "authenticated";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_servicos"."permissoes_modulo" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_servicos"."solicitacoes_pagamento" TO "authenticated";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "gestao_servicos"."solicitacoes_pagamento" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "integracoes"."integracoes" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "integracoes"."integracoes_secrets" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "notificacoes"."fila_emails" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "notificacoes"."notificacoes" TO "service_role";
GRANT SELECT,UPDATE ON TABLE "notificacoes"."notificacoes" TO "authenticated";



GRANT ALL ON TABLE "public"."acessos_usuario_sistema" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."acessos_usuario_sistema" TO "authenticated";
GRANT ALL ON TABLE "public"."acessos_usuario_sistema" TO "service_role";
GRANT SELECT ON TABLE "public"."acessos_usuario_sistema" TO "authenticator";



GRANT ALL ON TABLE "public"."avisos" TO "anon";
GRANT ALL ON TABLE "public"."avisos" TO "authenticated";
GRANT ALL ON TABLE "public"."avisos" TO "service_role";
GRANT SELECT ON TABLE "public"."avisos" TO "authenticator";



GRANT ALL ON TABLE "public"."avisos_aceites" TO "anon";
GRANT ALL ON TABLE "public"."avisos_aceites" TO "authenticated";
GRANT ALL ON TABLE "public"."avisos_aceites" TO "service_role";
GRANT SELECT ON TABLE "public"."avisos_aceites" TO "authenticator";



GRANT ALL ON TABLE "public"."cargos" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."cargos" TO "authenticated";
GRANT ALL ON TABLE "public"."cargos" TO "service_role";
GRANT SELECT ON TABLE "public"."cargos" TO "authenticator";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."categorias_veiculo" TO "authenticated";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."categorias_veiculo" TO "service_role";



GRANT ALL ON TABLE "public"."clientes" TO "anon";
GRANT ALL ON TABLE "public"."clientes" TO "authenticated";
GRANT ALL ON TABLE "public"."clientes" TO "service_role";
GRANT SELECT ON TABLE "public"."clientes" TO "authenticator";



GRANT ALL ON TABLE "public"."clientes_telefones_adicionais" TO "anon";
GRANT ALL ON TABLE "public"."clientes_telefones_adicionais" TO "authenticated";
GRANT ALL ON TABLE "public"."clientes_telefones_adicionais" TO "service_role";
GRANT SELECT ON TABLE "public"."clientes_telefones_adicionais" TO "authenticator";



GRANT ALL ON TABLE "public"."colaboradores" TO "anon";
GRANT ALL ON TABLE "public"."colaboradores" TO "authenticated";
GRANT ALL ON TABLE "public"."colaboradores" TO "service_role";
GRANT SELECT ON TABLE "public"."colaboradores" TO "authenticator";



GRANT ALL ON TABLE "public"."comunicados" TO "anon";
GRANT ALL ON TABLE "public"."comunicados" TO "authenticated";
GRANT ALL ON TABLE "public"."comunicados" TO "service_role";
GRANT SELECT ON TABLE "public"."comunicados" TO "authenticator";



GRANT ALL ON TABLE "public"."cores_veiculo" TO "anon";
GRANT ALL ON TABLE "public"."cores_veiculo" TO "authenticated";
GRANT ALL ON TABLE "public"."cores_veiculo" TO "service_role";
GRANT SELECT ON TABLE "public"."cores_veiculo" TO "authenticator";



GRANT ALL ON TABLE "public"."departamentos" TO "anon";
GRANT ALL ON TABLE "public"."departamentos" TO "authenticated";
GRANT ALL ON TABLE "public"."departamentos" TO "service_role";
GRANT SELECT ON TABLE "public"."departamentos" TO "authenticator";



GRANT ALL ON TABLE "public"."empresas" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."empresas" TO "authenticated";
GRANT ALL ON TABLE "public"."empresas" TO "service_role";
GRANT SELECT ON TABLE "public"."empresas" TO "authenticator";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."marcas_veiculo" TO "authenticated";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."marcas_veiculo" TO "service_role";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."modelos_veiculo" TO "authenticated";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."modelos_veiculo" TO "service_role";



GRANT ALL ON TABLE "public"."push_subscriptions" TO "anon";
GRANT ALL ON TABLE "public"."push_subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."push_subscriptions" TO "service_role";
GRANT SELECT ON TABLE "public"."push_subscriptions" TO "authenticator";



GRANT ALL ON TABLE "public"."sistemas" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."sistemas" TO "authenticated";
GRANT ALL ON TABLE "public"."sistemas" TO "service_role";
GRANT SELECT ON TABLE "public"."sistemas" TO "authenticator";



GRANT ALL ON TABLE "public"."unidades" TO "anon";
GRANT ALL ON TABLE "public"."unidades" TO "authenticated";
GRANT ALL ON TABLE "public"."unidades" TO "service_role";
GRANT SELECT ON TABLE "public"."unidades" TO "authenticator";



GRANT ALL ON TABLE "public"."veiculos" TO "anon";
GRANT ALL ON TABLE "public"."veiculos" TO "authenticated";
GRANT ALL ON TABLE "public"."veiculos" TO "service_role";
GRANT SELECT ON TABLE "public"."veiculos" TO "authenticator";



GRANT ALL ON TABLE "public"."veiculos_proprietarios" TO "anon";
GRANT ALL ON TABLE "public"."veiculos_proprietarios" TO "authenticated";
GRANT ALL ON TABLE "public"."veiculos_proprietarios" TO "service_role";
GRANT SELECT ON TABLE "public"."veiculos_proprietarios" TO "authenticator";



GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."versoes_veiculo" TO "authenticated";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."versoes_veiculo" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "gestao_crm" GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "gestao_crm" GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "notificacoes" GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT SELECT ON TABLES TO "authenticator";
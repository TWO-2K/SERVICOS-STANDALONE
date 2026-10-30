-- Unifica gestao_plataforma em plataforma. O prefixo gestao_* vinha do monorepo; hoje so existe o schema
-- plataforma para o dominio do painel. SET SCHEMA preserva dados, indices, constraints, policies e FKs
-- (tudo referencia o OID). Corpos de funcao que citam "gestao_plataforma" como texto sao reescritos abaixo.
--
-- ATENCAO: o hook de senha (Auth) muda de caminho. Logo apos aplicar, repontar em Dashboard ->
-- Authentication -> Hooks -> Password Verification Attempt para plataforma.hook_verificacao_senha.

do $$
declare
  r record;
begin
  for r in
    select c.oid, c.relname, c.relkind
    from pg_class c
    where c.relnamespace = 'gestao_plataforma'::regnamespace
      and c.relkind in ('r', 'p', 'v', 'm', 'S')
      and not (c.relkind = 'S' and exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype in ('a', 'i')))
    order by (c.relkind = 'S'), c.relname
  loop
    if exists (
      select 1 from pg_class c2 where c2.relnamespace = 'plataforma'::regnamespace and c2.relname = r.relname
    ) then
      raise exception 'plataforma.% ja existe; resolva o conflito antes de mover gestao_plataforma.%', r.relname, r.relname;
    end if;
    execute format(
      'alter %s gestao_plataforma.%I set schema plataforma',
      case r.relkind when 'S' then 'sequence' when 'v' then 'view' when 'm' then 'materialized view' else 'table' end,
      r.relname
    );
  end loop;

  for r in
    select p.oid::regprocedure as assinatura
    from pg_proc p
    where p.pronamespace = 'gestao_plataforma'::regnamespace
  loop
    execute format('alter function %s set schema plataforma', r.assinatura);
  end loop;

  for r in
    select t.typname
    from pg_type t
    where t.typnamespace = 'gestao_plataforma'::regnamespace
      and t.typtype in ('e', 'd')
  loop
    execute format('alter type gestao_plataforma.%I set schema plataforma', r.typname);
  end loop;

  -- Reescreve as funcoes cujo corpo ou search_path cita o schema antigo (o hook le/grava bloqueios_login).
  for r in
    select p.oid
    from pg_proc p
    where p.prokind = 'f'
      and (p.prosrc ilike '%gestao_plataforma%' or coalesce(p.proconfig::text, '') ilike '%gestao_plataforma%')
  loop
    execute replace(pg_get_functiondef(r.oid), 'gestao_plataforma', 'plataforma');
  end loop;
end $$;

-- O hook roda como supabase_auth_admin e as Edge Functions como service_role: precisam enxergar o schema.
-- authenticated recebia USAGE no schema antigo; os selects dele nas tabelas de log ja foram revogados em
-- 20260101001800, entao o USAGE aqui e inofensivo e mantem o comportamento anterior.
grant usage on schema plataforma to authenticated, service_role, supabase_auth_admin;

-- Sem CASCADE: falha se sobrar qualquer objeto.
drop schema gestao_plataforma;

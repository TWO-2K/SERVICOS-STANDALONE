-- Consolida o dominio do Servicos em public. O prefixo gestao_* vinha do monorepo; hoje so existem os apps
-- servicos e plataforma. SET SCHEMA preserva dados, indices, constraints, triggers, policies (inclusive
-- tenant_isolation) e FKs, porque tudo referencia o OID. Os grants existentes tambem acompanham a tabela.
-- O que precisa ser reescrito sao os corpos de funcao que citam "gestao_servicos" como texto.

do $$
declare
  r record;
begin
  -- Tabelas, sequences soltas (as de identity vao junto da tabela) e views.
  for r in
    select c.oid, c.relname, c.relkind
    from pg_class c
    where c.relnamespace = 'gestao_servicos'::regnamespace
      and c.relkind in ('r', 'p', 'v', 'm', 'S')
      and not (c.relkind = 'S' and exists (select 1 from pg_depend d where d.objid = c.oid and d.deptype in ('a', 'i')))
    order by (c.relkind = 'S'), c.relname
  loop
    if exists (
      select 1 from pg_class c2 where c2.relnamespace = 'public'::regnamespace and c2.relname = r.relname
    ) then
      raise exception 'public.% ja existe; resolva o conflito antes de mover gestao_servicos.%', r.relname, r.relname;
    end if;
    execute format(
      'alter %s gestao_servicos.%I set schema public',
      case r.relkind when 'S' then 'sequence' when 'v' then 'view' when 'm' then 'materialized view' else 'table' end,
      r.relname
    );
  end loop;

  -- Funcoes do schema.
  for r in
    select p.oid::regprocedure as assinatura
    from pg_proc p
    where p.pronamespace = 'gestao_servicos'::regnamespace
  loop
    execute format('alter function %s set schema public', r.assinatura);
  end loop;

  -- Tipos proprios (enums/compostos), se houver.
  for r in
    select t.typname
    from pg_type t
    where t.typnamespace = 'gestao_servicos'::regnamespace
      and t.typtype in ('e', 'd')
  loop
    execute format('alter type gestao_servicos.%I set schema public', r.typname);
  end loop;

  -- Reescreve as funcoes cujo corpo ou search_path cita o schema antigo.
  for r in
    select p.oid
    from pg_proc p
    where p.prokind = 'f'
      and (p.prosrc ilike '%gestao_servicos%' or coalesce(p.proconfig::text, '') ilike '%gestao_servicos%')
  loop
    execute replace(pg_get_functiondef(r.oid), 'gestao_servicos', 'public');
  end loop;
end $$;

-- Nada pode ter ficado para tras: sem CASCADE, o DROP falha se sobrar qualquer objeto.
drop schema gestao_servicos;

-- O dominio nunca foi exposto ao client (o schema ficava fora de [api].schemas). Agora ele esta em public,
-- que e exposto: anon nao precisa de nada aqui. O authenticated continua com o que ja tinha (o storage
-- consulta solicitacoes_pagamento/checklist_avaliacoes como authenticated), sempre filtrado pelo RLS.
revoke all on table
  public.anexos_solicitacao, public.assinaturas_anexo, public.categorias, public.checklist_avaliacoes,
  public.checklist_avarias, public.checklist_fotos, public.checklist_itens, public.configuracoes_modulo,
  public.contadores_tenant, public.fornecedores, public.historico_checklist, public.historico_solicitacao,
  public.notificacoes, public.parcelas_pagamento, public.permissoes_modulo, public.solicitacoes_pagamento
from anon;

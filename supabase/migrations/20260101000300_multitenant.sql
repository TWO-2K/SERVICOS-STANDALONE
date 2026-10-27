-- Multiempresa (SaaS): um tenant = um cliente da plataforma.
-- Hierarquia: tenant > empresas > unidades. Cada tabela de negocio carrega tenant_id e uma policy
-- RESTRICTIVE (soma-se, com AND, as policies de permissao ja existentes, sem reescreve-las).
--
-- Como o tenant e resolvido (public.current_tenant_id):
--   1. GUC app.tenant_id, setada pela Edge Function dentro da transacao da requisicao; ou
--   2. tenant do colaborador logado (auth.uid() / e-mail), para acesso direto via PostgREST.
-- Os INSERTs herdam o tenant por DEFAULT public.current_tenant_id(), sem mudar as queries.

-- Papel usado pelas Edge Functions (conexao direta ao Postgres): sem BYPASSRLS, entao a policy tenant_isolation vale
-- tambem para elas. As policies de permissao por usuario (auth.uid()) nao se aplicam a ele: a autorizacao fina
-- continua no codigo da function; o banco garante apenas o isolamento entre tenants.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'app_tenant') then
    create role app_tenant nologin noinherit;
  end if;
end $$;
grant app_tenant to postgres;

create table if not exists public.tenants (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  slug text not null,
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create unique index if not exists tenants_slug_unique on public.tenants (lower(slug));
alter table public.tenants enable row level security;

-- Tenant padrao: recebe os dados que ja existiam antes da migration.
insert into public.tenants (id, nome, slug)
values ('55555555-5555-5555-5555-555555555555', 'Tenant padrao', 'padrao')
on conflict (id) do nothing;

-- plpgsql (e nao sql) porque a coluna colaboradores.tenant_id so passa a existir mais abaixo nesta migration.
create or replace function public.current_tenant_id()
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return coalesce(
    nullif(current_setting('app.tenant_id', true), '')::uuid,
    (
      select c.tenant_id
      from public.colaboradores c
      where c.id = auth.uid()
         or lower(c.email) = lower(auth.email())
      order by case when c.id = auth.uid() then 0 else 1 end
      limit 1
    )
  );
end;
$$;

grant execute on function public.current_tenant_id() to authenticated, service_role;

-- Tabelas de negocio por tenant. Catalogos globais ficam de fora: public.sistemas e o catalogo de veiculos
-- (marcas, modelos, versoes, cores, categorias).
do $$
declare
  t text;
  tabelas text[] := array[
    'public.empresas', 'public.unidades', 'public.departamentos', 'public.cargos', 'public.colaboradores',
    'public.acessos_usuario_sistema', 'public.avisos', 'public.avisos_aceites', 'public.comunicados',
    'public.push_subscriptions', 'public.clientes', 'public.clientes_telefones_adicionais',
    'public.veiculos', 'public.veiculos_proprietarios',
    'gestao_servicos.anexos_solicitacao', 'gestao_servicos.assinaturas_anexo', 'gestao_servicos.categorias',
    'gestao_servicos.checklist_avaliacoes', 'gestao_servicos.checklist_avarias', 'gestao_servicos.checklist_fotos',
    'gestao_servicos.checklist_itens', 'gestao_servicos.configuracoes_modulo', 'gestao_servicos.fornecedores',
    'gestao_servicos.historico_checklist', 'gestao_servicos.historico_solicitacao', 'gestao_servicos.notificacoes',
    'gestao_servicos.parcelas_pagamento', 'gestao_servicos.permissoes_modulo', 'gestao_servicos.solicitacoes_pagamento',
    'gestao_crm.clientes_crm', 'gestao_crm.propostas', 'gestao_crm.veiculos_estoque', 'gestao_crm.vendas',
    'notificacoes.notificacoes'
  ];
  nome text;
begin
  foreach t in array tabelas loop
    nome := split_part(t, '.', 2);
    execute format('alter table %s add column if not exists tenant_id uuid references public.tenants(id)', t);
    execute format('update %s set tenant_id = %L where tenant_id is null', t, '55555555-5555-5555-5555-555555555555');
    execute format('alter table %s alter column tenant_id set default public.current_tenant_id()', t);
    execute format('alter table %s alter column tenant_id set not null', t);
    execute format('create index if not exists %I on %s (tenant_id)', 'idx_' || nome || '_tenant_id', t);
    execute format('alter table %s enable row level security', t);
    execute format('drop policy if exists tenant_isolation on %s', t);
    execute format(
      'create policy tenant_isolation on %s as restrictive for all to authenticated, app_tenant '
      || 'using (tenant_id = (select public.current_tenant_id())) '
      || 'with check (tenant_id = (select public.current_tenant_id()))', t);
  end loop;
end $$;

create policy tenants_select_proprio on public.tenants
  for select to authenticated using (id = (select public.current_tenant_id()));

-- Unicidades que eram globais passam a valer dentro do tenant.
drop index if exists public.empresas_nome_unique;
drop index if exists public.empresas_slug_unique;
create unique index empresas_nome_unique on public.empresas (tenant_id, lower(nome));
create unique index empresas_slug_unique on public.empresas (tenant_id, slug);

alter table public.unidades drop constraint if exists unidades_nome_key;
create unique index unidades_nome_unique on public.unidades (tenant_id, nome);

alter table public.departamentos drop constraint if exists departamentos_nome_key;
create unique index departamentos_nome_unique on public.departamentos (tenant_id, nome);

drop index if exists public.cargos_nome_departamento_unique;
drop index if exists public.cargos_nome_sem_departamento_unique;
create unique index cargos_nome_departamento_unique on public.cargos (tenant_id, lower(nome), departamento_id)
  where departamento_id is not null;
create unique index cargos_nome_sem_departamento_unique on public.cargos (tenant_id, lower(nome))
  where departamento_id is null;

-- e-mail continua global: o login (auth.users) e global.
alter table public.colaboradores drop constraint if exists colaboradores_cpf_key;
alter table public.colaboradores drop constraint if exists colaboradores_telefone_key;
drop index if exists public.colaboradores_telefone_unique_idx;
create unique index colaboradores_cpf_unique on public.colaboradores (tenant_id, cpf);
create unique index colaboradores_telefone_unique_idx on public.colaboradores (tenant_id, telefone)
  where telefone is not null;

drop index if exists public.avisos_one_active_per_sistema_idx;
create unique index avisos_one_active_per_sistema_idx on public.avisos (tenant_id, sistema_slug) where ativo = true;

drop index if exists public.idx_clientes_cpf_cnpj_unique;
drop index if exists public.idx_clientes_email_unique;
drop index if exists public.idx_clientes_telefone_unique;
create unique index idx_clientes_cpf_cnpj_unique on public.clientes (tenant_id, cpf_cnpj_normalizado)
  where cpf_cnpj_normalizado is not null and cpf_cnpj_normalizado <> '';
create unique index idx_clientes_email_unique on public.clientes (tenant_id, email_normalizado)
  where email_normalizado is not null and email_normalizado <> '';
create unique index idx_clientes_telefone_unique on public.clientes (tenant_id, telefone_normalizado);

drop index if exists public.idx_clientes_telefones_adicionais_normalizado_unique;
create unique index idx_clientes_telefones_adicionais_normalizado_unique
  on public.clientes_telefones_adicionais (tenant_id, telefone_normalizado);

drop index if exists public.idx_veiculos_placa_unique;
alter table public.veiculos drop constraint if exists veiculos_chassi_key;
create unique index idx_veiculos_placa_unique on public.veiculos (tenant_id, placa)
  where placa is not null and placa <> '';
create unique index veiculos_chassi_unique on public.veiculos (tenant_id, chassi);

drop index if exists gestao_servicos.idx_servicos_categorias_nome;
create unique index idx_servicos_categorias_nome on gestao_servicos.categorias (tenant_id, lower(nome));

drop index if exists gestao_servicos.idx_servicos_fornecedores_documento;
drop index if exists gestao_servicos.idx_servicos_fornecedores_nome;
create unique index idx_servicos_fornecedores_documento on gestao_servicos.fornecedores (tenant_id, documento)
  where documento is not null and documento <> '';
create unique index idx_servicos_fornecedores_nome on gestao_servicos.fornecedores (tenant_id, lower(nome));

alter table gestao_servicos.configuracoes_modulo drop constraint if exists configuracoes_modulo_modulo_unico;
drop index if exists gestao_servicos.configuracoes_modulo_modulo_unico;
create unique index configuracoes_modulo_modulo_unico on gestao_servicos.configuracoes_modulo (tenant_id, modulo);

-- Usuario novo nasce no tenant informado em raw_user_meta_data.tenant_id (criacao de usuarios pelo admin).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tenant uuid := nullif(new.raw_user_meta_data ->> 'tenant_id', '')::uuid;
begin
  if v_tenant is null then
    raise exception 'Usuario sem tenant_id em raw_user_meta_data.';
  end if;

  insert into public.colaboradores (id, nome, email, funcao, status, tenant_id)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    new.email,
    coalesce(new.raw_user_meta_data ->> 'funcao', 'usuario'),
    'ativo',
    v_tenant
  )
  on conflict (id) do update
  set nome = excluded.nome,
      email = excluded.email,
      funcao = excluded.funcao,
      status = coalesce(public.colaboradores.status, 'ativo'),
      atualizado_em = now();

  return new;
end;
$$;

-- Legado da intranet, sem trigger ligado e sem tenant.
drop function if exists public.sync_auth_user_to_colaborador();

-- Libera o papel app_tenant (grants + policy permissiva; o isolamento vem da policy RESTRICTIVE acima).
do $$
declare
  s text;
  r record;
begin
  foreach s in array array['public', 'gestao_servicos', 'gestao_crm', 'gestao_plataforma', 'integracoes', 'notificacoes'] loop
    execute format('grant usage on schema %I to app_tenant', s);
    execute format('grant all on all tables in schema %I to app_tenant', s);
    execute format('grant all on all sequences in schema %I to app_tenant', s);
    execute format('grant execute on all functions in schema %I to app_tenant', s);
    for r in
      select c.relname from pg_class c
      where c.relnamespace = s::regnamespace and c.relkind in ('r', 'p') and c.relrowsecurity
    loop
      execute format('drop policy if exists app_tenant_all on %I.%I', s, r.relname);
      execute format('create policy app_tenant_all on %I.%I for all to app_tenant using (true) with check (true)', s, r.relname);
    end loop;
  end loop;
end $$;

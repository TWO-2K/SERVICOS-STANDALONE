-- Administracao da plataforma (dono do SaaS): quem pode criar e desativar tenants.
-- Fica fora de qualquer tenant. RLS ligado e SEM policies: so o dono do banco (Edge Function admin-api,
-- fora da transacao por tenant) enxerga estas tabelas.
create schema if not exists plataforma;

create table if not exists plataforma.administradores (
  user_id uuid primary key references auth.users(id) on delete cascade,
  criado_em timestamptz not null default now()
);
alter table plataforma.administradores enable row level security;
revoke all on schema plataforma from public, anon, authenticated;
revoke all on all tables in schema plataforma from public, anon, authenticated;

alter table public.tenants add column if not exists plano text not null default 'padrao';

-- Tenant desativado nao enxerga nem grava nada: current_tenant_id() passa a devolver null.
create or replace function public.current_tenant_id()
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_tenant uuid;
begin
  v_tenant := nullif(current_setting('app.tenant_id', true), '')::uuid;

  if v_tenant is null then
    select c.tenant_id
      into v_tenant
    from public.colaboradores c
    where c.id = auth.uid()
       or lower(c.email) = lower(auth.email())
    order by case when c.id = auth.uid() then 0 else 1 end
    limit 1;
  end if;

  if v_tenant is not null and not exists (select 1 from public.tenants t where t.id = v_tenant and t.ativo) then
    return null;
  end if;

  return v_tenant;
end;
$$;

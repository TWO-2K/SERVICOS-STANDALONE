-- Trilha de auditoria das acoes administrativas (clientes, usuarios, administradores da plataforma, integracoes).
-- Fora de qualquer tenant; RLS ligado e sem policies: so o dono do banco (admin-api, pool dono) le e grava.
create table if not exists plataforma.auditoria (
  id uuid primary key default gen_random_uuid(),
  criado_em timestamptz not null default now(),
  ator_id uuid,
  ator_email text,
  tenant_id uuid references public.tenants(id) on delete set null,
  acao text not null,
  alvo text,
  detalhes jsonb not null default '{}'::jsonb
);

create index if not exists idx_auditoria_criado_em on plataforma.auditoria (criado_em desc);
create index if not exists idx_auditoria_tenant_id on plataforma.auditoria (tenant_id);

alter table plataforma.auditoria enable row level security;
revoke all on plataforma.auditoria from public, anon, authenticated, app_tenant;

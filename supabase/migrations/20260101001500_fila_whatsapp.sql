-- Fila de WhatsApp por cliente (so a separacao: ainda nao ha provedor nem worker). Cada mensagem pertence a um
-- tenant; quando um provedor for ligado, o worker usa as credenciais da integracao `whatsapp` do tenant da linha
-- (integracoes.integracoes, segredos no Vault) e nunca as de outro cliente. Mesmo desenho de notificacoes.fila_emails.
create table if not exists notificacoes.fila_whatsapp (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null default public.current_tenant_id() references public.tenants(id) on delete cascade,
  tipo text not null,
  destinatario text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pendente' check (status in ('pendente', 'processando', 'enviado', 'erro')),
  tentativas integer not null default 0,
  max_tentativas integer not null default 5,
  agendado_em timestamptz not null default now(),
  erro text,
  enviado_em timestamptz,
  processado_em timestamptz,
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create index if not exists idx_fila_whatsapp_tenant_id on notificacoes.fila_whatsapp (tenant_id);
create index if not exists idx_fila_whatsapp_pendentes on notificacoes.fila_whatsapp (agendado_em) where status = 'pendente';

alter table notificacoes.fila_whatsapp enable row level security;
create policy tenant_isolation on notificacoes.fila_whatsapp as restrictive for all to authenticated, app_tenant
  using (tenant_id = (select public.current_tenant_id()))
  with check (tenant_id = (select public.current_tenant_id()));
create policy app_tenant_all on notificacoes.fila_whatsapp for all to app_tenant using (true) with check (true);

revoke all on notificacoes.fila_whatsapp from anon, authenticated;
grant select, insert, update, delete on notificacoes.fila_whatsapp to app_tenant;

-- Integracoes (credenciais Gmail/WhatsApp etc.) e fila de e-mails passam a ser por tenant.
-- Cada cliente cadastra suas proprias credenciais; nenhum envio usa a conta de outro cliente.

-- ---------------------------------------------------------------------------
-- integracoes.integracoes: uma linha por (tenant, chave).
-- Segredos ficam no Vault e so sao lidos por get_credenciais (service_role); o papel app_tenant
-- e o usuario autenticado nunca enxergam este schema.
-- ---------------------------------------------------------------------------
alter table integracoes.integracoes
  add column if not exists tenant_id uuid references public.tenants(id) on delete cascade;
update integracoes.integracoes set tenant_id = '55555555-5555-5555-5555-555555555555' where tenant_id is null;
alter table integracoes.integracoes alter column tenant_id set not null;
create index if not exists idx_integracoes_tenant_id on integracoes.integracoes (tenant_id);

alter table integracoes.integracoes drop constraint if exists integracoes_chave_key;
create unique index integracoes_tenant_chave_unique on integracoes.integracoes (tenant_id, chave);

drop policy if exists app_tenant_all on integracoes.integracoes;
drop policy if exists app_tenant_all on integracoes.integracoes_secrets;
revoke all on all tables in schema integracoes from app_tenant, authenticated, anon;
revoke all on all functions in schema integracoes from app_tenant, authenticated, anon;
revoke usage on schema integracoes from app_tenant, authenticated, anon;

drop function if exists integracoes.get_credenciais(text);

create or replace function integracoes.get_credenciais(p_chave text, p_tenant_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'integracoes', 'vault', 'pg_temp'
as $$
declare
  integracao_row integracoes.integracoes%rowtype;
  result jsonb;
  secret_row record;
begin
  if p_tenant_id is null then
    return null;
  end if;

  select * into integracao_row
  from integracoes.integracoes
  where chave = p_chave
    and tenant_id = p_tenant_id
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

alter function integracoes.get_credenciais(text, uuid) owner to postgres;
revoke all on function integracoes.get_credenciais(text, uuid) from public;
grant execute on function integracoes.get_credenciais(text, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- notificacoes.fila_emails: cada e-mail enfileirado pertence a um tenant (o worker usa o tenant da
-- linha para escolher as credenciais). Antes nao tinha RLS, entao app_tenant enxergava a fila toda.
-- ---------------------------------------------------------------------------
alter table notificacoes.fila_emails
  add column if not exists tenant_id uuid references public.tenants(id) on delete cascade;
update notificacoes.fila_emails set tenant_id = '55555555-5555-5555-5555-555555555555' where tenant_id is null;
alter table notificacoes.fila_emails alter column tenant_id set default public.current_tenant_id();
alter table notificacoes.fila_emails alter column tenant_id set not null;
create index if not exists idx_fila_emails_tenant_id on notificacoes.fila_emails (tenant_id);

alter table notificacoes.fila_emails enable row level security;
drop policy if exists tenant_isolation on notificacoes.fila_emails;
create policy tenant_isolation on notificacoes.fila_emails as restrictive for all to authenticated, app_tenant
  using (tenant_id = (select public.current_tenant_id()))
  with check (tenant_id = (select public.current_tenant_id()));
drop policy if exists app_tenant_all on notificacoes.fila_emails;
create policy app_tenant_all on notificacoes.fila_emails for all to app_tenant using (true) with check (true);

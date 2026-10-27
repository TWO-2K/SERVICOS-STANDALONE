-- Agenda os workers em segundo plano (fila de e-mail e lembrete de aprovacoes) com pg_cron + pg_net.
-- Nada sensivel fica na migration: a URL base das functions e o segredo vem do Vault, por ambiente:
--   select vault.create_secret('https://<ref>.supabase.co/functions/v1', 'functions_base_url');
--   select vault.create_secret('<mesmo valor de INTERNAL_INVOKE_SECRET>', 'internal_invoke_secret');
-- Sem os dois segredos o job nao faz nada (so registra um aviso), entao e seguro aplicar em qualquer ambiente.
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;

create or replace function plataforma.invocar_function(p_nome text)
returns bigint
language plpgsql
security definer
set search_path = plataforma, vault, extensions, pg_temp
as $$
declare
  v_base text;
  v_secret text;
begin
  select decrypted_secret into v_base from vault.decrypted_secrets where name = 'functions_base_url' limit 1;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'internal_invoke_secret' limit 1;
  if v_base is null or v_secret is null then
    raise warning 'invocar_function(%): segredos functions_base_url/internal_invoke_secret ausentes no Vault', p_nome;
    return null;
  end if;
  return net.http_post(
    url := rtrim(v_base, '/') || '/' || p_nome,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-invoke-secret', v_secret),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000
  );
end;
$$;

-- Fila de e-mail: so chama a function quando ha algo pendente (evita uma invocacao por minuto sem necessidade).
create or replace function plataforma.processar_fila_email_se_pendente()
returns void
language plpgsql
security definer
set search_path = plataforma, notificacoes, pg_temp
as $$
begin
  if exists (
    select 1 from notificacoes.fila_emails
    where status = 'pendente' and agendado_em <= now() and tentativas < max_tentativas
  ) then
    perform plataforma.invocar_function('processa-fila-email');
  end if;
end;
$$;

revoke all on function plataforma.invocar_function(text) from public, anon, authenticated, app_tenant;
revoke all on function plataforma.processar_fila_email_se_pendente() from public, anon, authenticated, app_tenant;

select cron.unschedule(jobname) from cron.job
where jobname in ('processa-fila-email-every-minute', 'servicos-lembrete-aprovacoes-hourly');

select cron.schedule('processa-fila-email-every-minute', '* * * * *',
  $job$select plataforma.processar_fila_email_se_pendente();$job$);
select cron.schedule('servicos-lembrete-aprovacoes-hourly', '0 * * * *',
  $job$select plataforma.invocar_function('servicos-lembrete-aprovacoes');$job$);

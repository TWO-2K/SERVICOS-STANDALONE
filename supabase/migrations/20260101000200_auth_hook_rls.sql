-- O hook de lockout roda como supabase_auth_admin, que no Supabase local nao ignora RLS.
-- Policy explicita (so esse papel) para o hook poder ler/gravar a tabela.
create policy "auth_admin_bloqueios_login" on gestao_plataforma.bloqueios_login
  as permissive for all to supabase_auth_admin using (true) with check (true);

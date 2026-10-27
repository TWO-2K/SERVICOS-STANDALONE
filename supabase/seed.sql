-- Dados minimos para uso local. Login: admin@servicos.local / Servicos@123
select set_config('app.tenant_id', '55555555-5555-5555-5555-555555555555', false);
insert into public.sistemas (slug, nome, descricao)
values ('servicos', 'Servicos', 'Financeiro e Oficina')
on conflict (slug) do nothing;

insert into public.empresas (id, nome, slug)
values ('11111111-1111-1111-1111-111111111111', 'Empresa Demo', 'empresa-demo')
on conflict do nothing;

insert into public.unidades (id, nome, cidade, empresa_id)
values ('22222222-2222-2222-2222-222222222222', 'Matriz', 'Cidade Demo', '11111111-1111-1111-1111-111111111111')
on conflict do nothing;

insert into public.departamentos (id, nome)
values ('33333333-3333-3333-3333-333333333333', 'Administrativo')
on conflict do nothing;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change
) values (
  '00000000-0000-0000-0000-000000000000', '44444444-4444-4444-4444-444444444444',
  'authenticated', 'authenticated', 'admin@servicos.local', extensions.crypt('Servicos@123', extensions.gen_salt('bf')),
  now(), '{"provider":"email","providers":["email"]}', '{}', now(), now(), '', '', '', ''
) on conflict (id) do nothing;

insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
values (
  gen_random_uuid(), '44444444-4444-4444-4444-444444444444', '44444444-4444-4444-4444-444444444444', 'email',
  '{"sub":"44444444-4444-4444-4444-444444444444","email":"admin@servicos.local","email_verified":true}',
  now(), now(), now()
) on conflict do nothing;

insert into public.colaboradores (id, nome, email, funcao, departamento_id, unidade_id, empresa_id, precisa_trocar_senha)
values ('44444444-4444-4444-4444-444444444444', 'Administrador', 'admin@servicos.local', 'admin',
  '33333333-3333-3333-3333-333333333333', '22222222-2222-2222-2222-222222222222',
  '11111111-1111-1111-1111-111111111111', false)
on conflict (id) do nothing;

insert into public.acessos_usuario_sistema (colaborador_id, sistema_id, nivel_acesso)
select '44444444-4444-4444-4444-444444444444', id, 'admin' from public.sistemas where slug = 'servicos'
on conflict do nothing;

-- Configuracao padrao do modulo Financeiro (mesma linha que a migration original semeava).
insert into gestao_servicos.configuracoes_modulo (modulo, restringir_visibilidade_pagamento_dinheiro)
values ('financeiro', true)
on conflict (tenant_id, modulo) do nothing;

-- O admin local tambem e administrador da plataforma (cria e desativa tenants).
insert into plataforma.administradores (user_id)
values ('44444444-4444-4444-4444-444444444444')
on conflict do nothing;

-- Segredos do agendamento (migration 20260101001200) para o ambiente local. Em producao crie os seus no Vault.
select vault.create_secret('http://kong:8000/functions/v1', 'functions_base_url')
where not exists (select 1 from vault.secrets where name = 'functions_base_url');
select vault.create_secret('local-dev-secret', 'internal_invoke_secret')
where not exists (select 1 from vault.secrets where name = 'internal_invoke_secret');

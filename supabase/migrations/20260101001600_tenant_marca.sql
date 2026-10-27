-- Marca (identidade visual) por cliente: nome exibido, cor principal e logo. A tela de login precisa da marca ANTES de
-- o usuario existir, entao ela e servida por uma function publica (marca-publica) a partir do slug do cliente.
alter table public.tenants
  add column if not exists marca_nome text,
  add column if not exists marca_cor text,
  add column if not exists marca_logo_path text;

alter table public.tenants
  drop constraint if exists tenants_marca_cor_check,
  add constraint tenants_marca_cor_check check (marca_cor is null or marca_cor ~ '^#[0-9a-fA-F]{6}$'),
  drop constraint if exists tenants_marca_nome_check,
  add constraint tenants_marca_nome_check check (marca_nome is null or char_length(marca_nome) between 1 and 60);

-- Logos sao publicas por natureza (aparecem na tela de login). Escrita so pela service role, via admin-api
-- (sem policy de insert/update/delete para os papeis do app).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('marcas', 'marcas', true, 524288, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do update
  set public = true, file_size_limit = 524288, allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp'];

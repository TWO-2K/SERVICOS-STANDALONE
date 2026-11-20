-- Imagem de fundo da tela de login, por cliente. Sem imagem, o login usa o gradiente padrao (generico).
alter table public.tenants
  add column if not exists marca_fundo_path text;

-- Fotos de fundo pesam mais que logos: eleva o limite do bucket publico "marcas".
update storage.buckets
  set file_size_limit = 2097152
  where id = 'marcas';

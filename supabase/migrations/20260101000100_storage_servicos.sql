-- Buckets e policies de Storage usados pelo Servicos. O dump do schema nao inclui o schema `storage`,
-- entao estao aqui (extraidos das migrations originais, ja com o slug 'servicos').

insert into storage.buckets (id, name, public)
values ('comprovantes-pagamento', 'comprovantes-pagamento', false)
on conflict (id) do nothing;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('oficina-checklist-fotos', 'oficina-checklist-fotos', false, 8388608, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
set file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('assinaturas', 'assinaturas', true, 524288, array['image/png'])
on conflict (id) do update
set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create policy "storage_comprovantes_pagamento_read_authenticated" on storage.objects for select to authenticated
  using (bucket_id = 'comprovantes-pagamento' and public.has_system_access('servicos'));
create policy "storage_comprovantes_pagamento_write_authenticated" on storage.objects for insert to authenticated
  with check (bucket_id = 'comprovantes-pagamento' and public.has_system_access('servicos'));
create policy "storage_comprovantes_pagamento_update_authenticated" on storage.objects for update to authenticated
  using (bucket_id = 'comprovantes-pagamento' and public.has_system_access('servicos'))
  with check (bucket_id = 'comprovantes-pagamento' and public.has_system_access('servicos'));
create policy "storage_comprovantes_pagamento_delete_authenticated" on storage.objects for delete to authenticated
  using (bucket_id = 'comprovantes-pagamento' and public.has_system_access('servicos'));

create policy "storage_oficina_checklist_fotos_read" on storage.objects for select to authenticated
  using (bucket_id = 'oficina-checklist-fotos' and public.servicos_oficina_pode_ver());
create policy "storage_oficina_checklist_fotos_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'oficina-checklist-fotos' and public.servicos_oficina_pode_editar());
create policy "storage_oficina_checklist_fotos_update" on storage.objects for update to authenticated
  using (bucket_id = 'oficina-checklist-fotos' and public.servicos_oficina_pode_editar())
  with check (bucket_id = 'oficina-checklist-fotos' and public.servicos_oficina_pode_editar());
create policy "storage_oficina_checklist_fotos_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'oficina-checklist-fotos' and public.servicos_oficina_pode_editar());

create policy "storage_assinaturas_read_authenticated" on storage.objects for select to authenticated
  using (bucket_id = 'assinaturas');
create policy "storage_assinaturas_insert_own_profile" on storage.objects for insert to authenticated
  with check (bucket_id = 'assinaturas' and (storage.foldername(name))[1] = 'colaboradores'
    and (storage.foldername(name))[2] = auth.uid()::text);
create policy "storage_assinaturas_update_own_profile" on storage.objects for update to authenticated
  using (bucket_id = 'assinaturas' and (storage.foldername(name))[1] = 'colaboradores'
    and (storage.foldername(name))[2] = auth.uid()::text)
  with check (bucket_id = 'assinaturas' and (storage.foldername(name))[1] = 'colaboradores'
    and (storage.foldername(name))[2] = auth.uid()::text);
create policy "storage_assinaturas_delete_own_profile" on storage.objects for delete to authenticated
  using (bucket_id = 'assinaturas' and (storage.foldername(name))[1] = 'colaboradores'
    and (storage.foldername(name))[2] = auth.uid()::text);

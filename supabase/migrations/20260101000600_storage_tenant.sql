-- Storage por tenant. Os caminhos dos arquivos comecam pelo id da solicitacao (comprovantes) ou da avaliacao
-- (fotos do checklist). As policies passam a exigir que esse id exista para o tenant do usuario: o SELECT
-- interno e filtrado pelo RLS (tenant_isolation), entao arquivo de outro cliente nunca e visivel nem gravavel.

create or replace function public.storage_pasta_e_do_tenant(p_bucket text, p_name text)
returns boolean
language plpgsql
stable
as $$
declare
  v_pasta text := (storage.foldername(p_name))[1];
begin
  if v_pasta is null or v_pasta !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    return false;
  end if;
  if p_bucket = 'comprovantes-pagamento' then
    return exists (select 1 from gestao_servicos.solicitacoes_pagamento s where s.id = v_pasta::uuid);
  elsif p_bucket = 'oficina-checklist-fotos' then
    return exists (select 1 from gestao_servicos.checklist_avaliacoes a where a.id = v_pasta::uuid);
  end if;
  return false;
end;
$$;

grant execute on function public.storage_pasta_e_do_tenant(text, text) to authenticated;

drop policy if exists "storage_comprovantes_pagamento_read_authenticated" on storage.objects;
drop policy if exists "storage_comprovantes_pagamento_write_authenticated" on storage.objects;
drop policy if exists "storage_comprovantes_pagamento_update_authenticated" on storage.objects;
drop policy if exists "storage_comprovantes_pagamento_delete_authenticated" on storage.objects;

create policy "storage_comprovantes_pagamento_read_authenticated" on storage.objects for select to authenticated
  using (bucket_id = 'comprovantes-pagamento' and public.has_system_access('servicos')
    and public.storage_pasta_e_do_tenant(bucket_id, name));
create policy "storage_comprovantes_pagamento_write_authenticated" on storage.objects for insert to authenticated
  with check (bucket_id = 'comprovantes-pagamento' and public.has_system_access('servicos')
    and public.storage_pasta_e_do_tenant(bucket_id, name));
create policy "storage_comprovantes_pagamento_update_authenticated" on storage.objects for update to authenticated
  using (bucket_id = 'comprovantes-pagamento' and public.has_system_access('servicos')
    and public.storage_pasta_e_do_tenant(bucket_id, name))
  with check (bucket_id = 'comprovantes-pagamento' and public.has_system_access('servicos')
    and public.storage_pasta_e_do_tenant(bucket_id, name));
create policy "storage_comprovantes_pagamento_delete_authenticated" on storage.objects for delete to authenticated
  using (bucket_id = 'comprovantes-pagamento' and public.has_system_access('servicos')
    and public.storage_pasta_e_do_tenant(bucket_id, name));

drop policy if exists "storage_oficina_checklist_fotos_read" on storage.objects;
drop policy if exists "storage_oficina_checklist_fotos_insert" on storage.objects;
drop policy if exists "storage_oficina_checklist_fotos_update" on storage.objects;
drop policy if exists "storage_oficina_checklist_fotos_delete" on storage.objects;

create policy "storage_oficina_checklist_fotos_read" on storage.objects for select to authenticated
  using (bucket_id = 'oficina-checklist-fotos' and public.servicos_oficina_pode_ver()
    and public.storage_pasta_e_do_tenant(bucket_id, name));
create policy "storage_oficina_checklist_fotos_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'oficina-checklist-fotos' and public.servicos_oficina_pode_editar()
    and public.storage_pasta_e_do_tenant(bucket_id, name));
create policy "storage_oficina_checklist_fotos_update" on storage.objects for update to authenticated
  using (bucket_id = 'oficina-checklist-fotos' and public.servicos_oficina_pode_editar()
    and public.storage_pasta_e_do_tenant(bucket_id, name))
  with check (bucket_id = 'oficina-checklist-fotos' and public.servicos_oficina_pode_editar()
    and public.storage_pasta_e_do_tenant(bucket_id, name));
create policy "storage_oficina_checklist_fotos_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'oficina-checklist-fotos' and public.servicos_oficina_pode_editar()
    and public.storage_pasta_e_do_tenant(bucket_id, name));

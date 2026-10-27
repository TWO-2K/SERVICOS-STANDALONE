-- Bucket `assinaturas` (publico: a imagem e servida pela URL com nome aleatorio, usada em PDFs e no checklist
-- publico). A policy de SELECT liberava listar/ler qualquer arquivo do bucket para qualquer usuario autenticado,
-- o que permitia enumerar as assinaturas de todos os clientes. Agora so enxerga as de colaboradores do
-- proprio tenant.

-- SECURITY DEFINER porque `authenticated` nao le public.colaboradores direto (so as Edge Functions leem).
create or replace function public.colaborador_e_do_tenant(p_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select exists (
    select 1 from public.colaboradores c
    where c.id = p_id and c.tenant_id = public.current_tenant_id()
  );
$$;

revoke all on function public.colaborador_e_do_tenant(uuid) from public;
grant execute on function public.colaborador_e_do_tenant(uuid) to authenticated;

drop policy if exists "storage_assinaturas_read_authenticated" on storage.objects;

create policy "storage_assinaturas_read_authenticated" on storage.objects for select to authenticated
  using (
    bucket_id = 'assinaturas'
    and (storage.foldername(name))[1] = 'colaboradores'
    and (storage.foldername(name))[2] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    and public.colaborador_e_do_tenant(((storage.foldername(name))[2])::uuid)
  );

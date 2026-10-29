-- O "Tenant padrao" (slug padrao) e o cliente de teste fixo: nao pode ser excluido nem desativado.
create or replace function public.proteger_tenant_padrao()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'O cliente padrao e fixo e nao pode ser excluido.' using errcode = 'P0001';
  end if;
  if new.ativo is false then
    raise exception 'O cliente padrao e fixo e nao pode ser desativado.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

drop trigger if exists tenant_padrao_fixo on public.tenants;
create trigger tenant_padrao_fixo
  before update or delete on public.tenants
  for each row
  when (old.id = '55555555-5555-5555-5555-555555555555')
  execute function public.proteger_tenant_padrao();

-- Exclusao definitiva de um cliente (chamada so pela admin-api, com o pool dono do banco).
-- As tabelas de negocio referenciam public.tenants sem cascade e ha FKs RESTRICT entre elas, entao apaga em
-- varias passadas: cada tabela e tentada num sub-bloco e as que ainda tem dependentes ficam para a passada
-- seguinte. Tudo corre numa transacao so (se algo falhar, nada e apagado).
create or replace function plataforma.excluir_tenant(p_id uuid)
returns void
language plpgsql
as $$
declare
  r record;
  pendente boolean;
  progresso boolean;
  n bigint;
  passo int := 0;
begin
  if p_id = '55555555-5555-5555-5555-555555555555' then
    raise exception 'O cliente padrao e fixo e nao pode ser excluido.';
  end if;
  if not exists (select 1 from public.tenants where id = p_id) then
    raise exception 'Cliente nao encontrado.';
  end if;

  perform set_config('app.tenant_id', p_id::text, true);

  loop
    passo := passo + 1;
    pendente := false;
    progresso := false;
    for r in
      select distinct c.conrelid::regclass as tabela
      from pg_constraint c
      where c.contype = 'f'
        and c.confrelid = 'public.tenants'::regclass
        and c.confdeltype in ('a', 'r')
        and c.conrelid <> 'public.tenants'::regclass
    loop
      begin
        execute format('delete from %s where tenant_id = $1', r.tabela) using p_id;
        get diagnostics n = row_count;
        if n > 0 then progresso := true; end if;
      exception when foreign_key_violation then
        pendente := true;
      end;
    end loop;
    exit when not pendente;
    if not progresso or passo > 50 then
      raise exception 'Nao foi possivel excluir os dados do cliente (dependencias entre tabelas).';
    end if;
  end loop;

  delete from public.tenants where id = p_id;
end;
$$;

revoke all on function plataforma.excluir_tenant(uuid) from public, anon, authenticated;

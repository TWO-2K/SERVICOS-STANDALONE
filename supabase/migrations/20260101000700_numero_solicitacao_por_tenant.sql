-- Numero da solicitacao por tenant: cada cliente comeca do 1 (antes era um identity global da base inteira,
-- o que expunha o volume de outros clientes e misturava a numeracao).

create table gestao_servicos.contadores_tenant (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  nome text not null,
  ultimo bigint not null default 0,
  primary key (tenant_id, nome)
);
alter table gestao_servicos.contadores_tenant enable row level security;
revoke all on gestao_servicos.contadores_tenant from public, anon, authenticated, app_tenant;

-- Mantem a numeracao ja existente: o contador de cada tenant parte do maior numero atual.
insert into gestao_servicos.contadores_tenant (tenant_id, nome, ultimo)
select tenant_id, 'solicitacao', max(numero) from gestao_servicos.solicitacoes_pagamento group by tenant_id;

alter table gestao_servicos.solicitacoes_pagamento alter column numero drop identity;
drop index if exists gestao_servicos.idx_servicos_solicitacoes_numero;
create unique index idx_servicos_solicitacoes_numero on gestao_servicos.solicitacoes_pagamento (tenant_id, numero);

-- SECURITY DEFINER: o contador e fechado para os papeis da aplicacao. O upsert e atomico, entao inserts
-- concorrentes do mesmo tenant nunca recebem o mesmo numero.
create or replace function gestao_servicos.atribuir_numero_solicitacao()
returns trigger
language plpgsql
security definer
set search_path to 'gestao_servicos', 'pg_temp'
as $$
begin
  insert into gestao_servicos.contadores_tenant as c (tenant_id, nome, ultimo)
  values (new.tenant_id, 'solicitacao', 1)
  on conflict (tenant_id, nome) do update set ultimo = c.ultimo + 1
  returning c.ultimo into new.numero;
  return new;
end;
$$;

drop sequence if exists gestao_servicos.solicitacoes_pagamento_numero_seq;

create trigger trg_solicitacoes_atribuir_numero
  before insert on gestao_servicos.solicitacoes_pagamento
  for each row execute function gestao_servicos.atribuir_numero_solicitacao();

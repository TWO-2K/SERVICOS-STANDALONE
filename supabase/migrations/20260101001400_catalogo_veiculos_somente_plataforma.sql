-- Os catalogos de veiculo (marcas, modelos, versoes, cores, categorias) sao globais: valem para todos os clientes.
-- As policies "manage" davam escrita direta (REST) a qualquer admin/gestor de qualquer cliente, o que permitia
-- renomear ou apagar itens usados por todos. Passa a ser so leitura para `authenticated`; quem escreve e' a
-- plataforma (admin-api, tela Plataforma > Catalogos) e as Edge Functions (role app_tenant, ex.: criar cor).
drop policy if exists "veiculo_catalogo_marcas_manage" on public.marcas_veiculo;
drop policy if exists "veiculo_catalogo_modelos_manage" on public.modelos_veiculo;
drop policy if exists "veiculo_catalogo_versoes_manage" on public.versoes_veiculo;
drop policy if exists "veiculo_catalogo_categorias_manage" on public.categorias_veiculo;
drop policy if exists "cores_veiculo_manage" on public.cores_veiculo;

-- O CRM nao faz parte deste produto: nenhuma tela ou funcao le essas tabelas (clientes_crm, veiculos_estoque,
-- propostas, vendas) e nada fora do schema referencia elas. Remove o schema inteiro.
-- Os cadastros de clientes e veiculos da Oficina (public.clientes / public.veiculos) permanecem.
drop schema if exists gestao_crm cascade;

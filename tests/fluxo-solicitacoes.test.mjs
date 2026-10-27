// Fluxo completo do Financeiro contra o stack local: cadastro -> solicitacao -> aprovacao -> pagamento,
// com as regras de permissao e as notificacoes. Mesmos pre-requisitos de `npm test` (ver _helpers.mjs).

import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';

import { PLATFORM_EMAIL, api, criarCliente, login, loginPlataforma, psql, sufixo } from './_helpers.mjs';

describe('fluxo de solicitacao de pagamento', () => {
  let platform;
  let A; // cliente do teste (admin = aprovador/financeiro)
  let B; // outro cliente, para conferir que nao enxerga nada
  let solicitante; // usuario comum do cliente A
  let payload;

  before(async () => {
    platform = api('admin-api', (await loginPlataforma()).aal2);
    A = await criarCliente(platform, 'fa');
    B = await criarCliente(platform, 'fb');

    const criado = await A.admin({ action: 'usuario_criar', nome: 'Solicitante', email: `solicitante-${sufixo}@teste.local`, nivel_acesso: 'usuario' });
    assert.equal(criado.status, 200, JSON.stringify(criado.data));
    const permissao = await A.servicos({ action: 'set_permissao', colaborador_id: criado.data.row.id, modulo: 'financeiro', papel: 'usuario' });
    assert.equal(permissao.status, 200, JSON.stringify(permissao.data));
    const token = await login(criado.data.row.email, criado.data.row.senha_temporaria);
    solicitante = { id: criado.data.row.id, servicos: api('servicos-api', token) };

    const categoria = await A.servicos({ action: 'criar_categoria', nome: `Categoria ${sufixo}` });
    assert.equal(categoria.status, 200, JSON.stringify(categoria.data));
    const fornecedor = await A.servicos({
      action: 'criar_fornecedor',
      nome: `Fornecedor ${sufixo}`,
      tipo_pessoa: 'juridica',
      documento: '11222333000181',
      telefone: '11999998888',
      endereco: 'Rua A, 1',
      cidade: 'Sao Paulo',
      uf: 'SP',
      cep: '01001000',
    });
    assert.equal(fornecedor.status, 200, JSON.stringify(fornecedor.data));

    payload = {
      titulo: 'Compra de pecas',
      tipo_beneficiario: 'fornecedor',
      fornecedor_id: fornecedor.data.row.id,
      categoria_id: categoria.data.row.id,
      descricao: 'Pecas para a oficina',
      valor: 250.5,
      forma_pagamento: 'pix',
      aprovador_destino_id: A.colaboradorId,
    };
  });

  after(async () => {
    for (const cliente of [A, B]) {
      if (cliente?.id) await platform({ action: 'tenant_atualizar', id: cliente.id, ativo: false });
    }
  });

  test('cria, aprova e paga respeitando quem pode cada passo', async () => {
    const criada = await solicitante.servicos({ action: 'create', payload });
    assert.equal(criada.status, 200, JSON.stringify(criada.data));
    const id = criada.data.row.id;
    assert.equal(criada.data.row.status, 'pendente');
    assert.equal(criada.data.row.solicitante_id, solicitante.id);

    // o aprovador foi avisado
    const avisosAprovador = (await A.servicos({ action: 'list_notificacoes' })).data.rows;
    assert.ok(avisosAprovador.some((n) => n.referencia_id === id), 'aprovador recebe notificacao da nova solicitacao');

    // solicitante comum nao aprova nem paga
    assert.equal((await solicitante.servicos({ action: 'set_status', id, status: 'aprovado', confirmar_sem_anexo: true })).status, 403);
    assert.equal((await solicitante.servicos({ action: 'set_status', id, status: 'pago' })).status, 403);

    // aprovador: sem anexo pede confirmacao; com confirmacao aprova
    assert.equal((await A.servicos({ action: 'set_status', id, status: 'aprovado' })).status, 409, 'sem anexo exige confirmacao');
    const aprovada = await A.servicos({ action: 'set_status', id, status: 'aprovado', confirmar_sem_anexo: true });
    assert.equal(aprovada.status, 200, JSON.stringify(aprovada.data));
    assert.equal(aprovada.data.row.status, 'aprovado');
    assert.equal((await A.servicos({ action: 'set_status', id, status: 'aprovado', confirmar_sem_anexo: true })).status, 400, 'nao aprova duas vezes');

    // pagamento: so o financeiro, uma vez
    assert.equal((await solicitante.servicos({ action: 'set_status', id, status: 'pago' })).status, 403);
    const paga = await A.servicos({ action: 'set_status', id, status: 'pago' });
    assert.equal(paga.status, 200, JSON.stringify(paga.data));
    assert.equal(paga.data.row.status, 'pago');
    assert.equal((await A.servicos({ action: 'set_status', id, status: 'pago' })).status, 400, 'nao paga duas vezes');

    // historico e notificacoes do solicitante
    const historico = (await A.servicos({ action: 'historico', solicitacao_id: id })).data.rows.map((h) => h.evento ?? h.acao ?? h.tipo);
    for (const evento of ['criada', 'aprovada', 'pago']) assert.ok(historico.includes(evento), `historico tem "${evento}": ${historico}`);
    const avisos = (await solicitante.servicos({ action: 'list_notificacoes' })).data.rows.filter((n) => n.referencia_id === id);
    assert.ok(avisos.length >= 2, `solicitante recebe avisos de aprovacao e pagamento (${avisos.length})`);

    // o solicitante ve a propria solicitacao paga; outro cliente nao enxerga nada
    const vista = await solicitante.servicos({ action: 'get', id });
    assert.equal(vista.status, 200);
    assert.equal(vista.data.row.status, 'pago');
    const deB = await B.servicos({ action: 'get', id });
    assert.ok(deB.status >= 400, `outro cliente nao le a solicitacao (veio ${deB.status})`);
  });

  test('reprovacao exige a decisao do aprovador e encerra a solicitacao', async () => {
    const criada = await solicitante.servicos({ action: 'create', payload: { ...payload, titulo: 'Compra recusada' } });
    assert.equal(criada.status, 200, JSON.stringify(criada.data));
    const id = criada.data.row.id;

    const reprovada = await A.servicos({ action: 'set_status', id, status: 'reprovado', observacao_analise: 'Fora do orcamento' });
    assert.equal(reprovada.status, 200, JSON.stringify(reprovada.data));
    assert.equal(reprovada.data.row.status, 'reprovado');
    assert.equal((await A.servicos({ action: 'set_status', id, status: 'pago' })).status, 400, 'reprovada nao pode ser paga');
  });

  test('validacoes na criacao: valor, forma de pagamento e aprovador', async () => {
    const tentar = (extra) => solicitante.servicos({ action: 'create', payload: { ...payload, ...extra } });
    assert.equal((await tentar({ valor: 0 })).status, 400, 'valor zero');
    assert.equal((await tentar({ forma_pagamento: 'cheque-de-ouro' })).status, 400, 'forma invalida');
    assert.equal((await tentar({ aprovador_destino_id: null })).status, 400, 'sem aprovador');
    assert.equal((await tentar({ aprovador_destino_id: solicitante.id })).status, 400, 'aprovador sem perfil de aprovacao');
  });
});

describe('fluxo do checklist da oficina', () => {
  let platform;
  let A;
  let B;
  const UUID = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;

  before(async () => {
    platform = api('admin-api', (await loginPlataforma()).aal2);
    A = await criarCliente(platform, 'oa');
    B = await criarCliente(platform, 'ob');
  });

  after(async () => {
    for (const cliente of [A, B]) {
      if (cliente?.id) await platform({ action: 'tenant_atualizar', id: cliente.id, ativo: false });
    }
  });

  test('cadastra veiculo, preenche o checklist, avalia e finaliza; outro cliente nao acessa', async () => {
    const oficina = api('servicos-oficina-api', A.token);
    const oficinaB = api('servicos-oficina-api', B.token);

    const unidadeId = psql(
      `insert into public.unidades (nome, cidade, empresa_id, tenant_id)
       select 'Matriz', 'Cidade', e.id, e.tenant_id from public.empresas e where e.tenant_id = '${A.id}' limit 1 returning id;`,
    ).match(UUID)?.[0];
    assert.ok(unidadeId, 'unidade de teste nao criada');
    const modeloId = psql('select id from public.modelos_veiculo order by nome limit 1;').match(UUID)?.[0];
    assert.ok(modeloId, 'catalogo de modelos vazio');

    const cliente = await oficina({ action: 'cliente_criar', nome: 'Cliente Checklist', telefone: '11988887777', cpf_cnpj: '52998224725' });
    assert.equal(cliente.status, 201, JSON.stringify(cliente.data));
    const veiculo = await oficina({
      action: 'veiculo_criar',
      modelo_id: modeloId,
      chassi: `9BC${sufixo}98765432`.slice(0, 17).toUpperCase(),
      placa: `C${sufixo}`.slice(0, 7).toUpperCase(),
      cliente_id: cliente.data.row.id,
    });
    assert.equal(veiculo.status, 201, JSON.stringify(veiculo.data));

    const iniciado = await oficina({ action: 'checklist_iniciar', veiculo_id: veiculo.data.row.id, cliente_id: cliente.data.row.id, unidade_id: unidadeId, km: 1200 });
    assert.equal(iniciado.status, 201, JSON.stringify(iniciado.data));
    const id = iniciado.data.row.id;
    assert.equal(iniciado.data.row.status, 'em_andamento');
    assert.equal(iniciado.data.row.numero, 1, 'primeiro checklist da unidade');

    const atualizado = await oficina({
      action: 'checklist_atualizar',
      id,
      nivel_combustivel: 50,
      observacoes: 'risco na porta',
      assinatura_entrada_nome: 'Maria Cliente',
    });
    assert.equal(atualizado.status, 200, JSON.stringify(atualizado.data));

    const itens = await oficina({
      action: 'checklist_itens_upsert',
      avaliacao_id: id,
      categoria: 'pneus',
      itens: [{ item: 'Pneu dianteiro', status: 'conforme' }, { item: 'Pneu traseiro', status: 'conforme' }],
    });
    assert.equal(itens.status, 200, JSON.stringify(itens.data));
    assert.equal(itens.data.rows.length, 2);

    const avaliado = await oficina({ action: 'checklist_concluir_avaliacao', id });
    assert.equal(avaliado.status, 200, JSON.stringify(avaliado.data));
    assert.equal(avaliado.data.row.status, 'avaliado');

    const finalizado = await oficina({ action: 'checklist_finalizar', id, entrega_conferida: true, assinatura_saida_nome: 'Maria Cliente' });
    assert.equal(finalizado.status, 200, JSON.stringify(finalizado.data));
    assert.equal(finalizado.data.row.status, 'finalizado');
    assert.ok(finalizado.data.row.data_saida, 'data de saida registrada');

    const completo = await oficina({ action: 'checklist_obter', id });
    assert.equal(completo.status, 200);
    assert.equal(completo.data.itens.length, 2);
    assert.equal(completo.data.row.status, 'finalizado');

    const deB = await oficinaB({ action: 'checklist_obter', id });
    assert.ok(deB.status >= 400, `outro cliente nao le o checklist (veio ${deB.status})`);
    assert.ok(
      !JSON.stringify((await oficinaB({ action: 'checklist_listar' })).data).includes(id),
      'checklist nao aparece na lista do outro cliente',
    );
  });
});

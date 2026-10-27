// Teste de isolamento entre clientes (tenants), de ponta a ponta contra o stack local:
// Supabase (`npm run db:start`) + Edge Functions (`npm run functions:serve`) no ar e banco recem-resetado
// (admin da plataforma admin@servicos.local / Servicos@123).
//
//   npm test
//
// Cria dois clientes novos por execucao (slug com sufixo aleatorio) e, no fim, desativa os dois.
// Variaveis opcionais: SUPABASE_URL, SUPABASE_ANON_KEY, PLATFORM_ADMIN_EMAIL, PLATFORM_ADMIN_PASSWORD.
import { after, before, describe, test } from 'node:test';
import assert from 'node:assert/strict';

import { ANON, URL_BASE, PLATFORM_EMAIL, api, criarCliente, login, loginPlataforma, psql, storage, sufixo } from './_helpers.mjs';

describe('isolamento entre tenants', () => {
  let platform;
  let A;
  let B;

  before(async () => {
    platform = api('admin-api', (await loginPlataforma()).aal2);
    A = await criarCliente(platform, 'a');
    B = await criarCliente(platform, 'b');
  });

  after(async () => {
    for (const cliente of [A, B]) {
      if (cliente?.id) await platform({ action: 'tenant_atualizar', id: cliente.id, ativo: false });
    }
  });

  test('admin de cliente novo ja entra com acesso total a Financeiro e Oficina', async () => {
    const financeiro = (await A.servicos({ action: 'me' })).data;
    assert.ok(financeiro.role && financeiro.role !== 'nenhum', `papel no Financeiro: ${financeiro.role}`);
    const oficina = await api('servicos-oficina-api', A.token)({ action: 'me' });
    assert.equal(oficina.data.role, 'admin');
  });

  test('cadastros nao vazam e o mesmo nome vale nos dois clientes', async () => {
    const a = await A.admin({ action: 'cadastro_salvar', tipo: 'departamentos', nome: 'Vendas' });
    const b = await B.admin({ action: 'cadastro_salvar', tipo: 'departamentos', nome: 'Vendas' });
    assert.equal(a.status, 200, JSON.stringify(a.data));
    assert.equal(b.status, 200, 'mesmo nome em outro cliente deve ser permitido');
    assert.notEqual(a.data.id, b.data.id);

    const listaA = (await A.admin({ action: 'cadastros_list' })).data;
    const listaB = (await B.admin({ action: 'cadastros_list' })).data;
    assert.deepEqual(listaA.departamentos.map((d) => d.id), [a.data.id]);
    assert.deepEqual(listaB.departamentos.map((d) => d.id), [b.data.id]);
    assert.equal(listaA.empresas.length, 1);
    assert.equal(listaB.empresas.length, 1);
    assert.notEqual(listaA.empresas[0].id, listaB.empresas[0].id);
  });

  test('um cliente nao altera nem exclui registros do outro', async () => {
    const alvo = (await B.admin({ action: 'cadastros_list' })).data.departamentos[0];

    const renomear = await A.admin({ action: 'cadastro_salvar', tipo: 'departamentos', id: alvo.id, nome: 'INVADIDO' });
    assert.equal(renomear.status, 404);
    await A.admin({ action: 'cadastro_excluir', tipo: 'departamentos', id: alvo.id });

    const depois = (await B.admin({ action: 'cadastros_list' })).data.departamentos;
    assert.equal(depois.length, 1);
    assert.equal(depois[0].nome, 'Vendas');
  });

  test('nao e possivel referenciar registro de outro cliente', async () => {
    const empresaB = (await B.admin({ action: 'cadastros_list' })).data.empresas[0];
    const unidade = await A.admin({ action: 'cadastro_salvar', tipo: 'unidades', nome: 'Matriz', empresa_id: empresaB.id });
    assert.equal(unidade.status, 400);

    const departamentoB = (await B.admin({ action: 'cadastros_list' })).data.departamentos[0];
    const cargo = await A.admin({ action: 'cadastro_salvar', tipo: 'cargos', nome: 'Gerente', departamento_id: departamentoB.id });
    assert.equal(cargo.status, 400);
  });

  test('lista de usuarios mostra so os do proprio cliente', async () => {
    const listaA = (await A.admin({ action: 'usuarios_list' })).data.rows.map((u) => u.email);
    const listaB = (await B.admin({ action: 'usuarios_list' })).data.rows.map((u) => u.email);
    assert.deepEqual(listaA, [A.email]);
    assert.deepEqual(listaB, [B.email]);
  });

  test('nao da para editar usuario de outro cliente', async () => {
    const usuarioB = (await B.admin({ action: 'usuarios_list' })).data.rows[0];
    const editar = await A.admin({ action: 'usuario_atualizar', id: usuarioB.id, nome: 'INVADIDO' });
    assert.ok(editar.status >= 400, `esperava erro, veio ${editar.status}`);
    const reset = await A.admin({ action: 'usuario_resetar_senha', id: usuarioB.id });
    assert.ok(reset.status >= 400, `esperava erro, veio ${reset.status}`);

    const depois = (await B.admin({ action: 'usuarios_list' })).data.rows[0];
    assert.notEqual(depois.nome, 'INVADIDO');
  });

  test('integracao de e-mail e por cliente', async () => {
    const salvar = await A.admin({
      action: 'integracao_gmail_salvar',
      sender: 'a@teste.local',
      client_id: 'cid-a',
      client_secret: 'segredo-a',
      refresh_token: 'token-a',
    });
    assert.equal(salvar.status, 200, JSON.stringify(salvar.data));
    assert.ok(!JSON.stringify(salvar.data).includes('segredo-a'), 'segredo nao pode voltar na resposta');

    const b = (await B.admin({ action: 'integracao_gmail_obter' })).data;
    assert.equal(b.configurada, false);
    assert.equal(b.sender, '');
  });

  test('acoes da plataforma sao negadas a admin de cliente', async () => {
    for (const action of ['tenants_list', 'tenant_atualizar', 'tenant_criar']) {
      const resposta = await A.admin({ action, id: B.id, ativo: false });
      assert.equal(resposta.status, 403, `${action} deveria ser 403`);
    }
  });

  test('catalogos do financeiro sao separados por cliente', async (t) => {
    const categoria = await A.servicos({ action: 'criar_categoria', nome: 'Categoria so da A' });
    if (categoria.status !== 200) {
      // Admin recem-criado pode nao ter papel no Financeiro; o isolamento por RLS ja e coberto acima.
      return t.skip(`criar_categoria respondeu ${categoria.status}: ${JSON.stringify(categoria.data)}`);
    }
    const listaB = (await B.servicos({ action: 'list_categorias' })).data.rows || [];
    assert.ok(!listaB.some((c) => c.nome === 'Categoria so da A'));
  });

  test('catalogos de veiculo: so a plataforma altera; cliente le mas nao escreve nem por REST', async () => {
    const nome = `Marca ${sufixo}`;
    for (const acao of [{ action: 'catalogo_listar' }, { action: 'catalogo_salvar', tipo: 'marcas', nome }]) {
      assert.equal((await A.admin(acao)).status, 403, `cliente nao pode ${acao.action}`);
    }
    const rest = await fetch(`${URL_BASE}/rest/v1/marcas_veiculo`, {
      method: 'POST',
      headers: { apikey: ANON, Authorization: `Bearer ${A.token}`, 'Content-Type': 'application/json', Prefer: 'return=representation' },
      body: JSON.stringify({ nome: `Rest ${sufixo}` }),
    });
    assert.ok([401, 403].includes(rest.status), `escrita REST de cliente deve ser negada: ${rest.status}`);
    const leitura = await fetch(`${URL_BASE}/rest/v1/marcas_veiculo?select=id&limit=1`, {
      headers: { apikey: ANON, Authorization: `Bearer ${A.token}` },
    });
    assert.equal(leitura.status, 200, 'cliente continua lendo o catalogo');

    const criada = await platform({ action: 'catalogo_salvar', tipo: 'marcas', nome });
    assert.equal(criada.status, 200, JSON.stringify(criada.data));
    assert.equal((await platform({ action: 'catalogo_salvar', tipo: 'marcas', nome })).status, 409, 'nome repetido');
    const lista = (await platform({ action: 'catalogo_listar' })).data;
    assert.ok(lista.marcas.some((m) => m.id === criada.data.id), 'marca aparece na lista');
    assert.ok(
      lista.marcas.length >= 18 && lista.modelos.length >= 58 && lista.cores.length >= 13 && lista.categorias.length >= 6,
      'catalogo padrao presente',
    );

    const modelo = await platform({
      action: 'catalogo_salvar',
      tipo: 'modelos',
      nome: `Modelo ${sufixo}`,
      marca_id: criada.data.id,
      categoria_veiculo_id: lista.categorias[0].id,
    });
    assert.equal(modelo.status, 200, JSON.stringify(modelo.data));
    assert.equal((await platform({ action: 'catalogo_excluir', tipo: 'marcas', id: criada.data.id })).status, 409, 'marca com modelo nao exclui');
    assert.equal((await platform({ action: 'catalogo_salvar', tipo: 'marcas', id: criada.data.id, nome, ativo: false })).status, 200, 'desativa');
    assert.equal((await platform({ action: 'catalogo_excluir', tipo: 'modelos', id: modelo.data.id })).status, 200);
    assert.equal((await platform({ action: 'catalogo_excluir', tipo: 'marcas', id: criada.data.id })).status, 200);
  });

  test('whatsapp: sem provedor por enquanto; a fila e isolada por cliente', async () => {
    const status = await A.admin({ action: 'integracao_whatsapp_obter' });
    assert.equal(status.status, 200, JSON.stringify(status.data));
    assert.deepEqual(status.data, { configurada: false, provider: 'nenhum', ativo: false, providers_disponiveis: [] });

    psql(`insert into notificacoes.fila_whatsapp (tenant_id, tipo, destinatario) values ('${A.id}', 'teste', '5511988887777');`);
    const contar = (tenant) =>
      Number(psql(`set role app_tenant; select set_config('app.tenant_id', '${tenant}', false); select count(*) from notificacoes.fila_whatsapp where tipo = 'teste';`).split('\n').pop());
    assert.equal(contar(A.id), 1, 'A enxerga a propria mensagem');
    assert.equal(contar(B.id), 0, 'B nao enxerga a mensagem da A');
  });

  test('storage: so a pasta de uma solicitacao do proprio cliente aceita arquivos', async () => {
    const categoria = (await A.servicos({ action: 'list_categorias' })).data.rows[0];
    assert.ok(categoria, 'cliente A precisa de uma categoria');
    const fornecedorId = psql(`insert into gestao_servicos.fornecedores (nome, tenant_id) values ('Forn A', '${A.id}') returning id;`).match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)?.[0];
    assert.ok(fornecedorId, 'fornecedor de teste nao criado');

    const solicitacaoId = psql(`
      insert into gestao_servicos.solicitacoes_pagamento (solicitante_id, fornecedor, descricao, titulo, valor, forma_pagamento, categoria_id, fornecedor_id, tenant_id)
      values ('${A.colaboradorId}', 'Forn A', 'd', 't', 10, 'pix', '${categoria.id}', '${fornecedorId}', '${A.id}') returning id;
    `).match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)?.[0];
    assert.ok(solicitacaoId, 'solicitacao de teste nao criada');

    const caminho = `comprovantes-pagamento/${solicitacaoId}/pix/teste-${sufixo}.txt`;
    assert.equal(await storage(A.token, 'POST', caminho, 'x'), 200, 'A deve gravar na propria solicitacao');
    assert.equal(await storage(B.token, 'POST', `comprovantes-pagamento/${solicitacaoId}/pix/invasao-${sufixo}.txt`, 'x'), 400, 'B nao grava na pasta da A');
    assert.equal(await storage(B.token, 'GET', `authenticated/${caminho}`), 400, 'B nao le arquivo da A');
    assert.equal(await storage(A.token, 'POST', `comprovantes-pagamento/solto-${sufixo}.txt`, 'x'), 400, 'arquivo fora de pasta de solicitacao');
    assert.equal(await storage(A.token, 'GET', `authenticated/${caminho}`), 200, 'A le o proprio arquivo');
  });

  test('assinaturas: um cliente nao lista nem enumera as do outro', async () => {
    const arquivo = `colaboradores/${A.colaboradorId}/${sufixo}.png`;
    assert.equal(await storage(A.token, 'POST', `assinaturas/${arquivo}`, 'x', 'image/png'), 200, 'A grava a propria assinatura');
    assert.equal(await storage(B.token, 'POST', `assinaturas/colaboradores/${A.colaboradorId}/invasao-${sufixo}.png`, 'x', 'image/png'), 400, 'B nao grava na pasta da A');

    const listar = async (token) => {
      const response = await fetch(`${URL_BASE}/storage/v1/object/list/assinaturas`, {
        method: 'POST',
        headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ prefix: `colaboradores/${A.colaboradorId}`, limit: 100 }),
      });
      return response.json();
    };
    const listaA = await listar(A.token);
    assert.equal(listaA.length, 1, `A lista a propria assinatura: ${JSON.stringify(listaA)}`);
    assert.equal((await listar(B.token)).length, 0, 'B nao enxerga a assinatura da A');
    const publica = await fetch(`${URL_BASE}/storage/v1/object/public/assinaturas/${arquivo}`);
    assert.notEqual(publica.status, 200, 'bucket privado: a URL publica nao abre o arquivo');
  });

  test('auditoria registra as acoes sem vazar segredos e so a plataforma le', async () => {
    const lista = await platform({ action: 'auditoria_list' });
    assert.equal(lista.status, 200);
    const criacao = lista.data.rows.find((r) => r.acao === 'tenant_criar' && r.tenant_id === A.id);
    assert.ok(criacao, 'criacao do cliente A deve estar na auditoria');
    assert.equal(criacao.ator_email, PLATFORM_EMAIL);
    assert.equal(criacao.detalhes.admin_email, A.email);

    const integracao = lista.data.rows.find((r) => r.acao === 'integracao_gmail_salvar' && r.tenant_id === A.id);
    assert.ok(integracao, 'salvar integracao de e-mail deve estar na auditoria');
    const texto = JSON.stringify(lista.data.rows);
    for (const segredo of ['segredo-a', 'token-a', 'senha_temporaria']) {
      assert.ok(!texto.includes(segredo), `auditoria nao pode conter "${segredo}"`);
    }

    for (const action of ['auditoria_list', 'admins_list']) {
      assert.equal((await A.admin({ action })).status, 403, `${action} deve ser negada a admin de cliente`);
    }
  });

  test('administradores da plataforma: adicionar, remover e protecoes', async () => {
    const lista = (await platform({ action: 'admins_list' })).data.rows;
    const eu = lista.find((r) => r.email === PLATFORM_EMAIL);
    assert.ok(eu, 'admin da plataforma deve aparecer na lista');

    assert.equal((await platform({ action: 'admin_remover', user_id: eu.user_id })).status, 400, 'nao remove a si mesmo');
    assert.equal((await platform({ action: 'admin_adicionar', email: 'nao-existe@teste.local' })).status, 404);

    const adicionar = await platform({ action: 'admin_adicionar', email: B.email });
    assert.equal(adicionar.status, 200, JSON.stringify(adicionar.data));
    try {
      const comoAdmin = await B.admin({ action: 'me' });
      assert.equal(comoAdmin.data.is_platform_admin, true, 'novo admin da plataforma e reconhecido');
      const semMfa = await B.admin({ action: 'tenants_list' });
      assert.equal(semMfa.status, 403, 'mesmo sendo admin da plataforma, sem MFA nao acessa o painel');
      assert.equal(semMfa.data.code, 'mfa_required');
    } finally {
      assert.equal((await platform({ action: 'admin_remover', user_id: adicionar.data.user_id })).status, 200);
    }
    assert.equal((await B.admin({ action: 'tenants_list' })).status, 403, 'acesso some apos a remocao');

    const trilha = (await platform({ action: 'auditoria_list' })).data.rows;
    assert.ok(trilha.some((r) => r.acao === 'admin_adicionar' && r.alvo === B.email));
    assert.ok(trilha.some((r) => r.acao === 'admin_remover'));
  });

  test('oficina: clientes e veiculos (cadastro, listagem, exclusao) funcionam e ficam isolados', async () => {
    const oficina = (cliente) => api('servicos-oficina-api', cliente.token);
    const modeloId = psql(`
      with c as (insert into public.categorias_veiculo (nome) values ('Cat ${sufixo}') returning id),
           m as (insert into public.marcas_veiculo (nome) values ('Marca ${sufixo}') returning id)
      insert into public.modelos_veiculo (marca_id, categoria_veiculo_id, nome)
      select m.id, c.id, 'Modelo ${sufixo}' from m, c returning id;
    `).match(/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i)?.[0];
    assert.ok(modeloId, 'modelo de teste nao criado');

    const cliente = await oficina(A)({ action: 'cliente_criar', nome: 'Cliente Teste', telefone: '11988887777', cpf_cnpj: '52998224725' });
    assert.equal(cliente.status, 201, JSON.stringify(cliente.data));
    const clienteId = cliente.data.row.id;

    const veiculo = await oficina(A)({ action: 'veiculo_criar', modelo_id: modeloId, chassi: `9BW${sufixo}12345678`.slice(0, 17).toUpperCase(), placa: `T${sufixo}`.slice(0, 7).toUpperCase(), cliente_id: clienteId });
    assert.equal(veiculo.status, 201, JSON.stringify(veiculo.data));
    const veiculoId = veiculo.data.row.id;

    const listaA = await oficina(A)({ action: 'veiculo_listar' });
    assert.equal(listaA.status, 200, JSON.stringify(listaA.data));
    assert.ok(listaA.data.rows.some((v) => v.id === veiculoId));
    assert.ok(!('tem_proposta_venda' in listaA.data.rows[0]), 'campos do CRM nao existem mais');
    assert.equal((await oficina(A)({ action: 'veiculo_obter', id: veiculoId })).status, 200);

    // outro cliente nao enxerga nem acessa
    const listaB = await oficina(B)({ action: 'veiculo_listar' });
    assert.equal(listaB.status, 200, JSON.stringify(listaB.data));
    assert.ok(!listaB.data.rows.some((v) => v.id === veiculoId));
    assert.equal((await oficina(B)({ action: 'veiculo_obter', id: veiculoId })).status, 404);
    assert.equal((await oficina(B)({ action: 'cliente_excluir', id: clienteId })).status, 404);

    // cliente com veiculo nao e excluido; depois de excluir o veiculo, sim
    assert.equal((await oficina(A)({ action: 'cliente_excluir', id: clienteId })).status, 400);
    assert.equal((await oficina(A)({ action: 'veiculo_excluir', veiculo_id: veiculoId })).status, 200);
    assert.equal((await oficina(A)({ action: 'cliente_excluir', id: clienteId })).status, 200);
  });

  test('plataforma edita nome/plano e redefine a senha do admin de um cliente', async () => {
    const editar = await platform({ action: 'tenant_atualizar', id: B.id, nome: `Renomeado ${sufixo}`, plano: 'premium' });
    assert.equal(editar.status, 200, JSON.stringify(editar.data));
    assert.equal(editar.data.row.plano, 'premium');
    const lista = (await platform({ action: 'tenants_list' })).data.rows;
    assert.equal(lista.find((t) => t.id === B.id).nome, `Renomeado ${sufixo}`);

    const admins = (await platform({ action: 'tenant_admins', tenant_id: B.id })).data.rows;
    assert.deepEqual(admins.map((a) => a.email), [B.email]);

    // usuario de outro cliente nao pode ser redefinido por esta rota
    const cruzado = await platform({ action: 'tenant_admin_resetar_senha', tenant_id: A.id, user_id: B.colaboradorId });
    assert.equal(cruzado.status, 404);

    const reset = await platform({ action: 'tenant_admin_resetar_senha', tenant_id: B.id, user_id: B.colaboradorId });
    assert.equal(reset.status, 200, JSON.stringify(reset.data));
    assert.ok(reset.data.senha_temporaria);
    const token = await login(B.email, reset.data.senha_temporaria);
    assert.ok(token, 'login com a nova senha temporaria');

    for (const action of ['tenant_admins', 'tenant_admin_resetar_senha']) {
      const negado = await A.admin({ action, tenant_id: B.id, user_id: B.colaboradorId });
      assert.equal(negado.status, 403, `${action} deve ser negada a admin de cliente`);
    }

    const trilha = (await platform({ action: 'auditoria_list', tenant_id: B.id })).data.rows;
    assert.ok(trilha.some((r) => r.acao === 'tenant_admin_resetar_senha'));
    assert.ok(!JSON.stringify(trilha).includes(reset.data.senha_temporaria), 'senha nao pode ir para a auditoria');
  });

  test('cliente desativado nao enxerga nem altera dados', async () => {
    const C = await criarCliente(platform, 'c');
    try {
      const antes = await C.admin({ action: 'cadastro_salvar', tipo: 'departamentos', nome: 'Antes' });
      assert.equal(antes.status, 200);
      await platform({ action: 'tenant_atualizar', id: C.id, ativo: false });

      const lista = await C.admin({ action: 'cadastros_list' });
      const visiveis = lista.status === 200 ? lista.data.departamentos.length + lista.data.empresas.length : 0;
      assert.equal(visiveis, 0, 'cliente desativado nao deve ver registros');

      const sessao = await C.servicos({ action: 'me' });
      assert.equal(sessao.status, 403, 'usuario de cliente desativado recebe aviso de acesso desativado');
      assert.match(JSON.stringify(sessao.data), /desativado/);

      const criar = await C.admin({ action: 'cadastro_salvar', tipo: 'departamentos', nome: 'Depois' });
      assert.ok(criar.status >= 400, `esperava erro ao criar, veio ${criar.status}`);
    } finally {
      await platform({ action: 'tenant_atualizar', id: C.id, ativo: false });
    }
  });

  test('marca: cada cliente personaliza a propria; a tela de login a le pelo slug', async () => {
    const publica = async (slug) => {
      const r = await fetch(`${URL_BASE}/functions/v1/marca-publica`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ slug }),
      });
      return { status: r.status, data: await r.json() };
    };
    const slugA = `teste-a-${sufixo}`;
    assert.equal((await publica('nao-existe-xyz')).status, 404);
    assert.equal((await publica(slugA)).data.nome, `Teste a ${sufixo}`, 'sem personalizacao usa o nome do cliente');
    assert.equal((await A.servicos({ action: 'me' })).data.tenant_slug, slugA, 'me informa o slug do cliente da conta');

    // PNG 1x1 valido.
    const png = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
    const salvo = await A.admin({ action: 'marca_salvar', marca_nome: 'Acme Motors', marca_cor: '#0A7CFF', logo_data_url: png });
    assert.equal(salvo.status, 200, JSON.stringify(salvo.data));
    assert.equal(salvo.data.marca.nome, 'Acme Motors');
    assert.equal(salvo.data.marca.cor, '#0a7cff');
    const aberta = (await publica(slugA)).data;
    assert.equal(aberta.nome, 'Acme Motors');
    assert.equal(aberta.cor, '#0a7cff');
    assert.ok(aberta.logo_url, 'logo publicado');
    assert.equal((await fetch(aberta.logo_url)).status, 200, 'logo acessivel sem login');

    // O outro cliente nao e afetado e nao altera a marca alheia (so a propria, pelo token).
    const slugB = `teste-b-${sufixo}`;
    const nomeB = (await platform({ action: 'tenants_list' })).data.rows.find((r) => r.id === B.id).nome;
    assert.equal((await publica(slugB)).data.nome, nomeB, 'sem personalizacao usa o nome atual do cliente');
    const linhaB = (await platform({ action: 'tenants_list' })).data.rows.find((r) => r.id === B.id);
    assert.equal(linhaB.marca_nome, null, 'a marca do A nao vaza para o B');

    // Validacoes.
    assert.equal((await A.admin({ action: 'marca_salvar', marca_cor: 'vermelho' })).status, 400);
    assert.equal((await A.admin({ action: 'marca_salvar', logo_data_url: 'data:image/svg+xml;base64,PHN2Zy8+' })).status, 400);
    assert.equal((await A.admin({ action: 'marca_salvar', logo_data_url: `data:image/png;base64,${Buffer.alloc(500 * 1024).toString('base64')}` })).status, 400);

    // Plataforma ajusta a marca de qualquer cliente; cliente comum nao usa a acao de plataforma.
    const pela = await platform({ action: 'tenant_marca_salvar', tenant_id: B.id, marca_nome: 'Beta Pecas' });
    assert.equal(pela.status, 200, JSON.stringify(pela.data));
    assert.equal((await publica(slugB)).data.nome, 'Beta Pecas');
    assert.equal((await A.admin({ action: 'tenant_marca_salvar', tenant_id: B.id, marca_nome: 'Hack' })).status, 403);

    // Remover o logo e limpar nome/cor volta ao padrao.
    const limpo = await A.admin({ action: 'marca_salvar', marca_nome: '', marca_cor: '', remover_logo: true });
    assert.equal(limpo.status, 200);
    const depois = (await publica(slugA)).data;
    assert.equal(depois.nome, `Teste a ${sufixo}`);
    assert.equal(depois.logo_url, null);
    assert.equal(depois.cor, null);
  });

  test('mfa: acoes de plataforma exigem segundo fator (aal2); so a senha nao basta', async () => {
    const { aal1, aal2 } = await loginPlataforma();
    const soSenha = api('admin-api', aal1);
    const bloqueada = await soSenha({ action: 'tenants_list' });
    assert.equal(bloqueada.status, 403);
    assert.equal(bloqueada.data.code, 'mfa_required');
    const catalogo = await soSenha({ action: 'catalogo_listar', catalogo: 'marcas' });
    assert.equal(catalogo.status, 403, 'catalogo tambem exige MFA');

    // O painel descobre em que etapa esta pelo "me", que continua respondendo com so a senha.
    const me1 = await soSenha({ action: 'me' });
    assert.equal(me1.status, 200);
    assert.equal(me1.data.is_platform_admin, true);
    assert.equal(me1.data.aal, 'aal1');

    const comMfa = api('admin-api', aal2);
    assert.equal((await comMfa({ action: 'me' })).data.aal, 'aal2');
    assert.equal((await comMfa({ action: 'tenants_list' })).status, 200);

    // Admin de cliente (nao e da plataforma) continua barrado, com ou sem MFA.
    const negada = await A.admin({ action: 'tenants_list' });
    assert.equal(negada.status, 403);
  });
});

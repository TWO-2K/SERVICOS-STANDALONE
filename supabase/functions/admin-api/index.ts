// Administracao de usuarios e de tenants.
//
// Dois niveis:
//   - Admin do tenant (public.acessos_usuario_sistema.nivel_acesso = 'admin'): gerencia os usuarios do proprio
//     tenant. Roda dentro da transacao do tenant (ver _shared/tenant-db.ts), entao nao enxerga nem altera outro.
//   - Admin da plataforma (plataforma.administradores): lista, cria e desativa tenants. Roda como dono do banco
//     e sempre informa o tenant_id de forma explicita.
// Criar/alterar login usa a service role (auth.admin); nenhuma senha e guardada, so devolvida uma vez.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';
import postgres from 'https://deno.land/x/postgresjs@v3.4.5/mod.js';
import { buildCorsHeaders } from '../_shared/cors.ts';
import {
  getAccessLevel,
  getAuthenticatedUser,
  getBearerToken,
  getCurrentCollaborator,
  getServicosAccess,
} from '../_shared/servicos-auth.ts';
import { createScopedSql, runInTenant, tenantIdOf } from '../_shared/tenant-db.ts';
import { listWhatsappProviders, WHATSAPP_INTEGRACAO_CHAVE } from '../_shared/whatsapp.ts';

const SERVICOS_SYSTEM_SLUG = 'servicos';
const NIVEIS_ACESSO = ['usuario', 'gestor', 'admin'] as const;
// Cliente de teste fixo: nao pode ser desativado nem excluido (tambem protegido por trigger no banco).
const TENANT_PADRAO_ID = '55555555-5555-5555-5555-555555555555';
const STATUS_USUARIO =['ativo', 'inativo', 'afastado'] as const;
const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const SLUG_RE = /^[a-z0-9](?:[a-z0-9-]{1,38})[a-z0-9]$/;
const CATEGORIAS_PADRAO = [
  'Fornecedores', 'Serviços', 'Peças e materiais', 'Impostos e taxas', 'Folha e benefícios',
  'Aluguel e condomínio', 'Energia, água e internet', 'Manutenção', 'Marketing', 'Outros',
];
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const databaseUrl = Deno.env.get('DATABASE_URL');
const supabaseUrl = Deno.env.get('SUPABASE_URL');
const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY');
const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

const sqlPool = databaseUrl
  ? postgres(databaseUrl, { prepare: false, max: 3, idle_timeout: 5, connect_timeout: 15 })
  : null;
const sql = sqlPool ? createScopedSql(sqlPool) : null;

type Json = Record<string, unknown>;
type Collaborator = Record<string, unknown>;

function httpError(message: string, status = 400) {
  return Object.assign(new Error(message), { status });
}

function jsonResponse(data: unknown, status = 200, headers: Record<string, string> = {}) {
  return new Response(JSON.stringify(data), { status, headers: { ...headers, 'Content-Type': 'application/json' } });
}

function getErrorStatus(error: unknown) {
  const status = Number((error as { status?: number })?.status);
  return Number.isFinite(status) && status >= 400 ? status : 500;
}

function getErrorCode(error: unknown) {
  const code = (error as { code?: unknown })?.code;
  return typeof code === 'string' ? code : undefined;
}

function getErrorMessage(error: unknown) {
  return error instanceof Error ? error.message : 'Falha na administracao.';
}

// Nivel de garantia da sessao (claim "aal" do JWT: aal1 = so senha, aal2 = senha + segundo fator). O token ja foi
// validado por getAuthenticatedUser (auth.getUser), entao ler o payload aqui nao confia em nada nao verificado.
function sessionAal(token: string) {
  try {
    const payload = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    return String(JSON.parse(atob(payload)).aal || 'aal1');
  } catch {
    return 'aal1';
  }
}

// O painel da plataforma enxerga todos os clientes, entao exige segundo fator (TOTP). Desligue so em ambiente
// de desenvolvimento descartavel, com PLATAFORMA_EXIGE_MFA=false.
const platformRequiresMfa = Deno.env.get('PLATAFORMA_EXIGE_MFA') !== 'false';

function authAdminClient() {
  if (!supabaseUrl || !serviceRoleKey) throw httpError('Supabase nao configurado.', 500);
  return createClient(supabaseUrl, serviceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } });
}

function gerarSenhaTemporaria() {
  const alfabeto = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
  const bytes = crypto.getRandomValues(new Uint8Array(12));
  return Array.from(bytes, (b) => alfabeto[b % alfabeto.length]).join('') + '#7';
}

function texto(value: unknown, max = 150) {
  const v = typeof value === 'string' ? value.trim() : '';
  return v ? v.slice(0, max) : '';
}

function uuidOuNull(value: unknown, campo: string) {
  if (value === undefined || value === null || value === '') return null;
  if (typeof value !== 'string' || !UUID_RE.test(value)) throw httpError(`${campo} invalido.`);
  return value;
}

function pertenceA<T extends readonly string[]>(lista: T, value: unknown, campo: string): T[number] {
  if (typeof value !== 'string' || !(lista as readonly string[]).includes(value)) throw httpError(`${campo} invalido.`);
  return value;
}

// Referencias (FK) validam fora do RLS: confirma pelo SELECT (filtrado pelo tenant) que o registro e do tenant.
async function garantirDoTenant(tabela: 'departamentos' | 'unidades' | 'empresas', id: string | null) {
  if (!id) return;
  const rows = await sql!.unsafe(`select id from public.${tabela} where id = $1 limit 1;`, [id]);
  if (!rows[0]) throw httpError(`Registro de ${tabela} nao encontrado.`);
}

async function getSistemaServicosId() {
  const rows = await sql!.unsafe(`select id from public.sistemas where slug = $1 limit 1;`, [SERVICOS_SYSTEM_SLUG]);
  if (!rows[0]) throw httpError('Sistema Servicos nao cadastrado.', 500);
  return String(rows[0].id);
}

// Contas de administrador da plataforma sao do dono do sistema, nao do cliente: nao aparecem na lista de usuarios do
// cliente e o admin dele nao pode inativar, editar nem redefinir a senha delas.
async function idsAdminsPlataforma(): Promise<string[]> {
  const rows = await sqlPool!.unsafe(`select user_id from plataforma.administradores;`);
  return rows.map((r: { user_id: string }) => String(r.user_id));
}

async function garantirNaoAdminPlataforma(id: string) {
  if ((await idsAdminsPlataforma()).includes(id)) throw httpError('Usuario nao encontrado.', 404);
}

// Cria login + colaborador + acesso ao Servicos no tenant corrente (transacao do tenant). Se algo falhar depois
// de criado o login, ele e removido.
async function criarUsuarioNoTenant(tenantId: string, input: {
  nome: string;
  email: string;
  nivelAcesso: (typeof NIVEIS_ACESSO)[number];
  departamentoId: string | null;
  unidadeId: string | null;
  empresaId: string | null;
}) {
  await garantirDoTenant('departamentos', input.departamentoId);
  await garantirDoTenant('unidades', input.unidadeId);
  await garantirDoTenant('empresas', input.empresaId);
  const sistemaId = await getSistemaServicosId();

  const senha = gerarSenhaTemporaria();
  const admin = authAdminClient();
  const { data, error } = await admin.auth.admin.createUser({
    email: input.email,
    password: senha,
    email_confirm: true,
    user_metadata: { full_name: input.nome, tenant_id: tenantId },
  });
  if (error || !data.user) {
    const jaExiste = /already|registered|exists/i.test(error?.message || '');
    throw httpError(jaExiste ? 'E-mail ja cadastrado.' : 'Nao foi possivel criar o login.', jaExiste ? 409 : 500);
  }

  const userId = data.user.id;
  try {
    await sql!.unsafe(
      `
        insert into public.colaboradores
          (id, nome, email, funcao, status, precisa_trocar_senha, departamento_id, unidade_id, empresa_id, tenant_id)
        values ($1, $2, $3, $4, 'ativo', true, $5, $6, $7, $8);
      `,
      [userId, input.nome, input.email, input.nivelAcesso, input.departamentoId, input.unidadeId, input.empresaId, tenantId],
    );
    await sql!.unsafe(
      `insert into public.acessos_usuario_sistema (colaborador_id, sistema_id, nivel_acesso, tenant_id)
       values ($1, $2, $3, $4);`,
      [userId, sistemaId, input.nivelAcesso, tenantId],
    );
  } catch (dbError) {
    await admin.auth.admin.deleteUser(userId).catch(() => {});
    throw dbError;
  }

  return { id: userId, email: input.email, senha_temporaria: senha };
}

// Se o cliente tem o Gmail ativo, enfileira o acesso por e-mail (a senha continua temporaria: precisa ser trocada
// no primeiro login). Sem integracao o chamador devolve a senha para ser mostrada uma vez na tela.
async function entregarAcessoPorEmail(
  tenantId: string,
  input: { nome: string; email: string; senha: string; motivo: 'convite' | 'redefinicao' },
): Promise<boolean> {
  const ativa = await sqlPool!.unsafe(
    `select 1 from integracoes.integracoes where tenant_id = $1 and chave = 'gmail_notificacoes' and ativo limit 1;`,
    [tenantId],
  );
  if (!ativa[0]) return false;

  // O app dos clientes abre pelo slug da empresa (APP_URL/slug).
  const slugRows = await sqlPool!.unsafe(`select slug from public.tenants where id = $1;`, [tenantId]);
  const baseUrl = (Deno.env.get('APP_URL') || '').replace(/\/$/, '');
  const appUrl = baseUrl && slugRows[0] ? `${baseUrl}/${slugRows[0].slug}` : baseUrl;
  const assunto = input.motivo === 'convite' ? 'Seu acesso foi criado' : 'Sua senha foi redefinida';
  const abertura = input.motivo === 'convite'
    ? 'Foi criado um acesso para voce.'
    : 'Sua senha foi redefinida por um administrador.';
  const linhas = [
    `Ola, ${input.nome}.`,
    abertura,
    ...(appUrl ? [`Endereco: ${appUrl}`] : []),
    `E-mail: ${input.email}`,
    `Senha temporaria: ${input.senha}`,
    'Voce vai precisar trocar a senha no primeiro acesso.',
  ];
  await sqlPool!.unsafe(
    `insert into notificacoes.fila_emails (tenant_id, tipo, destinatario, assunto, payload)
     values ($1, 'acesso_usuario', $2, $3, $4::text::jsonb);`,
    [tenantId, input.email, assunto, JSON.stringify({ to: input.email, subject: assunto, body_text: linhas.join('\n\n') })],
  );
  return true;
}

// ---------- Marca (nome, cor e logo do cliente) ----------

const LOGO_MAX_BYTES = 400 * 1024;
const LOGO_TIPOS: Record<string, string> = { 'image/png': 'png', 'image/jpeg': 'jpg', 'image/webp': 'webp' };
const COR_RE = /^#[0-9a-fA-F]{6}$/;

function logoPublicUrl(path: string | null) {
  if (!path) return null;
  const base = (Deno.env.get('PUBLIC_SUPABASE_URL') || supabaseUrl || '').replace(/\/$/, '');
  return `${base}/storage/v1/object/public/marcas/${path}`;
}

async function obterMarca(tenantId: string) {
  const rows = await sqlPool!.unsafe(
    `select slug, nome, marca_nome, marca_cor, marca_logo_path from public.tenants where id = $1;`,
    [tenantId],
  );
  const r = rows[0];
  if (!r) throw httpError('Cliente nao encontrado.', 404);
  return {
    slug: r.slug,
    nome_cliente: r.nome,
    nome: r.marca_nome ?? null,
    cor: r.marca_cor ?? null,
    logo_url: logoPublicUrl(r.marca_logo_path as string | null),
  };
}

// Campos ausentes ficam como estao; "" limpa nome/cor; "remover_logo" tira o logo; "logo_data_url" troca o logo.
async function salvarMarca(tenantId: string, body: Json) {
  const atual = await sqlPool!.unsafe(`select marca_nome, marca_cor, marca_logo_path from public.tenants where id = $1;`, [tenantId]);
  if (!atual[0]) throw httpError('Cliente nao encontrado.', 404);

  let nome = atual[0].marca_nome as string | null;
  let cor = atual[0].marca_cor as string | null;
  let logoPath = atual[0].marca_logo_path as string | null;

  if (body.marca_nome !== undefined) {
    const v = texto(body.marca_nome, 60);
    nome = v || null;
  }
  if (body.marca_cor !== undefined) {
    const v = texto(body.marca_cor, 7);
    if (v && !COR_RE.test(v)) throw httpError('Cor invalida: use o formato #RRGGBB.');
    cor = v ? v.toLowerCase() : null;
  }

  const antigo = logoPath;
  let novoArquivo: { path: string; bytes: Uint8Array; type: string } | null = null;
  if (typeof body.logo_data_url === 'string' && body.logo_data_url) {
    const m = /^data:(image\/(?:png|jpeg|webp));base64,([A-Za-z0-9+\/=]+)$/.exec(body.logo_data_url);
    if (!m) throw httpError('Logo invalido: envie PNG, JPG ou WebP.');
    const bytes = Uint8Array.from(atob(m[2]), (c) => c.charCodeAt(0));
    if (bytes.length > LOGO_MAX_BYTES) throw httpError('Logo grande demais (maximo 400 KB).');
    novoArquivo = { path: `${tenantId}/logo-${Date.now()}.${LOGO_TIPOS[m[1]]}`, bytes, type: m[1] };
    logoPath = novoArquivo.path;
  } else if (body.remover_logo === true) {
    logoPath = null;
  }

  const storage = authAdminClient().storage.from('marcas');
  if (novoArquivo) {
    const { error } = await storage.upload(novoArquivo.path, novoArquivo.bytes, { contentType: novoArquivo.type, upsert: true });
    if (error) throw httpError('Nao foi possivel salvar o logo.', 500);
  }
  await sqlPool!.unsafe(
    `update public.tenants set marca_nome = $2, marca_cor = $3, marca_logo_path = $4 where id = $1;`,
    [tenantId, nome, cor, logoPath],
  );
  if (antigo && antigo !== logoPath) await storage.remove([antigo]).catch(() => undefined);
  return obterMarca(tenantId);
}

function mapDbError(error: unknown) {
  const code = (error as { code?: string })?.code;
  if (code === '23505') return httpError('Ja existe um registro com esses dados (nome, e-mail, CPF ou telefone).', 409);
  return error;
}


// ---------- Cadastros auxiliares (empresas, unidades, departamentos, cargos) ----------

type Tipo = 'empresas' | 'unidades' | 'departamentos' | 'cargos';
const TIPOS: readonly Tipo[] = ['empresas', 'unidades', 'departamentos', 'cargos'];

function slugify(value: string) {
  return value
    .normalize('NFD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 40);
}

async function listarCadastros() {
  const empresas = await sql!.unsafe(`select id, nome, slug from public.empresas order by nome;`);
  const unidades = await sql!.unsafe(
    `select id, nome, cidade, endereco, telefone, responsavel, cnpj, ativo, empresa_id from public.unidades order by nome;`,
  );
  const departamentos = await sql!.unsafe(`select id, nome, descricao from public.departamentos order by nome;`);
  const cargos = await sql!.unsafe(`select id, nome, departamento_id from public.cargos order by nome;`);
  return { empresas, unidades, departamentos, cargos };
}

async function salvarCadastro(body: Json, tenantId: string) {
  const tipo = pertenceA(TIPOS, body.tipo, 'Tipo');
  const id = uuidOuNull(body.id, 'Registro');
  const nome = texto(body.nome, 120);
  if (!nome) throw httpError('Informe o nome.');

  try {
    if (tipo === 'departamentos') {
      const descricao = texto(body.descricao, 300) || null;
      const rows = id
        ? await sql!.unsafe(
            `update public.departamentos set nome = $2, descricao = $3, atualizado_em = now() where id = $1 returning id;`,
            [id, nome, descricao],
          )
        : await sql!.unsafe(
            `insert into public.departamentos (nome, descricao, tenant_id) values ($1, $2, $3) returning id;`,
            [nome, descricao, tenantId],
          );
      if (!rows[0]) throw httpError('Registro nao encontrado.', 404);
      return { id: rows[0].id };
    }

    if (tipo === 'empresas') {
      const slugBase = slugify(texto(body.slug, 40) || nome) || 'empresa';
      if (id) {
        const rows = await sql!.unsafe(
          `update public.empresas set nome = $2, atualizado_em = now() where id = $1 returning id;`,
          [id, nome],
        );
        if (!rows[0]) throw httpError('Registro nao encontrado.', 404);
        return { id: rows[0].id };
      }
      // slug e unico por tenant: acrescenta sufixo ate achar um livre.
      for (let tentativa = 0; tentativa < 20; tentativa += 1) {
        const slug = tentativa === 0 ? slugBase : `${slugBase.slice(0, 36)}-${tentativa + 1}`;
        const existente = await sql!.unsafe(`select 1 from public.empresas where slug = $1 limit 1;`, [slug]);
        if (existente[0]) continue;
        const rows = await sql!.unsafe(
          `insert into public.empresas (nome, slug, tenant_id) values ($1, $2, $3) returning id;`,
          [nome, slug, tenantId],
        );
        return { id: rows[0].id };
      }
      throw httpError('Nao foi possivel gerar um identificador para a empresa.');
    }

    if (tipo === 'unidades') {
      const empresaId = uuidOuNull(body.empresa_id, 'Empresa');
      await garantirDoTenant('empresas', empresaId);
      const valores = [
        nome,
        texto(body.cidade, 80) || null,
        texto(body.endereco, 150) || null,
        texto(body.telefone, 30) || null,
        texto(body.responsavel, 120) || null,
        texto(body.cnpj, 20) || null,
        empresaId,
        body.ativo === false ? false : true,
      ];
      const rows = id
        ? await sql!.unsafe(
            `update public.unidades set nome = $2, cidade = $3, endereco = $4, telefone = $5, responsavel = $6,
               cnpj = $7, empresa_id = $8, ativo = $9, atualizado_em = now() where id = $1 returning id;`,
            [id, ...valores],
          )
        : await sql!.unsafe(
            `insert into public.unidades (nome, cidade, endereco, telefone, responsavel, cnpj, empresa_id, ativo, tenant_id)
             values ($1, $2, $3, $4, $5, $6, $7, $8, $9) returning id;`,
            [...valores, tenantId],
          );
      if (!rows[0]) throw httpError('Registro nao encontrado.', 404);
      return { id: rows[0].id };
    }

    const departamentoId = uuidOuNull(body.departamento_id, 'Departamento');
    await garantirDoTenant('departamentos', departamentoId);
    const rows = id
      ? await sql!.unsafe(
          `update public.cargos set nome = $2, departamento_id = $3, atualizado_em = now() where id = $1 returning id;`,
          [id, nome, departamentoId],
        )
      : await sql!.unsafe(
          `insert into public.cargos (nome, departamento_id, tenant_id) values ($1, $2, $3) returning id;`,
          [nome, departamentoId, tenantId],
        );
    if (!rows[0]) throw httpError('Registro nao encontrado.', 404);
    return { id: rows[0].id };
  } catch (error) {
    throw mapDbError(error);
  }
}

async function excluirCadastro(body: Json) {
  const tipo = pertenceA(TIPOS, body.tipo, 'Tipo');
  const id = uuidOuNull(body.id, 'Registro');
  if (!id) throw httpError('Registro obrigatorio.');
  try {
    // tipo vem da lista fechada acima, entao a interpolacao do nome da tabela e segura.
    await sql!.unsafe(`delete from public.${tipo} where id = $1;`, [id]);
  } catch (error) {
    if ((error as { code?: string })?.code === '23503') throw httpError('Registro em uso: nao pode ser excluido.', 409);
    throw error;
  }
  return { success: true };
}

// ---------- Admin do tenant ----------

async function handleTenantAction(action: string, body: Json, collaborator: Collaborator, tenantId: string) {
  if (action === 'cadastros_list') return await listarCadastros();
  if (action === 'cadastro_salvar') return await salvarCadastro(body, tenantId);
  if (action === 'cadastro_excluir') return await excluirCadastro(body);

  if (action === 'usuarios_list') {
    const rows = await sql!.unsafe(
      `
        select c.id, c.nome, c.email, c.funcao, c.status, c.precisa_trocar_senha, c.departamento_id,
               c.unidade_id, c.empresa_id, c.criado_em, aus.nivel_acesso, aus.ativo as acesso_ativo
        from public.colaboradores c
        left join public.acessos_usuario_sistema aus
          on aus.colaborador_id = c.id
         and aus.sistema_id = (select id from public.sistemas where slug = $1)
        where c.id <> all($2::uuid[])
        order by c.nome;
      `,
      [SERVICOS_SYSTEM_SLUG, await idsAdminsPlataforma()],
    );
    const departamentos = await sql!.unsafe(`select id, nome from public.departamentos order by nome;`);
    const unidades = await sql!.unsafe(`select id, nome, empresa_id from public.unidades order by nome;`);
    const empresas = await sql!.unsafe(`select id, nome from public.empresas order by nome;`);
    return { rows, departamentos, unidades, empresas };
  }

  if (action === 'usuario_criar') {
    const nome = texto(body.nome, 120);
    const email = texto(body.email, 160).toLowerCase();
    if (!nome) throw httpError('Informe o nome.');
    if (!EMAIL_RE.test(email)) throw httpError('Informe um e-mail valido.');
    try {
      const row = await criarUsuarioNoTenant(tenantId, {
        nome,
        email,
        nivelAcesso: pertenceA(NIVEIS_ACESSO, body.nivel_acesso ?? 'usuario', 'Nivel de acesso'),
        departamentoId: uuidOuNull(body.departamento_id, 'Departamento'),
        unidadeId: uuidOuNull(body.unidade_id, 'Unidade'),
        empresaId: uuidOuNull(body.empresa_id, 'Empresa'),
      });
      const emailEnviado = await entregarAcessoPorEmail(tenantId, {
        nome, email, senha: String(row.senha_temporaria), motivo: 'convite',
      });
      return { row: { ...row, senha_temporaria: emailEnviado ? null : row.senha_temporaria, email_enviado: emailEnviado } };
    } catch (error) {
      throw mapDbError(error);
    }
  }

  if (action === 'usuario_atualizar') {
    const id = uuidOuNull(body.id, 'Usuario');
    if (!id) throw httpError('Usuario obrigatorio.');
    await garantirNaoAdminPlataforma(id);
    const atual = await sql!.unsafe(`select id, status from public.colaboradores where id = $1 limit 1;`, [id]);
    if (!atual[0]) throw httpError('Usuario nao encontrado.', 404);

    const nome = body.nome === undefined ? null : texto(body.nome, 120);
    if (nome === '') throw httpError('Informe o nome.');
    const status = body.status === undefined ? null : pertenceA(STATUS_USUARIO, body.status, 'Status');
    const nivel = body.nivel_acesso === undefined ? null : pertenceA(NIVEIS_ACESSO, body.nivel_acesso, 'Nivel de acesso');
    const departamentoId = body.departamento_id === undefined ? undefined : uuidOuNull(body.departamento_id, 'Departamento');
    const unidadeId = body.unidade_id === undefined ? undefined : uuidOuNull(body.unidade_id, 'Unidade');
    const empresaId = body.empresa_id === undefined ? undefined : uuidOuNull(body.empresa_id, 'Empresa');

    if (id === String(collaborator.id) && ((status && status !== 'ativo') || (nivel && nivel !== 'admin'))) {
      throw httpError('Voce nao pode inativar nem rebaixar a si mesmo.');
    }
    if (departamentoId) await garantirDoTenant('departamentos', departamentoId);
    if (unidadeId) await garantirDoTenant('unidades', unidadeId);
    if (empresaId) await garantirDoTenant('empresas', empresaId);

    try {
      await sql!.unsafe(
        `
          update public.colaboradores set
            nome = coalesce($2, nome),
            status = coalesce($3, status),
            funcao = coalesce($4, funcao),
            departamento_id = case when $5::boolean then $6::uuid else departamento_id end,
            unidade_id = case when $7::boolean then $8::uuid else unidade_id end,
            empresa_id = case when $9::boolean then $10::uuid else empresa_id end,
            atualizado_em = now()
          where id = $1;
        `,
        [
          id, nome, status, nivel,
          departamentoId !== undefined, departamentoId ?? null,
          unidadeId !== undefined, unidadeId ?? null,
          empresaId !== undefined, empresaId ?? null,
        ],
      );
    } catch (error) {
      throw mapDbError(error);
    }

    if (nivel || status) {
      await sql!.unsafe(
        `
          update public.acessos_usuario_sistema set
            nivel_acesso = coalesce($2, nivel_acesso),
            ativo = case when $3::text is null then ativo else $3::text = 'ativo' end,
            atualizado_em = now()
          where colaborador_id = $1
            and sistema_id = (select id from public.sistemas where slug = $4);
        `,
        [id, nivel, status, SERVICOS_SYSTEM_SLUG],
      );
    }
    if (status) {
      // Inativo nao consegue nem entrar: bloqueia o login no Auth.
      await authAdminClient().auth.admin.updateUserById(id, { ban_duration: status === 'ativo' ? 'none' : '876000h' });
    }
    return { success: true };
  }

  if (action === 'usuario_resetar_senha') {
    const id = uuidOuNull(body.id, 'Usuario');
    if (!id) throw httpError('Usuario obrigatorio.');
    await garantirNaoAdminPlataforma(id);
    const atual = await sql!.unsafe(`select id, nome, email from public.colaboradores where id = $1 limit 1;`, [id]);
    if (!atual[0]) throw httpError('Usuario nao encontrado.', 404);

    const senha = gerarSenhaTemporaria();
    const { error } = await authAdminClient().auth.admin.updateUserById(id, { password: senha });
    if (error) throw httpError('Nao foi possivel redefinir a senha.', 500);
    await sql!.unsafe(`update public.colaboradores set precisa_trocar_senha = true, atualizado_em = now() where id = $1;`, [id]);
    const emailEnviado = await entregarAcessoPorEmail(tenantId, {
      nome: String(atual[0].nome), email: String(atual[0].email), senha, motivo: 'redefinicao',
    });
    return { senha_temporaria: emailEnviado ? null : senha, email_enviado: emailEnviado };
  }

  throw httpError('Acao invalida.');
}

// ---------- Admin da plataforma ----------

async function handlePlatformAction(action: string, body: Json, collaborator: Collaborator) {
  if (action === 'tenants_list') {
    const rows = await sqlPool!.unsafe(`
      select t.id, t.nome, t.slug, t.ativo, t.plano, t.criado_em, t.marca_nome, t.marca_cor, t.marca_logo_path,
        (select count(*)::int from public.colaboradores c where c.tenant_id = t.id) as usuarios,
        (select count(*)::int from gestao_servicos.solicitacoes_pagamento sp where sp.tenant_id = t.id) as solicitacoes
      from public.tenants t
      order by t.criado_em;
    `);
    return { rows: rows.map((r) => ({ ...r, marca_logo_url: logoPublicUrl(r.marca_logo_path as string | null) })) };
  }

  if (action === 'tenant_marca_salvar') {
    const tenantId = uuidOuNull(body.tenant_id, 'Cliente');
    if (!tenantId) throw httpError('Informe o cliente.');
    return { marca: await salvarMarca(tenantId, body) };
  }

  if (action === 'tenant_criar') {
    const nome = texto(body.nome, 120);
    const slug = texto(body.slug, 40).toLowerCase();
    const adminNome = texto(body.admin_nome, 120);
    const adminEmail = texto(body.admin_email, 160).toLowerCase();
    const empresaNome = texto(body.empresa_nome, 120) || nome;
    if (!nome) throw httpError('Informe o nome do cliente.');
    if (!SLUG_RE.test(slug)) throw httpError('Slug invalido: use 3 a 40 letras minusculas, numeros e hifen.');
    if (!adminNome) throw httpError('Informe o nome do administrador.');
    if (!EMAIL_RE.test(adminEmail)) throw httpError('Informe um e-mail valido para o administrador.');

    let tenantId: string;
    try {
      const rows = await sqlPool!.unsafe(`insert into public.tenants (nome, slug) values ($1, $2) returning id;`, [nome, slug]);
      tenantId = String(rows[0].id);
    } catch (error) {
      if ((error as { code?: string })?.code === '23505') throw httpError('Ja existe um cliente com esse slug.', 409);
      throw error;
    }

    try {
      const usuario = await runInTenant(sqlPool!, tenantId, async () => {
        const empresa = await sql!.unsafe(
          `insert into public.empresas (nome, slug, tenant_id) values ($1, $2, $3) returning id;`,
          [empresaNome, slug, tenantId],
        );
        await sql!.unsafe(
          `insert into gestao_servicos.configuracoes_modulo (modulo, restringir_visibilidade_pagamento_dinheiro, tenant_id)
           values ('financeiro', true, $1) on conflict (tenant_id, modulo) do nothing;`,
          [tenantId],
        );
        // Sem unidade o checklist da oficina nao avanca; o cliente renomeia/ajusta depois em Cadastros.
        await sql!.unsafe(
          `insert into public.unidades (nome, empresa_id, tenant_id) values ('Matriz', $1, $2);`,
          [String(empresa[0].id), tenantId],
        );
        // Sem categorias o formulario de solicitacao nao deixa enviar; o cliente ajusta depois em Catalogos.
        await sql!.unsafe(
          `insert into gestao_servicos.categorias (nome, tenant_id)
           select n, $1 from unnest($2::text[]) as n on conflict do nothing;`,
          [tenantId, CATEGORIAS_PADRAO],
        );
        return await criarUsuarioNoTenant(tenantId, {
          nome: adminNome,
          email: adminEmail,
          nivelAcesso: 'admin',
          departamentoId: null,
          unidadeId: null,
          empresaId: String(empresa[0].id),
        });
      });
      return { tenant: { id: tenantId, nome, slug }, admin: usuario };
    } catch (error) {
      // A transacao do tenant ja desfez tudo; sobra so a linha de tenants.
      await sqlPool!.unsafe(`delete from public.tenants where id = $1;`, [tenantId]).catch(() => {});
      throw mapDbError(error);
    }
  }

  if (action === 'tenant_atualizar') {
    const id = uuidOuNull(body.id, 'Cliente');
    if (!id) throw httpError('Cliente obrigatorio.');
    const nome = body.nome === undefined ? null : texto(body.nome, 120);
    if (nome === '') throw httpError('Informe o nome.');
    const ativo = typeof body.ativo === 'boolean' ? body.ativo : null;
    const plano = body.plano === undefined ? null : texto(body.plano, 40);
    if (ativo === false && id === tenantIdOf(collaborator)) {
      throw httpError('Voce nao pode desativar o proprio cliente.');
    }
    if (ativo === false && id === TENANT_PADRAO_ID) {
      throw httpError('O cliente padrao e fixo e nao pode ser desativado.');
    }
    const rows = await sqlPool!.unsafe(
      `
        update public.tenants set
          nome = coalesce($2, nome),
          ativo = coalesce($3, ativo),
          plano = coalesce($4, plano),
          atualizado_em = now()
        where id = $1
        returning id, nome, slug, ativo, plano;
      `,
      [id, nome, ativo, plano || null],
    );
    if (!rows[0]) throw httpError('Cliente nao encontrado.', 404);
    return { row: rows[0] };
  }

  if (action === 'tenant_excluir') {
    const id = uuidOuNull(body.id, 'Cliente');
    if (!id) throw httpError('Cliente obrigatorio.');
    if (id === TENANT_PADRAO_ID) throw httpError('O cliente padrao e fixo e nao pode ser excluido.');
    if (id === tenantIdOf(collaborator)) throw httpError('Voce nao pode excluir o proprio cliente.');
    const tenant = (await sqlPool!.unsafe(`select nome, slug, ativo, marca_logo_path from public.tenants where id = $1;`, [id]))[0];
    if (!tenant) throw httpError('Cliente nao encontrado.', 404);
    if (tenant.ativo) throw httpError('Desative o cliente antes de exclui-lo.');
    if (texto(body.confirmar_slug, 40).toLowerCase() !== String(tenant.slug).toLowerCase()) {
      throw httpError('Para confirmar, digite o identificador (slug) do cliente.');
    }
    const admins = await sqlPool!.unsafe(
      `select 1 from plataforma.administradores pa join public.colaboradores c on c.id = pa.user_id where c.tenant_id = $1 limit 1;`,
      [id],
    );
    if (admins.length) throw httpError('Este cliente tem um administrador da plataforma. Remova-o da lista de administradores antes.');

    // Levanta o que precisa ser limpo fora das tabelas (usuarios do Auth e arquivos do Storage) antes de apagar.
    const usuarios = (await sqlPool!.unsafe(`select id from public.colaboradores where tenant_id = $1;`, [id])).map((u: Json) => String(u.id));
    const arquivos = await sqlPool!.unsafe(
      `
        select bucket_id, name from storage.objects
        where (bucket_id = 'comprovantes-pagamento'
                and (storage.foldername(name))[1] in (select s.id::text from gestao_servicos.solicitacoes_pagamento s where s.tenant_id = $1))
           or (bucket_id = 'oficina-checklist-fotos'
                and (storage.foldername(name))[1] in (select a.id::text from gestao_servicos.checklist_avaliacoes a where a.tenant_id = $1))
           or (bucket_id = 'assinaturas' and (storage.foldername(name))[1] = 'colaboradores'
                and (storage.foldername(name))[2] = any($2::text[]));
      `,
      [id, usuarios],
    );

    await sqlPool!.unsafe(`select plataforma.excluir_tenant($1::uuid);`, [id]);

    // Dados ja apagados: a limpeza abaixo e best-effort e informa o que sobrou.
    const admin = authAdminClient();
    const falhas: string[] = [];
    const porBucket = new Map<string, string[]>();
    for (const a of arquivos) {
      const lista = porBucket.get(String(a.bucket_id)) ?? [];
      lista.push(String(a.name));
      porBucket.set(String(a.bucket_id), lista);
    }
    if (tenant.marca_logo_path) porBucket.set('marcas', [...(porBucket.get('marcas') ?? []), String(tenant.marca_logo_path)]);
    for (const [bucket, nomes] of porBucket) {
      for (let i = 0; i < nomes.length; i += 100) {
        const { error } = await admin.storage.from(bucket).remove(nomes.slice(i, i + 100));
        if (error) falhas.push(`arquivos de ${bucket}`);
      }
    }
    for (const userId of usuarios) {
      const { error } = await admin.auth.admin.deleteUser(userId);
      if (error) falhas.push(`usuario ${userId}`);
    }
    return { excluido: { id, nome: tenant.nome, slug: tenant.slug, usuarios: usuarios.length, arquivos: arquivos.length }, falhas };
  }

  if (action === 'tenant_admins') {
    const tenantId = uuidOuNull(body.tenant_id, 'Cliente');
    if (!tenantId) throw httpError('Cliente obrigatorio.');
    const rows = await sqlPool!.unsafe(
      `select id, nome, email from public.colaboradores where tenant_id = $1 and funcao = 'admin' order by nome;`,
      [tenantId],
    );
    return { rows };
  }

  // Adiciona um administrador a um cliente que ja existe (tenant_criar so cria o primeiro).
  if (action === 'tenant_admin_criar') {
    const tenantId = uuidOuNull(body.tenant_id, 'Cliente');
    const nome = texto(body.nome, 120);
    const email = texto(body.email, 160).toLowerCase();
    if (!tenantId) throw httpError('Cliente obrigatorio.');
    if (!nome) throw httpError('Informe o nome.');
    if (!EMAIL_RE.test(email)) throw httpError('Informe um e-mail valido.');
    const existe = await sqlPool!.unsafe(`select 1 from public.tenants where id = $1;`, [tenantId]);
    if (!existe[0]) throw httpError('Cliente nao encontrado.', 404);
    try {
      const usuario = await runInTenant(sqlPool!, tenantId, async () => {
        const empresa = await sql!.unsafe(`select id from public.empresas order by criado_em limit 1;`);
        return await criarUsuarioNoTenant(tenantId, {
          nome,
          email,
          nivelAcesso: 'admin',
          departamentoId: null,
          unidadeId: null,
          empresaId: empresa[0] ? String(empresa[0].id) : null,
        });
      });
      const emailEnviado = await entregarAcessoPorEmail(tenantId, { nome, email, senha: String(usuario.senha_temporaria), motivo: 'convite' });
      return { row: { ...usuario, senha_temporaria: emailEnviado ? null : usuario.senha_temporaria, email_enviado: emailEnviado } };
    } catch (error) {
      throw mapDbError(error);
    }
  }

  if (action === 'tenant_admin_resetar_senha') {
    const tenantId = uuidOuNull(body.tenant_id, 'Cliente');
    const userId = uuidOuNull(body.user_id, 'Usuario');
    if (!tenantId || !userId) throw httpError('Cliente e usuario sao obrigatorios.');
    const alvo = await sqlPool!.unsafe(`select id, nome, email from public.colaboradores where id = $1 and tenant_id = $2 limit 1;`, [userId, tenantId]);
    if (!alvo[0]) throw httpError('Usuario nao encontrado nesse cliente.', 404);
    const senha = gerarSenhaTemporaria();
    const { error } = await authAdminClient().auth.admin.updateUserById(userId, { password: senha });
    if (error) throw httpError('Nao foi possivel redefinir a senha.', 500);
    await sqlPool!.unsafe(`update public.colaboradores set precisa_trocar_senha = true, atualizado_em = now() where id = $1;`, [userId]);
    const emailEnviado = await entregarAcessoPorEmail(tenantId, {
      nome: String(alvo[0].nome), email: String(alvo[0].email), senha, motivo: 'redefinicao',
    });
    return { senha_temporaria: emailEnviado ? null : senha, email_enviado: emailEnviado };
  }

  if (action === 'catalogo_listar') {
    const [marcas, categorias, cores, modelos] = await Promise.all([
      sqlPool!.unsafe(`
        select m.id, m.nome, m.ativo, (select count(*)::int from public.modelos_veiculo x where x.marca_id = m.id) as modelos
        from public.marcas_veiculo m order by m.nome;`),
      sqlPool!.unsafe(`select id, nome, ativo from public.categorias_veiculo order by nome;`),
      sqlPool!.unsafe(`select id, nome from public.cores_veiculo order by nome;`),
      sqlPool!.unsafe(`
        select x.id, x.nome, x.ativo, x.marca_id, x.categoria_veiculo_id, m.nome as marca_nome, c.nome as categoria_nome,
               (select count(*)::int from public.veiculos v where v.modelo_id = x.id) as veiculos
        from public.modelos_veiculo x
        join public.marcas_veiculo m on m.id = x.marca_id
        join public.categorias_veiculo c on c.id = x.categoria_veiculo_id
        order by m.nome, x.nome;`),
    ]);
    return { marcas, categorias, cores, modelos };
  }

  if (action === 'catalogo_salvar') {
    const tipo = pertenceA(CATALOGOS, body.tipo, 'Catalogo');
    const tabela = TABELA_CATALOGO[tipo];
    const id = uuidOuNull(body.id, 'Item');
    const nome = texto(body.nome, 80);
    if (!nome) throw httpError('Informe o nome.');
    const ativo = body.ativo === undefined ? null : Boolean(body.ativo);
    try {
      if (tipo === 'modelos') {
        const marcaId = uuidOuNull(body.marca_id, 'Marca');
        const categoriaId = uuidOuNull(body.categoria_veiculo_id, 'Categoria');
        if (!marcaId || !categoriaId) throw httpError('Informe a marca e a categoria.');
        const rows = id
          ? await sqlPool!.unsafe(
            `update public.modelos_veiculo set nome = $2, marca_id = $3, categoria_veiculo_id = $4, ativo = coalesce($5, ativo)
             where id = $1 returning id;`,
            [id, nome, marcaId, categoriaId, ativo],
          )
          : await sqlPool!.unsafe(
            `insert into public.modelos_veiculo (nome, marca_id, categoria_veiculo_id, ativo) values ($1, $2, $3, coalesce($4, true)) returning id;`,
            [nome, marcaId, categoriaId, ativo],
          );
        if (!rows[0]) throw httpError('Item nao encontrado.', 404);
        return { id: rows[0].id };
      }
      const temAtivo = tipo !== 'cores';
      const rows = id
        ? await sqlPool!.unsafe(
          temAtivo
            ? `update public.${tabela} set nome = $2, ativo = coalesce($3, ativo) where id = $1 returning id;`
            : `update public.${tabela} set nome = $2 where id = $1 returning id;`,
          temAtivo ? [id, nome, ativo] : [id, nome],
        )
        : await sqlPool!.unsafe(
          temAtivo
            ? `insert into public.${tabela} (nome, ativo) values ($1, coalesce($2, true)) returning id;`
            : `insert into public.${tabela} (nome) values ($1) returning id;`,
          temAtivo ? [nome, ativo] : [nome],
        );
      if (!rows[0]) throw httpError('Item nao encontrado.', 404);
      return { id: rows[0].id };
    } catch (error) {
      const code = (error as { code?: string })?.code;
      if (code === '23505') throw httpError('Ja existe um item com esse nome.', 409);
      if (code === '23503') throw httpError('Marca ou categoria invalida.');
      throw error;
    }
  }

  if (action === 'catalogo_excluir') {
    const tipo = pertenceA(CATALOGOS, body.tipo, 'Catalogo');
    const id = uuidOuNull(body.id, 'Item');
    if (!id) throw httpError('Item obrigatorio.');
    try {
      const rows = await sqlPool!.unsafe(`delete from public.${TABELA_CATALOGO[tipo]} where id = $1 returning id;`, [id]);
      if (!rows[0]) throw httpError('Item nao encontrado.', 404);
      return { success: true };
    } catch (error) {
      if ((error as { code?: string })?.code === '23503') {
        throw httpError('Item em uso por veiculos ou modelos; desative-o em vez de excluir.', 409);
      }
      throw error;
    }
  }

  if (action === 'admins_list') {
    const rows = await sqlPool!.unsafe(`
      select a.user_id, u.email, a.criado_em, c.nome, t.nome as cliente
      from plataforma.administradores a
      join auth.users u on u.id = a.user_id
      left join public.colaboradores c on c.id = a.user_id
      left join public.tenants t on t.id = c.tenant_id
      order by a.criado_em;
    `);
    return { rows };
  }

  if (action === 'admin_adicionar') {
    const email = texto(body.email, 160).toLowerCase();
    if (!EMAIL_RE.test(email)) throw httpError('Informe um e-mail valido.');
    const users = await sqlPool!.unsafe(`select id from auth.users where lower(email) = $1 limit 1;`, [email]);
    if (!users[0]) throw httpError('Nenhum usuario com esse e-mail. Crie o usuario em um cliente primeiro.', 404);
    await sqlPool!.unsafe(`insert into plataforma.administradores (user_id) values ($1) on conflict do nothing;`, [users[0].id]);
    return { success: true, user_id: users[0].id };
  }

  if (action === 'admin_remover') {
    const userId = uuidOuNull(body.user_id, 'Usuario');
    if (!userId) throw httpError('Usuario obrigatorio.');
    if (userId === String(collaborator.id)) throw httpError('Voce nao pode remover a si mesmo.');
    const total = await sqlPool!.unsafe(`select count(*)::int as n from plataforma.administradores;`);
    if (Number(total[0].n) <= 1) throw httpError('Mantenha ao menos um administrador da plataforma.');
    await sqlPool!.unsafe(`delete from plataforma.administradores where user_id = $1;`, [userId]);
    return { success: true };
  }

  if (action === 'auditoria_list') {
    const tenantId = uuidOuNull(body.tenant_id, 'Cliente');
    const rows = await sqlPool!.unsafe(
      `
        select a.id, a.criado_em, a.ator_email, a.acao, a.alvo, a.detalhes, a.tenant_id, t.nome as tenant_nome
        from plataforma.auditoria a
        left join public.tenants t on t.id = a.tenant_id
        where ($1::uuid is null or a.tenant_id = $1::uuid)
        order by a.criado_em desc
        limit 300;
      `,
      [tenantId],
    );
    return { rows };
  }

  throw httpError('Acao invalida.');
}

// ---------- Integracao de e-mail (Gmail) do tenant ----------
// Roda no pool dono (schema integracoes e fechado ao papel do tenant); o tenant vem sempre da sessao,
// nunca do corpo. Segredos vao para o Vault e nunca voltam ao navegador.

const GMAIL_CHAVE = 'gmail_notificacoes';
const GMAIL_SEGREDOS = ['client_secret', 'refresh_token'] as const;

async function obterIntegracaoGmail(tenantId: string) {
  const rows = await sqlPool!.unsafe(
    `select i.id, i.ativo, i.config, i.atualizado_em,
            coalesce((select array_agg(s.chave) from integracoes.integracoes_secrets s where s.integracao_id = i.id), '{}') as segredos
     from integracoes.integracoes i where i.tenant_id = $1 and i.chave = $2;`,
    [tenantId, GMAIL_CHAVE],
  );
  const row = rows[0];
  if (!row) return { configurada: false, ativo: false, sender: '', client_id: '', segredos: [] };
  const config = (row.config || {}) as Json;
  return {
    configurada: true,
    ativo: Boolean(row.ativo),
    sender: String(config.sender || ''),
    client_id: String(config.client_id || ''),
    segredos: row.segredos as string[],
    atualizado_em: row.atualizado_em,
  };
}

// WhatsApp por cliente: por enquanto so a estrutura (sem provedor registrado, nada e enviado). Ver _shared/whatsapp.ts.
async function obterIntegracaoWhatsapp(tenantId: string) {
  const rows = await sqlPool!.unsafe(
    `select provider, ativo from integracoes.integracoes where tenant_id = $1 and chave = $2;`,
    [tenantId, WHATSAPP_INTEGRACAO_CHAVE],
  );
  const row = rows[0];
  return {
    configurada: Boolean(row),
    provider: row ? String(row.provider) : 'nenhum',
    ativo: row ? Boolean(row.ativo) : false,
    providers_disponiveis: listWhatsappProviders(),
  };
}

async function salvarIntegracaoGmail(body: Json, tenantId: string, collaboratorId: string) {
  const sender = texto(body.sender, 160).toLowerCase();
  const clientId = texto(body.client_id, 300);
  if (!EMAIL_RE.test(sender)) throw httpError('Informe o e-mail remetente valido.');
  if (!clientId) throw httpError('Informe o Client ID.');
  const ativo = body.ativo === undefined ? true : Boolean(body.ativo);
  const novos: Record<string, string> = {};
  for (const campo of GMAIL_SEGREDOS) {
    const valor = texto(body[campo], 2000);
    if (valor) novos[campo] = valor;
  }

  await sqlPool!.begin(async (tx) => {
    const config = { sender, client_id: clientId };
    const rows = await tx.unsafe(
      `insert into integracoes.integracoes (tenant_id, chave, provider, descricao, ativo, config, atualizado_por, atualizado_em)
       values ($1, $2, 'gmail', 'E-mail de notificacoes (Gmail API)', $3, $4::text::jsonb, $5, now())
       on conflict (tenant_id, chave) do update
         set ativo = excluded.ativo, config = excluded.config, atualizado_por = excluded.atualizado_por, atualizado_em = now()
       returning id;`,
      [tenantId, GMAIL_CHAVE, ativo, JSON.stringify(config), collaboratorId],
    );
    const integracaoId = String(rows[0].id);

    const existentes = await tx.unsafe(
      `select chave, secret_id from integracoes.integracoes_secrets where integracao_id = $1;`,
      [integracaoId],
    );
    const porChave = new Map(existentes.map((r) => [String(r.chave), String(r.secret_id)]));

    for (const [campo, valor] of Object.entries(novos)) {
      const atual = porChave.get(campo);
      if (atual) {
        await tx.unsafe(`select vault.update_secret($1::uuid, $2);`, [atual, valor]);
        await tx.unsafe(`update integracoes.integracoes_secrets set atualizado_em = now() where integracao_id = $1 and chave = $2;`, [integracaoId, campo]);
      } else {
        const created = await tx.unsafe(`select vault.create_secret($1, $2, $3) as id;`, [valor, `integracao:${tenantId}:${GMAIL_CHAVE}:${campo}`, `${GMAIL_CHAVE} ${campo}`]);
        await tx.unsafe(
          `insert into integracoes.integracoes_secrets (integracao_id, chave, secret_id) values ($1, $2, $3);`,
          [integracaoId, campo, created[0].id],
        );
        porChave.set(campo, String(created[0].id));
      }
    }

    if (ativo) {
      const faltando = GMAIL_SEGREDOS.filter((c) => !porChave.has(c));
      if (faltando.length) throw httpError(`Informe: ${faltando.join(', ')}.`);
    }
  });

  return await obterIntegracaoGmail(tenantId);
}

const TENANT_ACTIONS = new Set(['cadastros_list', 'cadastro_salvar', 'cadastro_excluir', 'usuarios_list', 'usuario_criar', 'usuario_atualizar', 'usuario_resetar_senha']);
const INTEGRACAO_ACTIONS = new Set(['integracao_gmail_obter', 'integracao_gmail_salvar', 'integracao_whatsapp_obter']);
const CATALOGOS = ['marcas', 'categorias', 'cores', 'modelos'] as const;
const TABELA_CATALOGO = { marcas: 'marcas_veiculo', categorias: 'categorias_veiculo', cores: 'cores_veiculo', modelos: 'modelos_veiculo' } as const;

const MARCA_ACTIONS = new Set(['marca_obter', 'marca_salvar']);
const PLATFORM_ACTIONS = new Set(['tenant_marca_salvar', 'catalogo_listar', 'catalogo_salvar', 'catalogo_excluir', 'tenants_list', 'tenant_criar', 'tenant_atualizar', 'tenant_excluir', 'tenant_admins', 'tenant_admin_criar', 'tenant_admin_resetar_senha', 'admins_list', 'admin_adicionar', 'admin_remover', 'auditoria_list']);

// Acoes que alteram dados e por isso entram na trilha de auditoria (as de leitura ficam de fora).
const AUDITED_ACTIONS = new Set([
  'tenant_criar', 'tenant_atualizar', 'tenant_excluir', 'tenant_admin_criar', 'tenant_admin_resetar_senha', 'admin_adicionar', 'admin_remover',
  'usuario_criar', 'usuario_atualizar', 'usuario_resetar_senha',
  'cadastro_salvar', 'cadastro_excluir', 'integracao_gmail_salvar', 'catalogo_salvar', 'catalogo_excluir',
  'tenant_marca_salvar', 'marca_salvar',
]);
// Somente estes campos do corpo vao para o log: nunca senhas, segredos ou tokens.
const AUDIT_FIELDS = ['nome', 'slug', 'confirmar_slug', 'email', 'admin_email', 'admin_nome', 'ativo', 'plano', 'nivel_acesso', 'status', 'tipo', 'marca_id', 'categoria_veiculo_id', 'sender', 'client_id', 'marca_nome', 'marca_cor', 'remover_logo', 'id', 'user_id', 'tenant_id'];

async function registrarAuditoria(user: { id: string; email?: string }, tenantId: string | null, action: string, body: Json, result: Json) {
  try {
    const detalhes: Json = {};
    for (const campo of AUDIT_FIELDS) {
      if (body[campo] !== undefined && typeof body[campo] !== 'object') detalhes[campo] = body[campo];
    }
    const alvo = String(body.admin_email || body.email || body.slug || body.id || body.user_id || '') || null;
    await sqlPool!.unsafe(
      `insert into plataforma.auditoria (ator_id, ator_email, tenant_id, acao, alvo, detalhes)
       values ($1, $2, $3, $4, $5, $6::text::jsonb);`,
      [user.id, user.email || null, tenantId, action, alvo, JSON.stringify({ ...detalhes, ...result })],
    );
  } catch (error) {
    console.error('Falha ao registrar auditoria:', error);
  }
}

Deno.serve(async (request) => {
  const corsHeaders = buildCorsHeaders(request);
  const json = (data: unknown, status = 200) => jsonResponse(data, status, corsHeaders);

  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    if (!sqlPool || !sql) return json({ error: 'DATABASE_URL nao configurada.' }, 500);

    const token = getBearerToken(request);
    const user = await getAuthenticatedUser(token, supabaseUrl, supabaseAnonKey);
    const aal = sessionAal(token);
    const collaborator = await getCurrentCollaborator(sqlPool, user);
    if (!collaborator?.id) throw httpError('Usuario sem cadastro.', 403);
    const tenantId = tenantIdOf(collaborator);
    if (!tenantId) throw httpError('Usuario sem empresa (tenant) vinculada.', 403);

    const platformRows = await sqlPool.unsafe(`select 1 from plataforma.administradores where user_id = $1 limit 1;`, [user.id]);
    const isPlatformAdmin = platformRows.length > 0;

    const body = await request.json().catch(() => ({}));
    const action = String(body.action || 'me');

    if (action === 'me') {
      const access = await getServicosAccess(sqlPool, String(collaborator.id));
      const tenant = await sqlPool.unsafe(`select id, nome, slug from public.tenants where id = $1;`, [tenantId]);
      return json({
        is_platform_admin: isPlatformAdmin,
        aal,
        is_tenant_admin: getAccessLevel(access) === 'admin',
        tenant: tenant[0] || null,
      });
    }

    if (PLATFORM_ACTIONS.has(action)) {
      if (!isPlatformAdmin) throw httpError('Acesso restrito a administradores da plataforma.', 403);
      if (platformRequiresMfa && aal !== 'aal2') {
        throw Object.assign(httpError('Confirme o segundo fator (MFA) para acessar a plataforma.', 403), { code: 'mfa_required' });
      }
      const resultado = await handlePlatformAction(action, body, collaborator);
      if (AUDITED_ACTIONS.has(action)) {
        const r = resultado as Json;
        const alvoTenant = action === 'tenant_excluir' ? null : uuidOuNull((r.tenant as Json | undefined)?.id ?? (r.row as Json | undefined)?.id ?? body.tenant_id ?? body.id, 'Cliente');
        await registrarAuditoria(user, action.startsWith('tenant_') ? alvoTenant : null, action, body, {});
      }
      return json(resultado);
    }

    if (INTEGRACAO_ACTIONS.has(action)) {
      const access = await getServicosAccess(sqlPool, String(collaborator.id));
      if (getAccessLevel(access) !== 'admin') throw httpError('Apenas administradores podem gerenciar integracoes.', 403);
      if (action === 'integracao_gmail_obter') return json(await obterIntegracaoGmail(tenantId));
      if (action === 'integracao_whatsapp_obter') return json(await obterIntegracaoWhatsapp(tenantId));
      const salvo = await salvarIntegracaoGmail(body, tenantId, String(collaborator.id));
      await registrarAuditoria(user, tenantId, action, body, {});
      return json(salvo);
    }

    if (MARCA_ACTIONS.has(action)) {
      const access = await getServicosAccess(sqlPool, String(collaborator.id));
      if (getAccessLevel(access) !== 'admin') throw httpError('Apenas administradores podem alterar a identidade visual.', 403);
      if (action === 'marca_obter') return json({ marca: await obterMarca(tenantId) });
      const marca = await salvarMarca(tenantId, body);
      await registrarAuditoria(user, tenantId, action, body, {});
      return json({ marca });
    }

    if (TENANT_ACTIONS.has(action)) {
      const access = await getServicosAccess(sqlPool, String(collaborator.id));
      if (getAccessLevel(access) !== 'admin') throw httpError('Apenas administradores podem gerenciar usuarios.', 403);
      const resultado = await runInTenant(sqlPool, tenantId, () => handleTenantAction(action, body, collaborator, tenantId));
      if (AUDITED_ACTIONS.has(action)) await registrarAuditoria(user, tenantId, action, body, {});
      return json(resultado);
    }

    return json({ error: 'Acao invalida.' }, 400);
  } catch (error) {
    return json({ error: getErrorMessage(error), code: getErrorCode(error) }, getErrorStatus(error));
  }
});

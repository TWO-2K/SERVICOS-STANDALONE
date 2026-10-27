// O app dos clientes abre por um caminho com o slug da empresa (/acme, /acme/solicitacoes). O slug so escolhe a marca
// da tela de login; o cliente do usuario sempre vem da conta dele (o backend confere).
const SLUG_RE = /^[a-z0-9](?:[a-z0-9-]{1,38})[a-z0-9]$/;
const STORAGE_KEY = 'app.tenantSlug';

// Primeiros segmentos das rotas do app: links antigos (sem slug) caem aqui e sao levados para a empresa lembrada.
const ROTAS_DO_APP = new Set([
  'entrar', 'login', 'checklist-publico', 'solicitacoes', 'aprovacoes', 'pagamentos', 'calendario-vencimentos',
  'fornecedores', 'categorias', 'relatorios', 'configuracoes', 'permissoes', 'atendimento', 'oficina', 'estoque',
  'compras', 'rh',
]);

export function isValidSlug(value) {
  return SLUG_RE.test(String(value || ''));
}

export function getRememberedSlug() {
  try {
    const value = window.localStorage.getItem(STORAGE_KEY);
    return isValidSlug(value) ? value : null;
  } catch {
    return null;
  }
}

export function rememberSlug(slug) {
  try {
    window.localStorage.setItem(STORAGE_KEY, slug);
  } catch {
    // Best effort: storage bloqueado so desliga o atalho "lembrar empresa".
  }
}

function readLocation() {
  const [first] = window.location.pathname.split('/').filter(Boolean);
  if (!first) return { slug: null, legacy: true };
  if (ROTAS_DO_APP.has(first)) return { slug: null, legacy: true };
  return { slug: isValidSlug(first) ? first : null, legacy: false };
}

const { slug: initialSlug, legacy } = readLocation();

// null = sem empresa no endereco (abre a escolha de empresa).
export const TENANT_SLUG = initialSlug;

// Raiz (/) ou link antigo (/solicitacoes?sol=...) com empresa lembrada: devolve o endereco novo (/acme, /acme/solicitacoes?sol=...).
export function getLegacyRedirect() {
  const remembered = getRememberedSlug();
  if (!legacy || !remembered) return null;
  const caminho = window.location.pathname === '/' ? '' : window.location.pathname;
  return `/${remembered}${caminho}${window.location.search}${window.location.hash}`;
}

// Caminho absoluto dentro do app da empresa atual (para links compartilhados e redirecionamentos manuais).
export function appPath(path = '/') {
  return TENANT_SLUG ? `/${TENANT_SLUG}${path === '/' ? '' : path}` : path;
}

export function appUrl(path = '/') {
  return `${window.location.origin}${appPath(path)}`;
}

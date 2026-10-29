import { assertSupabaseConfigured, supabase } from './supabaseClient';

function toError(message, status = 500, code) {
  const error = new Error(typeof message === 'string' ? message : 'Falha na administracao.');
  error.status = status;
  if (code) error.code = code;
  return error;
}

async function invokeAdmin(body = {}) {
  assertSupabaseConfigured();
  const { data } = await supabase.auth.getSession();
  const token = data?.session?.access_token;

  if (!token) {
    throw toError('Sessao expirada. Faca login novamente.', 401, 'auth_required');
  }

  const response = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/admin-api`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      apikey: import.meta.env.VITE_SUPABASE_ANON_KEY,
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify(body),
  });

  const result = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw toError(result?.error, response.status, result?.code);
  }
  return result;
}

// Administracao de usuarios (admin do tenant) e de clientes/tenants (admin da plataforma).
export const adminApi = {
  async me() {
    const result = await invokeAdmin({ action: 'me' });
    return {
      isPlatformAdmin: Boolean(result.is_platform_admin),
      isTenantAdmin: Boolean(result.is_tenant_admin),
      tenant: result.tenant || null,
    };
  },
  cadastros: {
    async list() {
      const result = await invokeAdmin({ action: 'cadastros_list' });
      return {
        empresas: result.empresas || [],
        unidades: result.unidades || [],
        departamentos: result.departamentos || [],
        cargos: result.cargos || [],
      };
    },
    async salvar(tipo, dados) {
      return invokeAdmin({ action: 'cadastro_salvar', tipo, ...dados });
    },
    async excluir(tipo, id) {
      return invokeAdmin({ action: 'cadastro_excluir', tipo, id });
    },
  },
  usuarios: {
    async list() {
      const result = await invokeAdmin({ action: 'usuarios_list' });
      return {
        rows: result.rows || [],
        departamentos: result.departamentos || [],
        unidades: result.unidades || [],
        empresas: result.empresas || [],
      };
    },
    async criar(dados) {
      const result = await invokeAdmin({ action: 'usuario_criar', ...dados });
      return result.row;
    },
    async atualizar(id, dados) {
      return invokeAdmin({ action: 'usuario_atualizar', id, ...dados });
    },
    async resetarSenha(id) {
      return invokeAdmin({ action: 'usuario_resetar_senha', id });
    },
  },
  integracoes: {
    gmailObter() {
      return invokeAdmin({ action: 'integracao_gmail_obter' });
    },
    gmailSalvar(dados) {
      return invokeAdmin({ action: 'integracao_gmail_salvar', ...dados });
    },
  },
  marca: {
    async obter() {
      const result = await invokeAdmin({ action: 'marca_obter' });
      return result.marca;
    },
    async salvar(dados) {
      const result = await invokeAdmin({ action: 'marca_salvar', ...dados });
      return result.marca;
    },
  },
  plataforma: {
    catalogo: {
      list() {
        return invokeAdmin({ action: 'catalogo_listar' });
      },
      salvar(dados) {
        return invokeAdmin({ action: 'catalogo_salvar', ...dados });
      },
      excluir(tipo, id) {
        return invokeAdmin({ action: 'catalogo_excluir', tipo, id });
      },
    },
    async admins() {
      const result = await invokeAdmin({ action: 'admins_list' });
      return result.rows || [];
    },
    async adicionarAdmin(email) {
      return invokeAdmin({ action: 'admin_adicionar', email });
    },
    async removerAdmin(userId) {
      return invokeAdmin({ action: 'admin_remover', user_id: userId });
    },
    async auditoria(tenantId) {
      const result = await invokeAdmin({ action: 'auditoria_list', tenant_id: tenantId || undefined });
      return result.rows || [];
    },
  },
  tenants: {
    async list() {
      const result = await invokeAdmin({ action: 'tenants_list' });
      return result.rows || [];
    },
    async criar(dados) {
      return invokeAdmin({ action: 'tenant_criar', ...dados });
    },
    async admins(tenantId) {
      const result = await invokeAdmin({ action: 'tenant_admins', tenant_id: tenantId });
      return result.rows || [];
    },
    async criarAdmin(tenantId, dados) {
      return invokeAdmin({ action: 'tenant_admin_criar', tenant_id: tenantId, ...dados });
    },
    async resetarSenhaAdmin(tenantId, userId) {
      return invokeAdmin({ action: 'tenant_admin_resetar_senha', tenant_id: tenantId, user_id: userId });
    },
    async atualizar(id, dados) {
      const result = await invokeAdmin({ action: 'tenant_atualizar', id, ...dados });
      return result.row;
    },
    async excluir(id, confirmarSlug) {
      return invokeAdmin({ action: 'tenant_excluir', id, confirmar_slug: confirmarSlug });
    },
    async salvarMarca(tenantId, dados) {
      const result = await invokeAdmin({ action: 'tenant_marca_salvar', tenant_id: tenantId, ...dados });
      return result.marca;
    },
  },
};

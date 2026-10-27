// Leitura de credenciais do schema `integracoes` (config nao sensivel + segredos do Vault,
// resolvidos via integracoes.get_credenciais). Cada tenant tem as suas proprias integracoes.
// O schema nao e exposto na API REST: a leitura e por SQL direto, com a conexao dona do banco.

type SqlUnsafe = { unsafe: (query: string, params?: unknown[]) => Promise<Array<Record<string, unknown>>> };

export interface IntegracaoCredenciaisContext {
  // Conexao postgres.js do chamador (pool dono, nunca o proxy escopado ao tenant).
  sql?: SqlUnsafe | null;
  // Tenant dono da credencial. Sem ele nada e carregado: nunca cair na conta de outro cliente.
  tenantId?: string | null;
}

export async function loadIntegracaoCredenciais(
  chave: string,
  ctx: IntegracaoCredenciaisContext,
): Promise<Record<string, unknown> | null> {
  if (!ctx.sql || !ctx.tenantId) return null;

  try {
    const rows = await ctx.sql.unsafe(`select integracoes.get_credenciais($1, $2::uuid) as credenciais;`, [chave, ctx.tenantId]);
    return (rows[0]?.credenciais as Record<string, unknown> | null) || null;
  } catch (error) {
    console.error(`Erro ao carregar credenciais da integracao "${chave}":`, error);
    return null;
  }
}

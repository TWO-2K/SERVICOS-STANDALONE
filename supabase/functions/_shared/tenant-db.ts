// Isolamento por tenant nas Edge Functions que falam direto com o Postgres.
//
// O pool (`postgres(...)`) conecta como dono do banco e ignora RLS. Para que o isolamento valha tambem aqui,
// cada requisicao autenticada roda dentro de uma transacao com `set local role app_tenant` e a GUC
// `app.tenant_id` (lida por public.current_tenant_id() e pela policy tenant_isolation). O codigo das
// queries nao muda: `sql` e um proxy que usa a transacao da requisicao quando existe e o pool caso contrario.
import { AsyncLocalStorage } from 'node:async_hooks';

// deno-lint-ignore no-explicit-any
type AnySql = any;

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type TenantStore = { tx: AnySql; tenantId: string };
const storage = new AsyncLocalStorage<TenantStore>();

export function createScopedSql(pool: AnySql): AnySql {
  const current = () => storage.getStore()?.tx ?? pool;
  return new Proxy(function () {}, {
    apply: (_target, _this, args) => current()(...args),
    get: (_target, prop) => {
      const target = current();
      // Dentro da transacao da requisicao nao existe `begin` aninhado: usa SAVEPOINT, que mantem a atomicidade
      // do bloco (erro desfaz so o bloco) e a mesma interface `fn(trx)` esperada pelo codigo das rotas.
      if (prop === 'begin' && target !== pool && typeof target.savepoint === 'function') {
        return (fn: (trx: AnySql) => Promise<unknown>) => target.savepoint((sp: AnySql) => fn(sp));
      }
      const value = target[prop];
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
}

export async function runInTenant<T>(pool: AnySql, tenantId: string, fn: () => Promise<T>): Promise<T> {
  if (!UUID_RE.test(tenantId)) {
    throw Object.assign(new Error('Tenant invalido.'), { status: 403 });
  }
  return await pool.begin(async (tx: AnySql) => {
    await tx.unsafe(`select set_config('app.tenant_id', $1, true);`, [tenantId]);
    await tx.unsafe('set local role app_tenant;');
    return await storage.run({ tx, tenantId }, fn);
  });
}

// Tenant da requisicao atual (dentro de runInTenant) -- usado para chavear caches em memoria
// que, por serem globais ao isolate, sao reaproveitados entre requisicoes de tenants diferentes.
export function getCurrentTenantId(): string | null {
  return storage.getStore()?.tenantId ?? null;
}

export function tenantIdOf(collaborator: Record<string, unknown> | null | undefined): string | null {
  const value = collaborator?.tenant_id;
  return typeof value === 'string' && UUID_RE.test(value) ? value : null;
}

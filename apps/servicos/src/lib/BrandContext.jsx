import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';

import { BrandLoader, Button } from '@/shared/ui';
import { APP_NAME, LOGO_URL } from '@/lib/branding';
import { TENANT_SLUG, rememberSlug } from '@/lib/tenant';
import EscolherEmpresa from '@/pages/EscolherEmpresa';

// Marca da empresa (nome, cor, logo), buscada pelo slug do endereco antes do login.
const BrandContext = createContext(null);

async function fetchBrand(slug) {
  const response = await fetch(`${import.meta.env.VITE_SUPABASE_URL}/functions/v1/marca-publica`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', apikey: import.meta.env.VITE_SUPABASE_ANON_KEY },
    body: JSON.stringify({ slug }),
  });
  if (response.status === 404) return null;
  if (!response.ok) throw new Error('Nao foi possivel carregar a empresa.');
  return response.json();
}

// Ultima marca vista por slug: permite renderizar de imediato e revalidar em segundo plano,
// em vez de bloquear a tela inteira numa chamada de rede a cada carga.
const BRAND_CACHE_KEY = `brand:${TENANT_SLUG}`;

function readCachedBrand() {
  try {
    const raw = localStorage.getItem(BRAND_CACHE_KEY);
    return raw ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
}

function writeCachedBrand(brand) {
  try {
    if (brand) localStorage.setItem(BRAND_CACHE_KEY, JSON.stringify(brand));
    else localStorage.removeItem(BRAND_CACHE_KEY);
  } catch {
    // storage indisponivel: segue sem cache
  }
}

export function BrandProvider({ children }) {
  const [cached] = useState(() => (TENANT_SLUG ? readCachedBrand() : null));
  const [brand, setBrand] = useState(cached);
  const [state, setState] = useState(TENANT_SLUG ? (cached ? 'ready' : 'loading') : 'missing');

  const load = useCallback(async () => {
    if (!TENANT_SLUG) return;
    try {
      const result = await fetchBrand(TENANT_SLUG);
      if (!result) {
        writeCachedBrand(null);
        setState('notfound');
        return;
      }
      rememberSlug(TENANT_SLUG);
      writeCachedBrand(result);
      setBrand(result);
      setState('ready');
    } catch {
      // Com marca em cache, uma falha de rede nao derruba a tela.
      setState((current) => (current === 'ready' ? current : 'error'));
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  // A cor da marca nao e aplicada aqui: o login e generico, e BrandTheme (App.jsx) aplica so apos autenticar.
  useEffect(() => {
    document.title = APP_NAME;
  }, []);

  const value = useMemo(
    () => ({
      slug: TENANT_SLUG,
      nome: brand?.nome || APP_NAME,
      produto: APP_NAME,
      logoUrl: brand?.logo_url || LOGO_URL,
      cor: brand?.cor || null,
      reload: load,
    }),
    [brand, load],
  );

  if (state === 'missing') return <EscolherEmpresa />;
  if (state === 'notfound') return <EscolherEmpresa erro="Empresa não encontrada. Confira o endereço informado pela sua empresa." />;
  if (state === 'error') {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center gap-3 p-4 text-center">
        <p className="text-sm text-muted-foreground">Não foi possível carregar a empresa. Verifique a conexão.</p>
        <Button
          onClick={() => {
            setState('loading');
            load();
          }}
        >
          Tentar novamente
        </Button>
      </div>
    );
  }
  if (state === 'loading') return <BrandLoader />;

  return <BrandContext.Provider value={value}>{children}</BrandContext.Provider>;
}

export function useBrand() {
  const context = useContext(BrandContext);
  if (!context) throw new Error('useBrand must be used within a BrandProvider');
  return context;
}

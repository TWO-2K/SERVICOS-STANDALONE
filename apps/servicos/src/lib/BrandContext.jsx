import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';

import { BrandLoader, Button } from '@/shared/ui';
import { applyBrandColor } from '@/lib/brandColor';
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

export function BrandProvider({ children }) {
  const [brand, setBrand] = useState(null);
  const [state, setState] = useState(TENANT_SLUG ? 'loading' : 'missing');

  const load = useCallback(async () => {
    if (!TENANT_SLUG) return;
    try {
      const result = await fetchBrand(TENANT_SLUG);
      if (!result) {
        setState('notfound');
        return;
      }
      rememberSlug(TENANT_SLUG);
      setBrand(result);
      setState('ready');
    } catch {
      setState('error');
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  useEffect(() => {
    applyBrandColor(brand?.cor);
    document.title = APP_NAME;
  }, [brand]);

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

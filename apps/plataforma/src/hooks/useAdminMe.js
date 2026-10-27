import { useAuth } from '@/lib/AuthContext';

// O painel so abre para admin da plataforma (garantido pelo AuthContext); aqui so expoe o cliente do admin logado.
export function useAdminMe() {
  const { me } = useAuth();
  return { isPlatformAdmin: Boolean(me?.isPlatformAdmin), tenant: me?.tenant || null, isLoading: false };
}

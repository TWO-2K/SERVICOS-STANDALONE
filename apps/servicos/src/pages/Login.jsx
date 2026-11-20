import { AuthLoginCard } from '@/shared/ui';
import { useAuth } from '@/lib/AuthContext';
import { useBrand } from '@/lib/BrandContext';
import { APP_NAME, LOGO_URL } from '@/lib/branding';

// Login reflete a identidade do cliente: nome do sistema + nome da empresa, logo e fundo vem da
// identidade visual (Configuracoes); sem personalizacao, cai nos valores padrao.
export default function Login({ loading = false }) {
  const { authError, login } = useAuth();
  const { nome, logoUrl, fundoUrl } = useBrand();

  const handleSubmit = async (email, password, captchaToken) => {
    try {
      await login(email, password, captchaToken);
    } catch (error) {
      throw new Error(error.message || `Não foi possível entrar no ${APP_NAME}.`);
    }
  };

  return (
    <AuthLoginCard
      logoUrl={logoUrl || LOGO_URL}
      backgroundImageUrl={fundoUrl}
      title={`${APP_NAME} · ${nome}`}
      onSubmit={handleSubmit}
      loading={loading}
      error={authError && authError.type !== 'auth_required' ? authError.message : ''}
      subtitle="Acesse sua conta"
      footer="Sem acesso? Solicite a liberação ao administrador."
    />
  );
}

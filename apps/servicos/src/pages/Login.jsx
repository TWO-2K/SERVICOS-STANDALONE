import { AuthLoginCard } from '@/shared/ui';
import { useAuth } from '@/lib/AuthContext';
import { useBrand } from '@/lib/BrandContext';

export default function Login({ loading = false }) {
  const { authError, login } = useAuth();
  const { nome: APP_NAME, logoUrl: LOGO_URL, produto } = useBrand();

  const handleSubmit = async (email, password, captchaToken) => {
    try {
      await login(email, password, captchaToken);
    } catch (error) {
      throw new Error(error.message || `Não foi possível entrar no ${produto}.`);
    }
  };

  return (
    <AuthLoginCard
      logoUrl={LOGO_URL}
      title={produto}
      onSubmit={handleSubmit}
      loading={loading}
      error={authError && authError.type !== 'auth_required' ? authError.message : ''}
      subtitle={`Acesso de ${APP_NAME}`}
      footer="Sem acesso? Solicite a liberação ao administrador."
    />
  );
}

import { AuthLoginCard } from '@/shared/ui';
import { useAuth } from '@/lib/AuthContext';
import { APP_NAME, LOGO_URL } from '@/lib/branding';

// Login generico: sem nome, logo ou cor da empresa. A personalizacao so vale dentro do acesso.
export default function Login({ loading = false }) {
  const { authError, login } = useAuth();

  const handleSubmit = async (email, password, captchaToken) => {
    try {
      await login(email, password, captchaToken);
    } catch (error) {
      throw new Error(error.message || `Não foi possível entrar no ${APP_NAME}.`);
    }
  };

  return (
    <AuthLoginCard
      logoUrl={LOGO_URL}
      title={APP_NAME}
      onSubmit={handleSubmit}
      loading={loading}
      error={authError && authError.type !== 'auth_required' ? authError.message : ''}
      subtitle="Acesse sua conta"
      footer="Sem acesso? Solicite a liberação ao administrador."
    />
  );
}

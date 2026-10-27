import { createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react';

import { adminApi } from '@/shared/api/adminApi';
import {
  assertSupabaseConfigured,
  checkLoginLock,
  getAuthErrorMessage,
  reportFailedLogin,
  reportLoginSuccess,
  supabase,
} from '@/shared/api/supabaseClient';

// Etapas do acesso ao painel: senha -> (cadastro do autenticador, so na 1a vez) -> codigo TOTP -> pronto.
// 'ready' so existe com sessao aal2; o backend (admin-api) confere de novo a cada chamada.
const AuthContext = createContext(null);

const LOCK_SLUG = 'servicos';

export function AuthProvider({ children }) {
  const [status, setStatus] = useState('loading');
  const [me, setMe] = useState(null);
  const [email, setEmail] = useState('');
  const [userId, setUserId] = useState(null);
  const [factorId, setFactorId] = useState(null);
  const [error, setError] = useState('');

  const resolve = useCallback(async () => {
    const { data } = await supabase.auth.getSession();
    const session = data?.session;
    if (!session) {
      setMe(null);
      setStatus('signed_out');
      return;
    }
    setEmail(session.user.email || '');
    setUserId(session.user.id);

    // Quem nao e admin da plataforma nem chega a ver a etapa de MFA.
    let adminMe;
    try {
      adminMe = await adminApi.me();
    } catch (err) {
      await supabase.auth.signOut({ scope: 'local' });
      setError(err.message || 'Nao foi possivel validar o acesso.');
      setStatus('signed_out');
      return;
    }
    if (!adminMe.isPlatformAdmin) {
      await supabase.auth.signOut({ scope: 'local' });
      setError('Este acesso é exclusivo da administração da plataforma.');
      setStatus('signed_out');
      return;
    }

    const { data: aal, error: aalError } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    if (aalError) {
      setError(aalError.message);
      setStatus('signed_out');
      return;
    }
    if (aal.currentLevel === 'aal2') {
      setMe(adminMe);
      setStatus('ready');
      return;
    }
    if (aal.nextLevel === 'aal2') {
      const { data: factors } = await supabase.auth.mfa.listFactors();
      setFactorId(factors?.totp?.[0]?.id || null);
      setStatus('mfa_verify');
      return;
    }
    setStatus('mfa_enroll');
  }, []);

  useEffect(() => {
    resolve().catch(() => setStatus('signed_out'));
    const { data: subscription } = supabase.auth.onAuthStateChange((event) => {
      if (event === 'SIGNED_OUT') {
        setMe(null);
        setStatus('signed_out');
      }
    });
    return () => subscription.subscription.unsubscribe();
  }, [resolve]);

  const login = useCallback(
    async (emailValue, password, captchaToken) => {
      assertSupabaseConfigured();
      setError('');
      const lock = await checkLoginLock(emailValue, LOCK_SLUG);
      if (lock.locked) throw new Error(lock.message);

      const { error: signInError } = await supabase.auth.signInWithPassword({
        email: emailValue,
        password,
        options: captchaToken ? { captchaToken } : undefined,
      });
      if (signInError) {
        reportFailedLogin(emailValue, LOCK_SLUG);
        throw new Error(getAuthErrorMessage(signInError) ?? 'Não foi possível entrar.');
      }
      reportLoginSuccess(LOCK_SLUG);
      await resolve();
    },
    [resolve],
  );

  // Inicia o cadastro do autenticador: descarta tentativas antigas nao concluidas e devolve QR code + chave.
  const startEnroll = useCallback(async () => {
    const { data: factors } = await supabase.auth.mfa.listFactors();
    const pendentes = (factors?.all || []).filter((f) => f.factor_type === 'totp' && f.status === 'unverified');
    for (const factor of pendentes) {
      await supabase.auth.mfa.unenroll({ factorId: factor.id });
    }
    const { data, error: enrollError } = await supabase.auth.mfa.enroll({
      factorType: 'totp',
      friendlyName: `Plataforma ${new Date().toISOString().slice(0, 10)}`,
    });
    if (enrollError) throw new Error(enrollError.message);
    return { factorId: data.id, qrCode: data.totp.qr_code, secret: data.totp.secret };
  }, []);

  const verifyCode = useCallback(
    async (targetFactorId, code) => {
      const { error: verifyError } = await supabase.auth.mfa.challengeAndVerify({
        factorId: targetFactorId,
        code: code.replace(/\s+/g, ''),
      });
      if (verifyError) {
        throw new Error(/invalid|expired/i.test(verifyError.message) ? 'Código inválido ou expirado.' : verifyError.message);
      }
      await resolve();
    },
    [resolve],
  );

  const logout = useCallback(async () => {
    await supabase.auth.signOut({ scope: 'local' });
    setMe(null);
    setStatus('signed_out');
  }, []);

  const value = useMemo(
    () => ({ status, me, email, user: { id: userId }, factorId, error, login, startEnroll, verifyCode, logout }),
    [status, me, email, userId, factorId, error, login, startEnroll, verifyCode, logout],
  );

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth() {
  const context = useContext(AuthContext);
  if (!context) throw new Error('useAuth must be used within an AuthProvider');
  return context;
}

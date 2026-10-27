import { useEffect, useRef, useState } from 'react';

import { Alert, AlertDescription, AuthLoginCard, Button, Card, CardContent, CardDescription, CardHeader, CardTitle, Input, Label } from '@/shared/ui';

import { useAuth } from '@/lib/AuthContext';
import { APP_NAME, LOGO_URL } from '@/lib/branding';

function CodigoForm({ onSubmit, onCancel, submitLabel }) {
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  const handleSubmit = async (event) => {
    event.preventDefault();
    setBusy(true);
    setError('');
    try {
      await onSubmit(code);
    } catch (err) {
      setError(err.message);
      setCode('');
    } finally {
      setBusy(false);
    }
  };

  return (
    <form className="space-y-3" onSubmit={handleSubmit}>
      <div className="space-y-1">
        <Label htmlFor="mfa-code">Código do aplicativo (6 dígitos)</Label>
        <Input
          id="mfa-code"
          inputMode="numeric"
          autoComplete="one-time-code"
          autoFocus
          maxLength={7}
          value={code}
          onChange={(e) => setCode(e.target.value.replace(/[^\d ]/g, ''))}
        />
      </div>
      {error ? (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      ) : null}
      <div className="flex gap-2">
        <Button type="submit" className="flex-1" disabled={busy || code.replace(/\s/g, '').length !== 6}>
          {busy ? 'Verificando...' : submitLabel}
        </Button>
        <Button type="button" variant="outline" onClick={onCancel}>
          Sair
        </Button>
      </div>
    </form>
  );
}

function MfaShell({ title, description, children }) {
  return (
    <div className="flex min-h-screen items-center justify-center bg-slate-100 p-4 dark:bg-slate-950">
      <Card className="w-full max-w-md">
        <CardHeader>
          <CardTitle>{title}</CardTitle>
          <CardDescription>{description}</CardDescription>
        </CardHeader>
        <CardContent>{children}</CardContent>
      </Card>
    </div>
  );
}

function Cadastro() {
  const { startEnroll, verifyCode, logout, email } = useAuth();
  const [enroll, setEnroll] = useState(null);
  const [error, setError] = useState('');
  const started = useRef(false);

  useEffect(() => {
    if (started.current) return;
    started.current = true;
    startEnroll().then(setEnroll).catch((err) => setError(err.message));
  }, [startEnroll]);

  return (
    <MfaShell
      title="Ative a verificação em duas etapas"
      description={`O painel da plataforma exige um aplicativo autenticador (Google Authenticator, Microsoft Authenticator, Authy...). Conta: ${email}.`}
    >
      {error ? (
        <Alert variant="destructive">
          <AlertDescription>{error}</AlertDescription>
        </Alert>
      ) : !enroll ? (
        <p className="text-sm text-muted-foreground">Gerando código...</p>
      ) : (
        <div className="space-y-4">
          <ol className="list-decimal space-y-1 pl-5 text-sm text-muted-foreground">
            <li>Abra o aplicativo autenticador e adicione uma conta lendo o QR code.</li>
            <li>Digite abaixo o código de 6 dígitos que o aplicativo mostrar.</li>
          </ol>
          <div className="flex justify-center rounded-md border bg-white p-3">
            <img src={enroll.qrCode} alt="QR code do autenticador" className="h-44 w-44" />
          </div>
          <div className="text-xs text-muted-foreground">
            Sem câmera? Digite a chave no aplicativo: <code className="select-all break-all font-mono">{enroll.secret}</code>
          </div>
          <CodigoForm submitLabel="Ativar e entrar" onSubmit={(code) => verifyCode(enroll.factorId, code)} onCancel={logout} />
        </div>
      )}
    </MfaShell>
  );
}

function Verificacao() {
  const { factorId, verifyCode, logout, email } = useAuth();
  return (
    <MfaShell title="Verificação em duas etapas" description={`Informe o código do seu aplicativo autenticador. Conta: ${email}.`}>
      <CodigoForm submitLabel="Entrar" onSubmit={(code) => verifyCode(factorId, code)} onCancel={logout} />
    </MfaShell>
  );
}

export default function Entrar() {
  const { status, error, login } = useAuth();

  if (status === 'mfa_enroll') return <Cadastro />;
  if (status === 'mfa_verify') return <Verificacao />;

  return (
    <AuthLoginCard
      logoUrl={LOGO_URL}
      title={`${APP_NAME} · Plataforma`}
      subtitle="Acesso restrito à administração"
      onSubmit={async (email, password, captchaToken) => {
        try {
          await login(email, password, captchaToken);
        } catch (err) {
          throw new Error(err.message || 'Não foi possível entrar.');
        }
      }}
      loading={status === 'loading'}
      error={error}
      footer="Exige verificação em duas etapas."
    />
  );
}

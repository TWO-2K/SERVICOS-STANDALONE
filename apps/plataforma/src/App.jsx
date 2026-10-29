import { useEffect, useState } from 'react';
import { QueryClientProvider } from '@tanstack/react-query';

import {
  Button,
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  Input,
  Label,
  Toaster,
  ThemeToggleButton,
  applyTheme,
  getInitialTheme,
  useToast,
} from '@/shared/ui';
import { KeyRound, LogOut } from 'lucide-react';

import { getAuthErrorMessage, supabase } from '@/shared/api/supabaseClient';

import { queryClientInstance } from '@/lib/query-client';
import { AuthProvider, useAuth } from '@/lib/AuthContext';
import { APP_NAME } from '@/lib/branding';
import Entrar from '@/pages/Entrar';
import Plataforma from '@/pages/Plataforma';

function TrocarSenhaDialog({ open, onClose }) {
  const { toast } = useToast();
  const { logout } = useAuth();
  const [senha, setSenha] = useState('');
  const [confirmar, setConfirmar] = useState('');
  const [salvando, setSalvando] = useState(false);

  useEffect(() => {
    setSenha('');
    setConfirmar('');
  }, [open]);

  const valida = senha.length >= 8 && senha === confirmar;

  const salvar = async () => {
    setSalvando(true);
    // A sessao ja e aal2 (MFA), entao o Supabase aceita a troca sem pedir a senha atual.
    const { error } = await supabase.auth.updateUser({ password: senha });
    setSalvando(false);
    if (error) {
      if (/session missing/i.test(error.message)) {
        toast({ title: 'Sua sessão expirou', description: 'Entre novamente e tente de novo.' });
        await logout();
        return;
      }
      toast({ title: 'Não foi possível trocar a senha', description: getAuthErrorMessage(error) ?? error.message });
      return;
    }
    toast({ title: 'Senha atualizada' });
    onClose();
  };

  return (
    <Dialog open={open} onOpenChange={(aberto) => !aberto && onClose()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Trocar senha</DialogTitle>
          <DialogDescription>Vale para o seu acesso à plataforma. Mínimo de 8 caracteres.</DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <div className="space-y-1">
            <Label htmlFor="nova-senha">Nova senha</Label>
            <Input id="nova-senha" type="password" autoComplete="new-password" value={senha} onChange={(e) => setSenha(e.target.value)} />
          </div>
          <div className="space-y-1">
            <Label htmlFor="confirmar-senha">Confirmar nova senha</Label>
            <Input id="confirmar-senha" type="password" autoComplete="new-password" value={confirmar} onChange={(e) => setConfirmar(e.target.value)} />
            {confirmar && senha !== confirmar ? <p className="text-xs text-destructive">As senhas não conferem.</p> : null}
          </div>
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={onClose}>
            Cancelar
          </Button>
          <Button disabled={!valida || salvando} onClick={salvar}>
            {salvando ? 'Salvando...' : 'Salvar'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function Painel() {
  const { email, logout } = useAuth();
  const [trocandoSenha, setTrocandoSenha] = useState(false);
  const [theme, setTheme] = useState(() => {
    const initial = getInitialTheme();
    applyTheme(initial);
    return initial;
  });

  const alternarTema = () => {
    const next = theme === 'dark' ? 'light' : 'dark';
    applyTheme(next);
    setTheme(next);
  };

  return (
    <div className="min-h-screen bg-background text-foreground">
      <header className="border-b">
        <div className="mx-auto flex max-w-6xl items-center justify-between gap-3 px-4 py-3">
          <div className="font-semibold">{APP_NAME} · Plataforma</div>
          <div className="flex items-center gap-2">
            <span className="hidden text-sm text-muted-foreground sm:inline">{email}</span>
            <div className="w-28">
              <ThemeToggleButton theme={theme} onToggle={alternarTema} collapsed />
            </div>
            <Button variant="outline" onClick={() => setTrocandoSenha(true)} className="gap-2">
              <KeyRound className="h-4 w-4" />
              Trocar senha
            </Button>
            <Button variant="outline" onClick={logout} className="gap-2">
              <LogOut className="h-4 w-4" />
              Sair
            </Button>
          </div>
        </div>
      </header>
      <main className="mx-auto max-w-6xl p-4">
        <Plataforma />
      </main>
      <TrocarSenhaDialog open={trocandoSenha} onClose={() => setTrocandoSenha(false)} />

    </div>
  );
}

function Rotas() {
  const { status } = useAuth();
  return status === 'ready' ? <Painel /> : <Entrar />;
}

export default function App() {
  return (
    <QueryClientProvider client={queryClientInstance}>
      <AuthProvider>
        <Rotas />
        <Toaster />
      </AuthProvider>
    </QueryClientProvider>
  );
}

import { useState } from 'react';
import { QueryClientProvider } from '@tanstack/react-query';

import { Button, Toaster, ThemeToggleButton, applyTheme, getInitialTheme } from '@/shared/ui';
import { LogOut } from 'lucide-react';

import { queryClientInstance } from '@/lib/query-client';
import { AuthProvider, useAuth } from '@/lib/AuthContext';
import { APP_NAME } from '@/lib/branding';
import Entrar from '@/pages/Entrar';
import Plataforma from '@/pages/Plataforma';

function Painel() {
  const { email, logout } = useAuth();
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

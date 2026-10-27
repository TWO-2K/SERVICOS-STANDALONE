import { useState } from 'react';

import { Alert, AlertDescription, Button, Card, CardContent, CardDescription, CardHeader, CardTitle, Input, Label } from '@/shared/ui';
import { isValidSlug } from '@/lib/tenant';
import { APP_NAME, LOGO_URL } from '@/lib/branding';

// Sem empresa no endereco (ou empresa inexistente): pede o identificador e abre /<identificador>.
export default function EscolherEmpresa({ erro = '' }) {
  const [slug, setSlug] = useState('');
  const valido = isValidSlug(slug.trim().toLowerCase());

  const handleSubmit = (event) => {
    event.preventDefault();
    if (valido) window.location.assign(`/${slug.trim().toLowerCase()}`);
  };

  return (
    <div className="flex min-h-screen items-center justify-center bg-slate-100 p-4 dark:bg-slate-950">
      <Card className="w-full max-w-sm">
        <CardHeader className="items-center text-center">
          <img src={LOGO_URL} alt={APP_NAME} className="h-12 w-12 object-contain" />
          <CardTitle>{APP_NAME}</CardTitle>
          <CardDescription>Informe o identificador da sua empresa para entrar.</CardDescription>
        </CardHeader>
        <CardContent>
          <form className="space-y-3" onSubmit={handleSubmit}>
            {erro ? (
              <Alert variant="destructive">
                <AlertDescription>{erro}</AlertDescription>
              </Alert>
            ) : null}
            <div className="space-y-1">
              <Label htmlFor="empresa-slug">Identificador da empresa</Label>
              <Input id="empresa-slug" placeholder="ex.: minha-empresa" autoFocus value={slug} onChange={(e) => setSlug(e.target.value)} />
            </div>
            <Button type="submit" className="w-full" disabled={!valido}>
              Continuar
            </Button>
          </form>
        </CardContent>
      </Card>
    </div>
  );
}

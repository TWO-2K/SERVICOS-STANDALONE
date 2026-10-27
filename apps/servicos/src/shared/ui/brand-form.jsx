import { useRef, useState } from 'react';

import { Button } from './button';
import { Input } from './input';
import { Label } from './label';

const LOGO_TIPOS = ['image/png', 'image/jpeg', 'image/webp'];
const LOGO_MAX_BYTES = 400 * 1024;
const COR_RE = /^#[0-9a-fA-F]{6}$/;

function lerComoDataUrl(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(new Error('Nao foi possivel ler o arquivo.'));
    reader.readAsDataURL(file);
  });
}

// Formulario de identidade visual (nome da empresa, cor principal e logo) de um cliente. Quem usa decide o que fazer com
// o resultado: onSave recebe { marca_nome, marca_cor, logo_data_url?, remover_logo? } e devolve uma Promise.
export function BrandForm({ marca, onSave, saveLabel = 'Salvar identidade' }) {
  const [nome, setNome] = useState(marca?.nome || '');
  const [cor, setCor] = useState(marca?.cor || '');
  const [logoDataUrl, setLogoDataUrl] = useState(null);
  const [removerLogo, setRemoverLogo] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const fileRef = useRef(null);

  const corValida = !cor || COR_RE.test(cor);
  const logoAtual = removerLogo ? null : logoDataUrl || marca?.logo_url || null;

  const escolherArquivo = async (event) => {
    const file = event.target.files?.[0];
    event.target.value = '';
    if (!file) return;
    if (!LOGO_TIPOS.includes(file.type)) return setError('Use uma imagem PNG, JPG ou WebP.');
    if (file.size > LOGO_MAX_BYTES) return setError('A imagem passa de 400 KB. Reduza o tamanho e tente de novo.');
    setError('');
    setLogoDataUrl(await lerComoDataUrl(file));
    setRemoverLogo(false);
  };

  const salvar = async () => {
    setSaving(true);
    setError('');
    try {
      const payload = { marca_nome: nome.trim(), marca_cor: cor.trim() };
      if (logoDataUrl) payload.logo_data_url = logoDataUrl;
      else if (removerLogo) payload.remover_logo = true;
      await onSave(payload);
      setLogoDataUrl(null);
      setRemoverLogo(false);
    } catch (err) {
      setError(err.message || 'Nao foi possivel salvar.');
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="space-y-4">
      <div className="space-y-1">
        <Label htmlFor="marca-nome">Nome da empresa</Label>
        <Input
          id="marca-nome"
          maxLength={60}
          value={nome}
          placeholder={marca?.nome_cliente || 'Nome da empresa'}
          onChange={(e) => setNome(e.target.value)}
        />
        <p className="text-xs text-muted-foreground">Aparece na tela de login. Em branco, usa o nome do cliente.</p>
      </div>

      <div className="space-y-1">
        <Label htmlFor="marca-cor-hex">Cor principal</Label>
        <div className="flex items-center gap-2">
          <input
            type="color"
            aria-label="Escolher cor"
            className="h-9 w-12 cursor-pointer rounded-md border border-input bg-transparent p-1"
            value={COR_RE.test(cor) ? cor : '#e30613'}
            onChange={(e) => setCor(e.target.value)}
          />
          <Input id="marca-cor-hex" className="w-32 font-mono" placeholder="#RRGGBB" value={cor} onChange={(e) => setCor(e.target.value)} />
          {cor ? (
            <Button type="button" variant="outline" size="sm" onClick={() => setCor('')}>
              Usar padrão
            </Button>
          ) : null}
        </div>
        {!corValida ? <p className="text-xs text-destructive">Use o formato #RRGGBB, por exemplo #0a7cff.</p> : null}
      </div>

      <div className="space-y-2">
        <Label>Logo</Label>
        <div className="flex items-center gap-3">
          <div className="flex h-16 w-16 items-center justify-center rounded-md border bg-muted">
            {logoAtual ? (
              <img src={logoAtual} alt="Logo" className="h-full w-full object-contain p-1" />
            ) : (
              <span className="text-xs text-muted-foreground">Padrão</span>
            )}
          </div>
          <div className="flex flex-wrap gap-2">
            <Button type="button" variant="outline" size="sm" onClick={() => fileRef.current?.click()}>
              Enviar logo
            </Button>
            {logoAtual ? (
              <Button
                type="button"
                variant="outline"
                size="sm"
                onClick={() => {
                  setLogoDataUrl(null);
                  setRemoverLogo(true);
                }}
              >
                Remover
              </Button>
            ) : null}
          </div>
          <input ref={fileRef} type="file" accept={LOGO_TIPOS.join(',')} className="hidden" onChange={escolherArquivo} />
        </div>
        <p className="text-xs text-muted-foreground">PNG, JPG ou WebP, até 400 KB. Quadrado funciona melhor.</p>
      </div>

      {error ? <p className="text-sm text-destructive">{error}</p> : null}
      <Button type="button" disabled={saving || !corValida} onClick={salvar}>
        {saving ? 'Salvando...' : saveLabel}
      </Button>
    </div>
  );
}

// Em desenvolvimento local as functions rodam no Docker e enxergam o Storage pelo host interno (http://kong:8000),
// que o navegador nao resolve. `PUBLIC_SUPABASE_URL` troca a origem das URLs assinadas pela publica; sem a
// variavel (producao, onde SUPABASE_URL ja e publico) a URL passa intacta.
export function toPublicStorageUrl(signedUrl: string | null | undefined): string | null {
  if (!signedUrl) return null;
  const publicBase = Deno.env.get('PUBLIC_SUPABASE_URL');
  if (!publicBase) return signedUrl;
  try {
    const target = new URL(signedUrl);
    const base = new URL(publicBase);
    target.protocol = base.protocol;
    target.host = base.host;
    return target.toString();
  } catch {
    return signedUrl;
  }
}

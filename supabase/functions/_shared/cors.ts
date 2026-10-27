// Origens permitidas: as de desenvolvimento local (vite dev e vite preview) mais as de producao, informadas em
// ALLOWED_ORIGINS (lista separada por virgula, ex.: "https://app.exemplo.com,https://outro.exemplo.com").
const LOCAL_ORIGINS = [5170, 5171, 5172, 5174, 5175, 5176, 5177, 4170, 4171, 4172, 4174, 4175, 4176, 4177].map(
  (port) => `http://localhost:${port}`,
);

const ALLOWED_ORIGINS = new Set([
  ...LOCAL_ORIGINS,
  ...(Deno.env.get('ALLOWED_ORIGINS') || '')
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean),
]);

export function buildCorsHeaders(request: Request): Record<string, string> {
  const origin = request.headers.get('origin');
  const headers: Record<string, string> = {
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    Vary: 'Origin',
  };

  if (origin && ALLOWED_ORIGINS.has(origin)) {
    headers['Access-Control-Allow-Origin'] = origin;
  }

  return headers;
}

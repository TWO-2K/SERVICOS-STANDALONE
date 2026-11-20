// Marca publica de um cliente (nome, cor e logo), buscada pelo slug antes do login. Devolve so o que a tela de login
// precisa; clientes desativados ou inexistentes dao 404 (o app mostra "empresa nao encontrada").
import postgres from 'https://deno.land/x/postgresjs@v3.4.5/mod.js';
import { buildCorsHeaders } from '../_shared/cors.ts';

const SLUG_RE = /^[a-z0-9](?:[a-z0-9-]{1,38})[a-z0-9]$/;
const databaseUrl = Deno.env.get('DATABASE_URL');
const sql = databaseUrl ? postgres(databaseUrl, { prepare: false, max: 2, idle_timeout: 5, connect_timeout: 15 }) : null;

function logoUrl(path: string | null) {
  if (!path) return null;
  const base = (Deno.env.get('PUBLIC_SUPABASE_URL') || Deno.env.get('SUPABASE_URL') || '').replace(/\/$/, '');
  return `${base}/storage/v1/object/public/marcas/${path}`;
}

Deno.serve(async (request) => {
  const corsHeaders = buildCorsHeaders(request);
  const json = (data: unknown, status = 200) =>
    new Response(JSON.stringify(data), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    if (!sql) return json({ error: 'DATABASE_URL nao configurada.' }, 500);
    const body = await request.json().catch(() => ({}));
    const slug = String(body.slug || '').trim().toLowerCase();
    if (!SLUG_RE.test(slug)) return json({ error: 'Empresa nao encontrada.' }, 404);

    const rows = await sql.unsafe(
      `select slug, coalesce(marca_nome, nome) as nome, marca_cor as cor, marca_logo_path, marca_fundo_path
       from public.tenants where slug = $1 and ativo limit 1;`,
      [slug],
    );
    const row = rows[0];
    if (!row) return json({ error: 'Empresa nao encontrada.' }, 404);
    return json({
      slug: row.slug,
      nome: row.nome,
      cor: row.cor,
      logo_url: logoUrl(row.marca_logo_path as string | null),
      fundo_url: logoUrl(row.marca_fundo_path as string | null),
    });
  } catch (error) {
    console.error('marca-publica:', error);
    return json({ error: 'Falha ao consultar a empresa.' }, 500);
  }
});

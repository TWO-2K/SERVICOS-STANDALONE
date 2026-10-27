// Worker da fila `notificacoes.fila_emails` (chamado por cron/net.http_post com x-invoke-secret, sem JWT
// de usuario). Cada e-mail e enviado com as credenciais Gmail do tenant dono da linha; tenant sem
// integracao ativa gera erro na linha e nunca usa a conta de outro cliente.
import { buildCorsHeaders } from '../_shared/cors.ts';
import { sendGmail } from '../_shared/email.ts';
import postgres from 'https://deno.land/x/postgresjs@v3.4.5/mod.js';

const LOTE = 20;

function getErrorMessage(error: unknown) {
  if (error instanceof Error) return error.message;
  try {
    return JSON.stringify(error);
  } catch {
    return 'Erro inesperado';
  }
}

Deno.serve(async (request) => {
  const corsHeaders = buildCorsHeaders(request);
  const json = (data: unknown, status = 200) =>
    new Response(JSON.stringify(data), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } });

  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  const secret = Deno.env.get('INTERNAL_INVOKE_SECRET');
  if (!secret || request.headers.get('x-invoke-secret') !== secret) {
    return json({ success: false, error: 'Nao autorizado.' }, 401);
  }

  const databaseUrl = Deno.env.get('DATABASE_URL');
  if (!databaseUrl) return json({ success: false, error: 'DATABASE_URL nao configurada.' }, 500);

  const sql = postgres(databaseUrl, { prepare: false, max: 2, idle_timeout: 5, connect_timeout: 15 });

  try {
    // Reserva o lote (SKIP LOCKED evita duas execucoes enviando o mesmo e-mail) e ignora tenants inativos.
    const itens = await sql.begin(async (tx) => {
      const rows = await tx.unsafe(
        `select f.id, f.tenant_id, f.payload, f.tentativas, f.max_tentativas
         from notificacoes.fila_emails f
         join public.tenants t on t.id = f.tenant_id and t.ativo
         where f.status = 'pendente' and f.agendado_em <= now() and f.tentativas < f.max_tentativas
         order by f.agendado_em
         limit ${LOTE}
         for update of f skip locked;`,
      );
      if (rows.length) {
        await tx.unsafe(
          `update notificacoes.fila_emails set status = 'processando', processado_em = now(), atualizado_em = now()
           where id = any($1::uuid[]);`,
          [rows.map((r) => String(r.id))],
        );
      }
      return rows;
    });

    let enviados = 0;
    let falhas = 0;

    for (const item of itens) {
      const tentativas = Number(item.tentativas) + 1;
      try {
        const payload = typeof item.payload === 'string' ? JSON.parse(item.payload) : item.payload;
        await sendGmail(payload as Record<string, unknown>, { sql, tenantId: String(item.tenant_id) });
        await sql.unsafe(
          `update notificacoes.fila_emails
           set status = 'enviado', tentativas = $2, enviado_em = now(), erro = null, atualizado_em = now()
           where id = $1;`,
          [String(item.id), tentativas],
        );
        enviados += 1;
      } catch (error) {
        const esgotou = tentativas >= Number(item.max_tentativas);
        await sql.unsafe(
          `update notificacoes.fila_emails
           set status = $2, tentativas = $3, erro = $4,
               agendado_em = now() + make_interval(mins => 5 * $3::int), atualizado_em = now()
           where id = $1;`,
          [String(item.id), esgotou ? 'erro' : 'pendente', tentativas, getErrorMessage(error).slice(0, 1000)],
        );
        falhas += 1;
      }
    }

    return json({ success: true, processados: itens.length, enviados, falhas });
  } catch (error) {
    return json({ success: false, error: getErrorMessage(error) }, 500);
  } finally {
    await sql.end({ timeout: 2 });
  }
});

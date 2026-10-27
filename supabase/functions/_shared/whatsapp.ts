// WhatsApp por cliente (tenant) -- so a estrutura. Ainda nao ha provedor registrado: nada envia mensagem.
//
// Como ligar um provedor depois:
//  1. implementar `WhatsappProvider` e chamar `registerWhatsappProvider` (um arquivo por provedor);
//  2. gravar a configuracao do cliente em integracoes.integracoes (chave `whatsapp`, segredos no Vault, igual ao Gmail
//     em admin-api) e ler com integracoes.get_credenciais('whatsapp', tenant_id);
//  3. criar o worker (modelo: processa-fila-email) sobre notificacoes.fila_whatsapp, agendado como em
//     supabase/migrations/20260101001200_cron_workers.sql.
// Quem gera mensagens usa so `enqueueWhatsapp`, que respeita o tenant da requisicao (RLS).

export const WHATSAPP_INTEGRACAO_CHAVE = 'whatsapp';

export interface WhatsappProvider {
  name: string;
  /** Envia um texto; credenciais vem do cadastro do cliente. Deve lancar erro se o envio falhar. */
  send(credentials: Record<string, unknown>, to: string, text: string): Promise<void>;
}

const providers = new Map<string, WhatsappProvider>();

export function registerWhatsappProvider(provider: WhatsappProvider) {
  providers.set(provider.name, provider);
}

export function getWhatsappProvider(name: string | null | undefined): WhatsappProvider | null {
  return name ? providers.get(name) ?? null : null;
}

export function listWhatsappProviders() {
  return [...providers.keys()];
}

/** Telefone brasileiro so com digitos e DDI 55 (ex.: "(11) 98888-7777" -> "5511988887777"); null se invalido. */
export function normalizePhoneBR(value: unknown): string | null {
  const digits = String(value ?? '').replace(/\D/g, '');
  const national = digits.startsWith('55') && digits.length >= 12 ? digits.slice(2) : digits;
  if (national.length !== 10 && national.length !== 11) return null;
  return `55${national}`;
}

type SqlUnsafe = { unsafe: (query: string, values?: unknown[]) => Promise<unknown> };

export async function enqueueWhatsapp(
  sql: SqlUnsafe,
  input: { tipo: string; destinatario: string; texto: string; agendadoEm?: Date; maxTentativas?: number },
): Promise<boolean> {
  const to = normalizePhoneBR(input.destinatario);
  if (!to) return false;
  await sql.unsafe(
    `insert into notificacoes.fila_whatsapp (tipo, destinatario, payload, agendado_em, max_tentativas)
     values ($1, $2, $3::text::jsonb, coalesce($4::timestamptz, now()), coalesce($5, 5));`,
    [input.tipo, to, JSON.stringify({ to, text: input.texto }), input.agendadoEm ?? null, input.maxTentativas ?? null],
  );
  return true;
}

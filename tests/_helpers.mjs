// Helpers compartilhados pelos testes de integracao (stack local: Supabase + functions:serve no ar).
// Variaveis opcionais: SUPABASE_URL, SUPABASE_ANON_KEY, PLATFORM_ADMIN_EMAIL, PLATFORM_ADMIN_PASSWORD, DB_CONTAINER.

import assert from 'node:assert/strict';
import { execFileSync, execSync } from 'node:child_process';
import { createHmac } from 'node:crypto';

export const URL_BASE = process.env.SUPABASE_URL || 'http://127.0.0.1:55321';
export const PLATFORM_EMAIL = process.env.PLATFORM_ADMIN_EMAIL || 'admin@servicos.local';
export const PLATFORM_PASSWORD = process.env.PLATFORM_ADMIN_PASSWORD || 'Servicos@123';

export function anonKey() {
  if (process.env.SUPABASE_ANON_KEY) return process.env.SUPABASE_ANON_KEY;
  const out = execSync('npx supabase status -o env', { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
  const match = out.match(/^ANON_KEY="?([^"\r\n]+)"?/m);
  if (!match) throw new Error('ANON_KEY nao encontrada: defina SUPABASE_ANON_KEY.');
  return match[1];
}

export const ANON = anonKey();

export async function login(email, password) {
  const response = await fetch(`${URL_BASE}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: ANON, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password }),
  });
  const data = await response.json();
  assert.ok(data.access_token, `login falhou para ${email}: ${JSON.stringify(data)}`);
  return data.access_token;
}

// TOTP (RFC 6238) para o MFA do admin da plataforma: SHA-1, 6 digitos, passo de 30 s.
function base32Decode(texto) {
  const alfabeto = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let bits = '';
  for (const c of texto.replace(/=+$/, '').toUpperCase()) bits += alfabeto.indexOf(c).toString(2).padStart(5, '0');
  const bytes = [];
  for (let i = 0; i + 8 <= bits.length; i += 8) bytes.push(parseInt(bits.slice(i, i + 8), 2));
  return Buffer.from(bytes);
}

export function totp(secret, agora = Date.now()) {
  const contador = Buffer.alloc(8);
  contador.writeBigUInt64BE(BigInt(Math.floor(agora / 30000)));
  const h = createHmac('sha1', base32Decode(secret)).update(contador).digest();
  const o = h[h.length - 1] & 0xf;
  const n = ((h[o] & 0x7f) << 24) | (h[o + 1] << 16) | (h[o + 2] << 8) | h[o + 3];
  return String(n % 1000000).padStart(6, '0');
}

// Login do admin da plataforma ja no nivel aal2: apaga os fatores antigos, cadastra um autenticador novo e verifica.
// As acoes de plataforma do admin-api recusam sessao aal1 (so senha).
export async function loginPlataforma() {
  psql(`delete from auth.mfa_factors where user_id = (select id from auth.users where email = '${PLATFORM_EMAIL}');`);
  const token = await login(PLATFORM_EMAIL, PLATFORM_PASSWORD);
  const headers = { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  const enroll = await (await fetch(`${URL_BASE}/auth/v1/factors`, {
    method: 'POST', headers, body: JSON.stringify({ factor_type: 'totp', friendly_name: `teste-${Date.now()}` }),
  })).json();
  assert.ok(enroll.id, `enroll MFA falhou: ${JSON.stringify(enroll)}`);
  const challenge = await (await fetch(`${URL_BASE}/auth/v1/factors/${enroll.id}/challenge`, { method: 'POST', headers, body: '{}' })).json();
  assert.ok(challenge.id, `challenge MFA falhou: ${JSON.stringify(challenge)}`);
  const verify = await (await fetch(`${URL_BASE}/auth/v1/factors/${enroll.id}/verify`, {
    method: 'POST', headers, body: JSON.stringify({ challenge_id: challenge.id, code: totp(enroll.totp.secret) }),
  })).json();
  assert.ok(verify.access_token, `verify MFA falhou: ${JSON.stringify(verify)}`);
  return { aal1: token, aal2: verify.access_token };
}

// Insere direto no banco o que nao tem rota simples na API (precisa do container do Postgres local).
const DB_CONTAINER = process.env.DB_CONTAINER || 'supabase_db_servicos';
export function psql(sqlText) {
  return execFileSync('docker', ['exec', '-i', DB_CONTAINER, 'psql', '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-At', '-c', sqlText], {
    encoding: 'utf8',
  }).trim();
}

export async function storage(token, metodo, caminho, corpo, contentType = 'text/plain') {
  const response = await fetch(`${URL_BASE}/storage/v1/object/${caminho}`, {
    method: metodo,
    headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': contentType },
    body: corpo,
  });
  return response.status;
}

export function api(fn, token) {
  return async (body) => {
    const response = await fetch(`${URL_BASE}/functions/v1/${fn}`, {
      method: 'POST',
      headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data = await response.json().catch(() => ({}));
    return { status: response.status, data };
  };
}

export const sufixo = Math.random().toString(36).slice(2, 8);

export async function criarCliente(platform, rotulo) {
  const slug = `teste-${rotulo}-${sufixo}`;
  const { status, data } = await platform({
    action: 'tenant_criar',
    nome: `Teste ${rotulo} ${sufixo}`,
    slug,
    admin_nome: `Admin ${rotulo}`,
    admin_email: `admin-${rotulo}-${sufixo}@teste.local`,
  });
  assert.equal(status, 200, JSON.stringify(data));
  const token = await login(data.admin.email, data.admin.senha_temporaria);
  return {
    id: data.tenant.id,
    token,
    colaboradorId: data.admin.id,
    email: data.admin.email,
    admin: api('admin-api', token),
    servicos: api('servicos-api', token),
  };
}

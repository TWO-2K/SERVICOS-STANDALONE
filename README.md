# K-Pit — plataforma multiempresa (Financeiro + Oficina)

Aplicacao independente (Financeiro + Oficina), multiempresa. Roda 100% local (front + Supabase em Docker).

## Rodar local
Pre-requisitos: Node 20+ e Docker Desktop aberto.

```bash
npm install
npx supabase start                      # banco, auth, storage (portas 55xxx); aplica migrations + seed
npm run functions:serve                 # Edge Functions (deixar rodando num terminal)
npm run dev                             # app dos clientes em http://localhost:5177/<slug-do-cliente> (ex.: /padrao)
npm run dev:plataforma                  # painel da plataforma em http://localhost:5178 (so admin da plataforma, com MFA)
```
Login de teste: `admin@servicos.local` / `Servicos@123` (acesso admin ao Servicos).
Studio (banco): http://127.0.0.1:55323 · e-mails de teste: http://127.0.0.1:55324
Recriar o banco do zero: `npx supabase db reset`. Parar: `npx supabase stop`.

## Estrutura
- `apps/plataforma` — painel do dono do sistema (clientes, catálogos, administradores, auditoria): app próprio, pensado para subdomínio próprio. Login com senha + MFA (TOTP); reaproveita `apps/servicos/src/shared`.
- `apps/servicos` — front dos clientes (React + Vite). Componentes base em `src/shared/ui`, clientes de API em `src/shared/api`, mais `shared/pdf-signature`, `shared/push` e `shared/validation`; import por `@/shared/...`.
- `supabase/functions` — `servicos-api`, `servicos-oficina-api`, `servicos-lembrete-aprovacoes`, `push-api`, `security-check-login-lock`, `security-log-failed-login`, `security-log-login-success`, `_shared`.
- `supabase/migrations` — baseline (dump schema-only do banco remoto, 2026-10-26) + Storage + fix do hook de login.
  Contem schemas de outros sistemas porque o dump e do banco inteiro; e so referencia, nao e usado.
- `supabase/seed.sql` — sistema `servicos`, empresa/unidade/departamento demo, usuario admin, config padrao do Financeiro.

## Sanitizacao e limites
- 13 migrations de cron (URL de producao, anon key e `x-invoke-secret` embutidos) viraram stubs; nao ha jobs de
  cron nesta copia (ex.: lembrete de aprovacoes nao dispara sozinho).
- Sem e-mail (Gmail), WhatsApp ou Web Push: faltam as credenciais, que nao foram copiadas.
- O dump nao traz dados: nao ha solicitacoes/fornecedores/categorias; cadastre pela tela.
- Multiempresa: veja `docs/PENDENCIAS.md` e a secao Multi-tenant em `apps/servicos/CLAUDE.md`.

## Pendencias
O que falta para uso real/entrega (usuarios, cron, e-mail, enxugar banco, producao, venda) e como fazer: `docs/PENDENCIAS.md`.

# Deploy no Vercel

Dois projetos Vercel a partir do mesmo repositorio. O `vercel.json` de cada app ja faz o rewrite de SPA.

| Projeto | Root Directory | Porta local | Uso |
|---|---|---|---|
| K-Pit (clientes) | `apps/servicos` | 5177 | App dos clientes, acessado por `/<slug>` |
| K-Pit Plataforma | `apps/plataforma` | 5178 | Painel do super-admin |

Em cada projeto: Framework Preset = Vite, Build Command = `npm run build` (raiz), Output Directory = `dist` do app.
Se o Root Directory for a pasta do app, habilite "Include source files outside of the Root Directory" para o workspace da raiz.

## Variaveis de ambiente (valores no painel do Vercel, nunca no Git)

| Variavel | Projeto | Descricao |
|---|---|---|
| `VITE_SUPABASE_URL` | ambos | URL do projeto Supabase |
| `VITE_SUPABASE_ANON_KEY` | ambos | Chave anon (publica) |
| `VITE_APP_NAME` | clientes | Nome do produto (padrao `K-Pit`) |
| `VITE_APP_URL` | clientes | URL publica do app |
| `VITE_LOGO_URL` | clientes | Logo padrao (opcional) |
| `VITE_TURNSTILE_SITE_KEY` | clientes | Site key do captcha (opcional) |

Segredos das Edge Functions (`DATABASE_URL`, `INTERNAL_INVOKE_SECRET`, `CHECKLIST_SHARE_SECRET`) ficam no Supabase (`supabase secrets set`), nao no Vercel.

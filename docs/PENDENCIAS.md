# Pendências da cópia standalone do Serviços

Estado em 2026-10-26: o projeto **roda local** (front + Supabase em Docker + Edge Functions), com login, `servicos-api` e
`servicos-oficina-api` funcionando. Nada abaixo é necessário para rodar/testar. São o que falta para **uso real por outras
pessoas** ou **entrega a um comprador**.

Ordem sugerida: 1 → 2 → (3 e 4 se quiser notificações) → 5 → 6 → 7.

---

## 1. Tela/API de gestão de usuários e de clientes — PARCIAL (feito em 2026-10-26)

**Feito (Edge Function `admin-api`, migration `20260101000400_plataforma_admin.sql`):**
- [x] Admin do cliente (tenant): aba **Configurações > Usuários** (`pages/Usuarios.jsx`): listar, criar (senha temporária
  mostrada uma vez), mudar nível de acesso e status (inativo bloqueia o login no Auth) e redefinir senha. Os papéis por
  módulo continuam na aba Permissões.
- [x] Admin da plataforma (`plataforma.administradores`): painel da **Plataforma** (app `apps/plataforma`, :5178): listar,
  criar cliente (cria tenant, empresa inicial, configuração do módulo e o administrador) e ativar/desativar. Cliente
  desativado enxerga e grava zero dados (`current_tenant_id()` devolve null).
- [x] Seed: `admin@servicos.local` é admin da plataforma. Testado no navegador e por chamadas diretas.

**Falta:**
- [x] Cadastros auxiliares: aba **Configurações > Cadastros** (empresas, unidades, departamentos e cargos: criar, editar, excluir; excluir bloqueia se estiver em uso).
- [x] Edição de nome, empresa, unidade e departamento do usuário na aba Usuários.
- [x] Cliente desativado: o login mostra "O acesso da sua empresa está desativado…" (servicos-api e servicos-oficina-api respondem 403). Testado na API e no navegador.
- [ ] E-mail de boas-vindas (o acesso por e-mail já cobre criação de usuário e redefinição de senha).
- [x] Auditoria (migration 20260101000900, `plataforma.auditoria`): `admin-api` registra criar/atualizar cliente, administradores da plataforma, criar/editar/resetar senha de usuário, cadastros e integração de e-mail (sem senhas/segredos). Aba **Plataforma → Auditoria**.
- [x] Aba **Plataforma → Administradores**: adicionar (por e-mail de usuário existente) e remover admins da plataforma; não remove a si mesmo nem o último.
- [x] Plataforma → Clientes: editar nome/plano e redefinir a senha de um administrador do cliente (senha temporária exibida uma vez; vai para a auditoria sem a senha).
- [x] Acesso por e-mail: criar usuário e redefinir senha (do cliente e da plataforma) enfileiram o e-mail com a senha temporária quando o cliente tem o Gmail ativo; a senha deixa de aparecer na tela. Sem Gmail ativo continua aparecendo uma vez (é o caso de um cliente recém-criado, que ainda não configurou o e-mail). Defina `APP_URL` nas functions para o e-mail trazer o endereço do app.
- [x] Painel da plataforma em app próprio (`apps/plataforma`, local em :5178; em produção, subdomínio próprio): saiu do app dos clientes (sem rota nem menu lá). Login senha + **MFA TOTP** (Supabase Auth, `[auth.mfa.totp]` ligado no config.toml): na 1ª vez o admin cadastra o autenticador (QR code), depois informa o código. O `admin-api` recusa ação de plataforma com sessão só de senha (`403 mfa_required`, claim `aal` do JWT) — vale mesmo chamando a API direto. `PLATAFORMA_EXIGE_MFA=false` nas functions desliga (só dev descartável). Teste: `npm test` (23 casos; o helper `loginPlataforma` cadastra um TOTP de teste).
  - **Perdeu o celular?** Não há autoatendimento ainda: outro admin da plataforma não consegue resetar; é preciso apagar o fator no banco (`delete from auth.mfa_factors where user_id = ...`) — guarde isso para o runbook de produção.
  - Para publicar: servir `apps/plataforma/dist` no subdomínio (ex.: admin.seudominio.com), com as mesmas `VITE_SUPABASE_*`; restringir por IP/VPN no host é opcional. Em produção habilite MFA TOTP também no Auth hospedado.
- [x] Identidade visual por cliente (nome, cor principal e logo): o app dos clientes abre por `/<slug>` (ex.: `/padrao`); a tela de login busca a marca pela function pública `marca-publica` (404 se o cliente não existe/está desativado). Na marca: nome do cliente no lugar de "Servicos" e o nome do produto ("Servicos") como subtítulo. O admin do cliente edita em **Configurações → Identidade**; a plataforma edita a de qualquer cliente no diálogo de edição do painel (mostra também o endereço de acesso). Logo PNG/JPG/WebP até 400 KB no bucket público `marcas` (escrita só pelo `admin-api`). O slug só escolhe a marca: o cliente do usuário vem da conta, e `me` devolve `tenant_slug` (conta de outra empresa é deslogada com aviso). Links antigos sem slug e a raiz `/` vão para a última empresa acessada no navegador; links de WhatsApp, e-mail de acesso e push já saem com o slug. Em produção, defina `VITE_APP_URL` no painel da plataforma (endereço do app dos clientes) e `APP_URL` nas functions. Migração futura para subdomínio por cliente: só trocar a origem do slug em `apps/servicos/src/lib/tenant.js`. Testes: `npm test` (24 casos).
- [ ] Cobrança/limites por plano.
- [x] `verify_jwt`: `supabase/config.toml` desliga só nos dois workers (`processa-fila-email`, `servicos-lembrete-aprovacoes`, que se autenticam por `x-invoke-secret`); as demais ficam com JWT. O `functions:serve` local usa `--no-verify-jwt`. Se o projeto de produção usar as chaves novas (`sb_publishable`, que não são JWT), as functions chamadas pelo navegador também precisam de `verify_jwt = false`, pois já validam o token por conta própria.

**Plano original (referência):**
- Nova Edge Function `usuarios-api` em `supabase/functions/`, usando a service role (`auth.admin`), com actions:
  `list`, `create`, `update`, `reset_password`, `set_access`. Só para quem tem `nivel_acesso = 'admin'` em
  `public.acessos_usuario_sistema` (reaproveitar `getAuthenticatedUser` e `getServicosAccess` de `_shared/servicos-auth.ts`).
- `create`: `auth.admin.createUser` (e-mail + senha temporária) → insert em `public.colaboradores` (mesmo `id` do auth) com
  `precisa_trocar_senha = true` → insert em `public.acessos_usuario_sistema` (sistema `servicos`). O trigger
  `auto_create_servicos_permissoes` já cria `permissoes_modulo` com papel `nenhum` para `financeiro` e `oficina`; a action
  `set_access` depois ajusta o papel (`usuario`, `aprovador`, `financeiro`, `contas_a_pagar`, `inspetor`, `gestor`).
- `reset_password`: `auth.admin.updateUserById` + `precisa_trocar_senha = true`. O front já tem o fluxo de troca obrigatória
  (`mustChangePassword` / `PasswordChangeForm`).
- Front: página "Usuários" em `apps/servicos/src/pages/`, com lista, criar, editar papéis por módulo e reset de senha.
  Cadastros auxiliares (empresas, unidades, departamentos, cargos) podem entrar na mesma tela ou em abas.
- Referência de comportamento: `plataforma-api` no repositório original (não copiar às cegas: ela serve a todos os sistemas).

**Esforço:** médio (1 function + 1 página). **Risco:** baixo, é aditivo.

## 2. Enxugar o banco (schemas e tabelas de outros sistemas) — PARCIAL (opção A feita em 2026-10-26)

**Feito:**
- [x] Levantamento de dependências (funções, triggers, FKs, queries das Edge Functions).
- [x] Removidos os schemas `gestao_ativos`, `gestao_comunicacao`, `gestao_intranet`, `gestao_relatorio` e `Base`.
- [x] `gestao_crm` reduzido a 4 tabelas usadas pela Oficina: `clientes_crm`, `veiculos_estoque`, `propostas`, `vendas`.
- [x] Removidas funções e triggers órfãos (`intranet_*`, `comunicacao_*`, `central_module_access`, `crm_can_access_*`, sync de permissões da intranet).
- [x] Policies de `propostas` e `vendas` passaram a usar `crm_has_access()`.
- [x] `servicos-api` (perfil do colaborador) deixou de ler `gestao_intranet.perfis_colaboradores`; bio, habilidades etc. voltam vazios.
- [x] `supabase db reset` aplicou o baseline novo (11.638 -> 4.847 linhas) e o login continua funcionando.
- `supabase/schema_remoto.sql` (dump do banco original) foi apagado.

**Falta:**
- [ ] Testar no navegador as telas do Financeiro e da Oficina (veículo, checklist, perfil do colaborador).
- [x] CRM removido por completo (migration 20260101001000: `drop schema gestao_crm`): sem estoque/propostas/vendas, sem o botão "Promover para estoque" na Oficina, sem `crmApi`. Cadastros de clientes e veículos da Oficina seguem em `public`.
- [x] Bug corrigido no proxy por tenant: `sql.begin` não existia dentro da transação da requisição e quebrava criar/transferir/excluir veículo e iniciar checklist (agora vira SAVEPOINT). Coberto pelo teste da Oficina.
- [x] apps/servicos/CLAUDE.md atualizado (seção Multi-tenant no topo; menções ao monorepo marcadas como histórico).
- [ ] Decidir sobre `notificacoes.*` x `gestao_servicos.notificacoes` e `integracoes` (hoje mantidos).
- [x] `supabase/schema_remoto.sql` e `docs/migrations_originais_referencia/` apagados (continham a marca original e vestígios de URLs/chaves antigas).

**Esforço restante:** baixo. **Risco:** médio até as telas serem testadas.

## 2b. Multiempresa (tenant_id + RLS) — PARCIAL (feito em 2026-10-26)

**Modelo:** tenant (cliente da plataforma) > empresas > unidades. Tabela `public.tenants` + `tenant_id NOT NULL` em todas as
tabelas de negócio (migration `20260101000300_multitenant.sql`). Catálogos globais ficam sem tenant: `public.sistemas` e o
catálogo de veículos (marcas, modelos, versões, cores, categorias).

**Feito:**
- [x] `public.tenants`, coluna `tenant_id` (default `public.current_tenant_id()`), índice e policy RESTRICTIVE `tenant_isolation` em 34 tabelas.
- [x] Unicidades que eram globais passaram a valer por tenant (CPF/CNPJ, placa, chassi, nome de fornecedor/categoria/empresa/unidade etc.). E-mail continua global (login é global).
- [x] Edge Functions rodam cada requisição numa transação com `set local role app_tenant` + `app.tenant_id` (`_shared/tenant-db.ts`), então o RLS vale também no SQL direto. As queries não mudaram.
- [x] `servicos-api`, `servicos-oficina-api` (inclusive o link público de checklist), `servicos-lembrete-aprovacoes` e `push-api` ajustadas.
- [x] `handle_new_user` exige `tenant_id` em `raw_user_meta_data`.
- [x] Testado com 2 tenants: catálogos e listas isolados; mesmo CNPJ e nome de fornecedor nos dois tenants; o tenant B não altera nem apaga dado do A.

**Falta:**
- [x] `integracoes.*` e `notificacoes.fila_emails` agora têm `tenant_id` (migration 20260101000500): `get_credenciais(chave, tenant_id)`, único (tenant, chave), schema `integracoes` fechado para app_tenant/authenticated, fila com RLS. Testado com 2 tenants.
- [x] Configurações → E-mail: o admin do cliente cadastra remetente/Client ID/Secret/Refresh Token (admin-api `integracao_gmail_*`, segredos no Vault, nunca devolvidos ao navegador).
- [x] Worker `processa-fila-email`: envia cada e-mail com as credenciais do tenant da linha, com retry (+5 min por tentativa), ignora tenant inativo, exige `x-invoke-secret`. Testado com 2 tenants.
- [x] Worker de e-mail (a cada minuto, só se houver pendência) e `servicos-lembrete-aprovacoes` (de hora em hora) agendados por pg_cron + pg_net (migration 20260101001200). URL e segredo vêm do Vault (`functions_base_url`, `internal_invoke_secret`); o seed.sql cria os de dev. **Em produção:** criar os dois segredos no Vault (mesmo valor de `INTERNAL_INVOKE_SECRET` das functions) e `supabase functions deploy`; sem eles o job só registra um aviso. Testado: cron → worker → 200.
- [x] WhatsApp por cliente, **só a separação** (migration 20260101001500, `_shared/whatsapp.ts`): fila `notificacoes.fila_whatsapp` isolada por cliente (RLS), interface de provedor sem nenhum registrado, `enqueueWhatsapp` e status `integracao_whatsapp_obter` no admin-api (hoje: provider "nenhum"). Nada envia mensagem. **Quando escolher o provedor:** implementar `WhatsappProvider`, tela/ação para salvar a integração (modelo: Gmail em admin-api + `IntegracaoEmail.jsx`), worker sobre a fila e cron (modelo: `processa-fila-email` + migration 20260101001200), e chamar `enqueueWhatsapp` nos pontos de aviso. Teste de isolamento da fila no `npm test`.
- [ ] `solicitacoes_pagamento.numero` usa sequência global (cada tenant vê saltos); numerar por tenant se isso importar.
- [ ] Painel administrativo da plataforma (schema `plataforma`: tenants, planos, assinaturas, super-admin) e criação de tenant/usuário (liga com o item 1).
- [x] Storage: policies de `comprovantes-pagamento` e `oficina-checklist-fotos` exigem que a pasta raiz (id da solicitação/avaliação) pertença ao tenant (migration 20260101000600); as APIs recusam `storage_path` fora da pasta do registro. Testado via API de Storage.
- [x] Bucket `assinaturas`: a policy de leitura agora só enxerga arquivos de colaboradores do próprio tenant (migration 20260101000800), então um cliente não consegue listar/enumerar as assinaturas de outro. Testado (12 casos em `npm test`).
- [x] Bucket `assinaturas` agora é privado (migration 20260101001300). O banco guarda só `assinatura_path`; `me` (12 h) e o checklist (10 min, inclusive o link público) devolvem URL assinada. `atualizar_assinatura` só aceita caminho da pasta do próprio colaborador. Coberto em `npm test` (URL pública não abre).
- [x] `solicitacoes_pagamento.numero` agora é por tenant (contador atômico + trigger, migration 20260101000700; único por tenant). Testado com 2 tenants.
- [x] Teste automatizado de isolamento: `npm test` (tests/isolamento-tenants.test.mjs, 16 casos: cadastros, edição/exclusão cruzada, referências, usuários, integração de e-mail, ações de plataforma, catálogos, Storage, assinaturas, acesso do admin novo, auditoria, administradores da plataforma, Oficina (clientes/veículos) e cliente desativado; usa o container do Postgres local para criar a solicitação de teste). Exige Supabase + functions no ar e cria/desativa 2 clientes por execução.
- [x] Testes do fluxo completo (`tests/fluxo-solicitacoes.test.mjs`: solicitação criar → aprovar → pagar com permissões, reprovação, validações e notificações; Oficina cadastro de veículo → checklist → avaliar → finalizar; outro cliente não acessa) e workflow `.github/workflows/ci.yml` (build + Supabase local + functions + `npm test`). **O workflow nunca rodou** (a pasta não é repositório git): na primeira execução pode precisar de ajuste. Helpers em `tests/_helpers.mjs`. Total: 21 casos.
- [x] Navegador com 2 clientes (Alfa e Beta, criados pelo painel/API): troca obrigatória de senha no primeiro acesso, Fornecedores, Categorias e Clientes da Oficina mostram só os dados do próprio cliente (mesmo CNPJ nos dois, sem conflito); a Beta não tem rota de plataforma no app dos clientes.
- [x] Fluxo completo no navegador exercitado (tenant padrão): solicitação com anexo → aprovação → pagamento (notificações geradas, download do anexo por URL assinada) e checklist da Oficina (cadastro de veículo, 7 passos, 2 fotos, assinatura do cliente, conclusão, fotos e assinatura exibidas no documento). Achado: as URLs assinadas saíam com o host interno do Docker (`kong:8000`); `_shared/storage-url.ts` troca a origem quando `PUBLIC_SUPABASE_URL` está definida (já no `.env.local`; em produção não é necessária).
- [x] Catálogos de veículo (`marcas_veiculo`, `modelos_veiculo`, `cores_veiculo`, `categorias_veiculo`) são globais; a migration 20260101001100 traz um conjunto padrão (18 marcas, 58 modelos, 13 cores, 6 categorias), então todo cliente novo já cadastra veículo.
- [x] Plataforma → **Catálogos**: criar, editar, ativar/desativar e excluir marcas, modelos, categorias e cores (admin-api `catalogo_*`, auditado). Excluir item em uso é recusado (desative). Migration 20260101001400: as policies `*_manage` davam escrita direta (REST) a qualquer admin/gestor de qualquer cliente nesses catálogos globais; foram removidas (cliente só lê). Coberto em `npm test` (17 casos). Versões de modelo (`versoes_veiculo`) não têm tela (o app não as usa).
- [ ] `seed.sql` e o tenant `55555555-...` ("Tenant padrao") são só para dev local.

---

## 3. Cron (automações em segundo plano)

**Situação:** os 13 agendamentos originais foram trocados por stubs (apontavam para a URL de produção e carregavam o
`x-invoke-secret` antigo em texto puro). Sem eles, `servicos-lembrete-aprovacoes` (lembrete de aprovações a cada hora) e
`processa-fila-email` (fila de e-mail, a cada minuto) não disparam sozinhos.

**Como fazer:**
- Nova migration que agenda com `pg_cron` + `pg_net` apontando para a URL do próprio ambiente (local: a rede do Docker; produção:
  a URL do projeto Supabase novo), lendo o segredo do **Vault**:
  `select decrypted_secret from vault.decrypted_secrets where name = 'internal_invoke_secret'`.
- Criar o segredo no Vault e o mesmo valor em `INTERNAL_INVOKE_SECRET` das functions (`supabase/functions/.env.local` e
  `supabase secrets set`). **Nunca** colocar o valor literal em migration (já vazou uma vez no monorepo).
- Jobs: `servicos-lembrete-aprovacoes-hourly` (`0 * * * *`) e, se fizer o item 4, `processa-fila-email-every-minute`.
- Para testar sem cron: chamar a function manualmente com o header `x-invoke-secret`.

**Esforço:** baixo. **Depende de:** o ambiente ter URL fixa (item 6).

## 4. E-mail, WhatsApp e Web Push (credenciais)

**Situação:** o código existe em `_shared/` (`email.ts`, `whatsapp.ts`, `push.ts`) mas não há credenciais, e a function
`processa-fila-email` não foi copiada.

**Como fazer:**
- **E-mail:** copiar `processa-fila-email` do original; criar credenciais **próprias** (Gmail API: `GMAIL_CLIENT_ID`,
  `GMAIL_CLIENT_SECRET`, `GMAIL_REFRESH_TOKEN`, `GMAIL_SENDER`) ou trocar o transporte em `sendGmail` por SMTP/Resend. No local,
  dá para usar o Inbucket/Mailpit (http://127.0.0.1:55324) para ver os e-mails sem enviar de verdade.
  **Não reaproveitar credenciais de outros ambientes.**
- **Push:** gerar um par VAPID novo (`npx web-push generate-vapid-keys`) e definir `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`,
  `VAPID_SUBJECT` nas functions; a chave pública também vai para o front.
- **WhatsApp:** opcional; só se o Serviços for mandar mensagem. Exige provedor próprio (Meta ou Evolution).
- Exige o item 3 (cron) para a fila de e-mail rodar sozinha.

**Esforço:** baixo a médio. **Opcional.**

## 5. Internalizar os pacotes `@app/*` — FEITO (2026-10-26)

Os pacotes (ui, api-client, validation, pdf-signature, push) estão em `apps/servicos/src/shared/` e os imports viraram `@/shared/...`.
`vite.config.js` e `tailwind.config.cjs` são autossuficientes (sem `createAppConfig`, sem versão por git, sem `prebuild` de favicons);
as dependências do front estão em `apps/servicos/package.json`. Validado: `npm run build`, lint do app e uso no navegador
(login, Solicitações, Plataforma → Catálogos, Oficina).
- [x] Pastas antigas apagadas (`packages/`, `scripts/` e as configs da raiz) e lockfile limpo. Build, lint e `npm test` (21 casos) passam.

## 6. Produção real (Supabase hospedado + deploy)

**Situação:** só existe o ambiente local.

**Como fazer:**
- Criar um projeto Supabase **novo** (nunca apontar para outro ambiente), `supabase link`, `supabase db push`, `supabase functions
  deploy` para as 7 functions, `supabase secrets set` (item 3 e 4) e o secret no Vault.
- Configurar Auth: `site_url`, redirects, SMTP próprio, e o hook de lockout (`gestao_plataforma.hook_verificacao_senha`).
  Atenção: no monorepo o hook nativo exigia plano Team; por isso o front também chama `security-check-login-lock`.
- Deploy do front (Vercel/Netlify/etc.) com `VITE_SUPABASE_URL` e `VITE_SUPABASE_ANON_KEY` do projeto novo.
- Criar o primeiro admin (seed manual) e **trocar a senha do seed**. O `seed.sql` atual é só para local.

**Primeiro super-admin (passo manual, depois do `db push`):** `public.sistemas` ('servicos') já vem da migration
`20260101001700`. O `admin-api` exige que o usuário tenha uma linha em `public.colaboradores` (com tenant) **antes** de checar se
é admin da plataforma; sem ela o login do painel falha com "Usuario sem cadastro". Crie o usuário no Auth (e-mail confirmado) e rode:

```sql
insert into public.colaboradores (id, nome, email, funcao, status, tenant_id)
values ('<user_id>', 'Super Admin', '<email>', 'admin', 'ativo', '55555555-5555-5555-5555-555555555555');
insert into plataforma.administradores (user_id) values ('<user_id>');
```

No primeiro login do painel, cadastre o autenticador (TOTP).

**Esforço:** médio. **Depende de:** itens 1 e 2 para ser entregável.

## 7. Para vender/entregar

- **Repositório limpo:** `git init` novo, sem o histórico do monorepo (houve vazamento de segredo em 2026-10 e há URL/chaves de
  produção nas migrations antigas). As migrations antigas de referência já foram apagadas desta pasta.
- **Modelo:** uma instância por cliente (mais simples, recomendado) ou multi-tenant (`tenant_id` + RLS em todas as tabelas, bem mais
  trabalho). Decisão em aberto; ver o documento de venda.
- **Marca:** nome e logo vêm de `VITE_APP_NAME`, `VITE_APP_TAGLINE` e `VITE_LOGO_URL` (ver `apps/servicos/src/lib/branding.js`); o ícone padrão é genérico (`apps/servicos/public`). Defina o ALLOWED_ORIGINS das functions com o domínio de produção.
- **Documentação, licença e termos** para o comprador; manual de instalação (o README atual serve de base).
- **Testes:** o Serviços não tem testes automatizados; vale um mínimo para o fluxo de solicitação/aprovação antes de entregar.

---

## Já validado nesta cópia
Build do front; Supabase local (baseline + Storage + seed); login; `servicos-api`, `servicos-oficina-api`, `push-api` e as três
`security-*` respondendo. **Não validado:** uso do app no navegador (Financeiro e Oficina de ponta a ponta), push, e-mail, WhatsApp.

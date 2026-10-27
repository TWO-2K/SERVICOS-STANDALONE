# Usuários de login (ambiente local)

Somente para desenvolvimento local. **Não use estas credenciais em produção** — troque a senha e remova o seed.

URL do app dos clientes: http://localhost:5177/padrao (o final é o identificador/slug do cliente; cada cliente tem o seu)
URL do painel da plataforma: http://localhost:5178 (só admin da plataforma; pede um código de aplicativo autenticador)

| Perfil | E-mail | Senha | Observação |
|---|---|---|---|
| Admin da plataforma + admin do cliente "Tenant padrao" | `admin@servicos.local` | `Servicos@123` | Vem do `supabase/seed.sql`. Entra no painel da plataforma (5178, criar/desativar clientes) e em **Configurações** do app dos clientes (usuários, cadastros, e-mail). |

## Como obter outros logins

- **Novo cliente:** entre no painel da plataforma (http://localhost:5178) como admin da plataforma → **Clientes** → Novo cliente. A senha temporária do
  administrador do cliente aparece **uma única vez** na tela (copie na hora); o primeiro acesso exige trocar a senha.
- **Novo usuário de um cliente:** como admin do cliente → **Configurações → Usuários → Novo usuário**. Também gera senha
  temporária exibida uma vez. "Resetar senha" gera outra.
- Senhas definidas pelos usuários não ficam registradas em lugar nenhum.

## Observações

- O `npm run db:reset` apaga tudo e recria apenas o usuário acima.
- O teste automatizado (`npm test`) cria clientes e usuários próprios (`admin-a-xxxx@teste.local` etc.) com senhas
  aleatórias e os desativa no final; eles não são utilizáveis depois.

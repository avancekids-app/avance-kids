# Avance Kids na VPS

O produto usa uma stack própria em `/opt/avancekids`, no servidor `82.25.70.72`.
O PostgreSQL, os volumes, as credenciais e a rede Docker são exclusivos do Avance
Kids. A stack Nexo e seu Caddy não participam deste deploy.

| Serviço | Endereço |
| --- | --- |
| Site (repositório `avancekids-app/avancekids`) | https://avancekids.com |
| App web | https://app.avancekids.com |
| Painel | https://admin.avancekids.com |
| Auth, REST, Storage e Functions | https://api.avancekids.com |

O Cloudflare Tunnel `avancekids-vps` encaminha os domínios para o Nginx desta
stack. O PostgreSQL escuta somente em `127.0.0.1:15432`; o gateway interno em
`127.0.0.1:18000` e o Nginx em `127.0.0.1:18080`. Studio não tem rota pública.
O app continua usando o SDK Supabase, agora com serviços e PostgreSQL na VPS.

## Deploy e migrations

Push na `main` executa `.github/workflows/deploy-vps.yml`:

1. Instala as dependências e valida todas as migrations em PostgreSQL descartável,
   tanto do zero quanto com dados existentes; executa os testes de regras e RLS.
2. Compila app e painel com o endereço público da VPS.
3. Envia somente os artefatos, migrations e functions pela chave SSH de deploy.
4. `/opt/avancekids/deploy.sh` bloqueia deploys concorrentes, faz um `pg_dump`
   completo e verifica o catálogo desse backup.
5. `supabase db push` aplica somente migrations pendentes. Qualquer erro interrompe
   o deploy antes da troca da aplicação.
6. Troca o symlink `apps/current` e recria apenas Functions e Nginx.

O site tem um workflow equivalente em seu próprio repositório, sem migrations.
Também é possível executar os workflows manualmente pelo GitHub Actions.

Configuração no GitHub:

- Secret `VPS_DEPLOY_KEY`: chave exclusiva, com comando forçado no servidor.
- Variable `VPS_KNOWN_HOSTS`: chave pública SSH conferida no servidor.
- Variable `SUPABASE_ANON_KEY`: chave pública do SDK, somente neste repositório.

As senhas do banco, SMTP, Google e Stripe ficam somente na VPS. A chave SSH aceita
apenas `app SHA` ou `site SHA` e não permite terminal nem encaminhamento de portas.
Os limites de memória dos containers estão em `compose.yml`.

Migrations devem preservar compatibilidade com a versão anterior do app. Em caso
de falha ao iniciar os containers, o script volta o symlink anterior; ele **não
desfaz migrations**, pois isso poderia apagar dados gravados após o deploy.

## Estrutura e operação

Supabase oficial: tag `self-hosted/v0.8.2`, commit
`564eab8ad7840b13324f68b1bfac074ef8d51c21`. CLI: `2.117.0`.
O checkout está em `supabase-upstream`; a cópia operacional em `supabase`.
Os arquivos deste diretório complementam o Compose oficial.

```sh
cd /opt/avancekids/supabase
docker compose --env-file .env -f docker-compose.yml \
  -f /opt/avancekids/infra/compose.yml ps
```

Configurações do servidor:

- `supabase/.env`: banco, JWT, SMTP, URLs públicas e redirect allowlist.
- `google.env`: provedor Google do projeto Avance Kids.
- `functions.env`: configuração Stripe e URLs de retorno do checkout.
- `tunnel-token`: token exclusivo do tunnel.
- `apps/releases`, `site/releases`: artefatos anteriores; `current` seleciona o ativo.
- `backups`: exportação original e backups anteriores a cada deploy do app.

Alterações em `compose.yml`, `nginx.conf` ou `deploy.sh` precisam ser copiadas
explicitamente para `/opt/avancekids/infra` ou `/opt/avancekids/deploy.sh`.
Valide com `docker compose ... config --quiet`, `nginx -t` e `bash -n`.
Não use comandos que removam todos os containers, volumes ou redes da VPS.
Ao preparar uma instalação nova, mantenha os arquivos de configuração montados
legíveis pelos usuários dos containers (SQLs 644, diretórios 755). Os arquivos
de segredos continuam 600 e `/opt/avancekids` continua 700.

## Backup da migração de 24/09/2026

`backups/source-20260924` contém:

- `full-original.dump`: exportação PostgreSQL original em formato custom, com
  `full-original.contents` para inspeção do catálogo.
- Dumps SQL de roles, estrutura, dados e histórico de migrations.
- `storage/manifest.json` e os sete arquivos originais, cada um com SHA-256.
- Relatórios de contagens, compatibilidade e correção do histórico.

Os 10 usuários, 11 identidades e 7 objetos foram preservados. A restauração foi
feita em uma transação; 52 tabelas foram conferidas por contagem. Cinco blocos
COPY vazios de recursos Auth mais novos não se aplicavam à versão self-hosted;
o original integral está preservado. Nenhuma linha foi descartada nesses blocos.
As duas URLs absolutas de avatar passaram para `api.avancekids.com`.

A migration `20260916160000` já existia na estrutura original, com as duas
colunas TEXT e os CHECKs esperados, mas faltava no histórico. Depois de conferir
a estrutura, somente o histórico da cópia na VPS foi reparado como `applied`.

`storage_transfer.py` exporta arquivos pela API Storage. Um dump PostgreSQL
sozinho não contém os arquivos. Para novos backups de arquivos:

```sh
python3 /opt/avancekids/infra/storage_transfer.py backup \
  /opt/avancekids/backups/storage-NOVA-DATA \
  --url http://127.0.0.1:18000 \
  --key-file /opt/avancekids/target-service-key
```

Restaure primeiro o banco e os buckets em um ambiente separado, depois use
`restore` com a mesma ferramenta. Ela confere os hashes antes de enviar e após
baixar os objetos restaurados. Copie backups para fora da VPS. Nunca restaure
por cima da produção sem uma janela de manutenção e uma cópia atual.

## Integrações

Remetente: `Avance Kids <nao-responda@avancekids.com>`, SMTP Resend na porta 465,
com chave de envio restrita a este domínio. O outro domínio da conta é independente.
O modelo em português está em `supabase/templates/recovery.html`, com o logo em
`supabase/templates/logo.png`. Ambos acompanham o deploy do app. Auth busca o HTML
pelo Nginx interno; o logo tem endereço público estável em
`https://app.avancekids.com/email-logo.png`. O assunto é definido no Compose.
Google usa o cliente OAuth existente do projeto Avance Kids e o callback
`https://api.avancekids.com/auth/v1/callback`.
Stripe usa `/functions/v1/handle-stripe-webhook` no domínio da API. O retorno do
portal/checkout usa o endereço público, mesmo com o SDK acessando o gateway
internamente. Não altere chaves ou endpoints de outros produtos.

Novos builds nativos também precisam de `EXPO_PUBLIC_SUPABASE_URL` e
`EXPO_PUBLIC_SUPABASE_ANON_KEY` da VPS. Aplicativos nativos já instalados não
recebem essas variáveis pela mudança do DNS; precisam de nova versão.

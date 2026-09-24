#!/usr/bin/env bash
# Aplica todas as migrations em um Postgres descartável e confere o resultado.
#
# Por que não `supabase db reset`: o CLI sobe a stack inteira em portas fixas
# (54321-54324) e a máquina de desenvolvimento costuma ter outro projeto
# ocupando essas portas. Aqui sobe só um Postgres em porta aleatória, com um
# prelúdio que recria o mínimo que o Supabase fornece (auth.users, auth.uid(),
# storage.*, roles). É o suficiente para validar DDL, RLS, funções e os seeds.
#
# Uso:  bash scripts/validate_migrations.sh            # banco do zero
#       bash scripts/validate_migrations.sh upgrade    # banco já em uso
#
# No modo `upgrade` as migrations até a 08 são aplicadas, o banco recebe uma
# carga que simula produção (scripts/seed_banco_existente.sql) e só então
# entram a 09 e a 10 — é o cenário em que a 09 troca FKs de tabelas com dados.
#
# Requer: docker.

set -euo pipefail

MODO="${1:-zero}"
CORTE="20260819130000_migration-09_integridade_multi_tenant.sql"

CONTAINER="avance-kids-migration-check-$$"
IMAGE="postgres:17-alpine"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

limpar() { docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap limpar EXIT

echo "==> subindo $IMAGE"
docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=postgres "$IMAGE" >/dev/null

for _ in $(seq 1 60); do
  # O servidor temporário de init usa apenas socket e reinicia logo depois.
  if docker exec "$CONTAINER" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then break; fi
  sleep 1
done
docker exec "$CONTAINER" pg_isready -h 127.0.0.1 -U postgres >/dev/null

psql_exec() { docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -q -U postgres -d postgres; }

echo "==> prelúdio (stubs do que o Supabase fornece)"
psql_exec <<'SQL'
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;

CREATE SCHEMA auth;
CREATE TABLE auth.users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email TEXT,
  raw_user_meta_data JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- No Supabase real vem do JWT. Aqui é uma variável de sessão, o que permite
-- testar as policies trocando o "usuário logado".
CREATE FUNCTION auth.uid() RETURNS UUID
LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

CREATE SCHEMA storage;
CREATE TABLE storage.buckets (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  public BOOLEAN NOT NULL DEFAULT false
);
CREATE TABLE storage.objects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id TEXT REFERENCES storage.buckets(id),
  name TEXT NOT NULL,
  owner UUID
);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;

CREATE FUNCTION storage.foldername(name TEXT) RETURNS TEXT[]
LANGUAGE sql IMMUTABLE AS $$
  SELECT string_to_array(name, '/');
$$;

-- O Supabase concede acesso aos roles da Data API por default privileges. Sem
-- isto, `SET ROLE authenticated` esbarraria em "permission denied" e os testes
-- de RLS não testariam RLS coisa nenhuma. Precisa vir ANTES das migrations
-- para que os REVOKE delas (migration-06/07) tenham o que revogar.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT ALL ON TABLES TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA public, auth, storage TO anon, authenticated, service_role;
GRANT SELECT ON storage.buckets TO anon, authenticated, service_role;
GRANT ALL ON storage.objects TO anon, authenticated, service_role;
SQL

echo "==> aplicando migrations (modo: $MODO)"
for arquivo in "$RAIZ"/supabase/migrations/*.sql; do
  base="$(basename "$arquivo")"
  if [ "$MODO" = "upgrade" ] && [ "$base" = "$CORTE" ]; then
    echo "    -- carga de banco em uso, antes da 09 --"
    psql_exec < "$RAIZ/scripts/seed_banco_existente.sql"
  fi
  if [ "$MODO" = "upgrade" ] && [ "$base" = "20260924194000_migration-24_restaura_policies_storage.sql" ]; then
    echo "    -- simula restore com histórico aplicado, mas sem policies de Storage --"
    psql_exec <<'SQL'
DROP POLICY "Public read media bucket" ON storage.objects;
DROP POLICY "Admins manage media bucket" ON storage.objects;
DROP POLICY "Users manage own avatar folder" ON storage.objects;
SQL
  fi
  printf '    %s ... ' "$base"
  psql_exec < "$arquivo"
  echo "ok"
done

if [ "$MODO" = "upgrade" ]; then
  echo "==> conferindo que os dados anteriores sobreviveram"
  psql_exec <<'SQL'
DO $$
DECLARE v_int INTEGER;
BEGIN
  SELECT count(*) INTO v_int FROM exercise_attempts
   WHERE session_id = '9e9e9e9e-0000-0000-0000-00000000b001';
  IF v_int <> 10 THEN RAISE EXCEPTION 'tentativas anteriores sumiram (achei %)', v_int; END IF;

  SELECT count(*) INTO v_int FROM exercise_sessions
   WHERE plan_id = '9e9e9e9e-0000-0000-0000-00000000a001';
  IF v_int <> 1 THEN RAISE EXCEPTION 'sessão anterior sumiu'; END IF;

  SELECT count(*) INTO v_int FROM activity_plans
   WHERE child_id = '9e9e9e9e-0000-0000-0000-00000000c001';
  IF v_int <> 2 THEN RAISE EXCEPTION 'planos anteriores sumiram (achei %)', v_int; END IF;

  -- As FKs novas passam a valer para os dados que já estavam lá.
  BEGIN
    INSERT INTO exercise_attempts (session_id, plan_id, child_id, repeticao_numero, resultado)
    VALUES ('9e9e9e9e-0000-0000-0000-00000000b001', '9e9e9e9e-0000-0000-0000-00000000a002',
            '9e9e9e9e-0000-0000-0000-00000000c001', 1, 'sem_ajuda');
    RAISE EXCEPTION 'FK composta não pegou em linha pré-existente';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;

  RAISE NOTICE 'upgrade: dados anteriores intactos e constraints ativas';
END $$;
SQL
fi

echo "==> conferências"
psql_exec <<'SQL'
DO $$
DECLARE
  v_int INTEGER;
BEGIN
  -- migration-06: catálogo e log de aceite
  SELECT count(*) INTO v_int FROM terms_documents WHERE vigente;
  IF v_int <> 1 THEN RAISE EXCEPTION 'terms_documents vigentes: esperava 1, achei %', v_int; END IF;

  SELECT count(*) INTO v_int FROM pg_policies
   WHERE tablename = 'terms_acceptances' AND cmd IN ('INSERT','UPDATE','DELETE');
  IF v_int <> 0 THEN
    RAISE EXCEPTION 'terms_acceptances não pode ter policy de escrita (achei %)', v_int;
  END IF;

  -- migration-07: retenção do histórico financeiro
  SELECT count(*) INTO v_int
    FROM information_schema.columns
   WHERE table_name = 'payment_history' AND column_name = 'user_id' AND is_nullable = 'YES';
  IF v_int <> 1 THEN RAISE EXCEPTION 'payment_history.user_id deveria ser nullable'; END IF;

  SELECT count(*) INTO v_int
    FROM pg_constraint
   WHERE conname = 'payment_history_user_id_fkey' AND confdeltype = 'n';  -- 'n' = SET NULL
  IF v_int <> 1 THEN RAISE EXCEPTION 'payment_history_user_id_fkey deveria ser ON DELETE SET NULL'; END IF;

  -- migration-08: conteúdo oficial
  SELECT count(*) INTO v_int FROM exercises WHERE status = 'ativo';
  IF v_int <> 378 THEN RAISE EXCEPTION 'exercises ativos: esperava 378, achei %', v_int; END IF;

  SELECT count(*) INTO v_int FROM exercises WHERE codigo ~ '^F0[1-6]A-';
  IF v_int <> 0 THEN
    RAISE EXCEPTION 'placeholders deveriam ter sido removidos (sem plano referenciando): achei %', v_int;
  END IF;

  SELECT count(DISTINCT codigo) INTO v_int FROM exercises WHERE status = 'ativo';
  IF v_int <> 126 THEN RAISE EXCEPTION 'códigos oficiais: esperava 126, achei %', v_int; END IF;

  -- migration-10: os 24 códigos AT existem, mas fora de `exercises`.
  SELECT count(*) INTO v_int FROM exercises WHERE codigo ~ '^F0[1-6]AT\d{3}$';
  IF v_int <> 0 THEN RAISE EXCEPTION 'códigos AT não podem estar em exercises (achei %)', v_int; END IF;

  SELECT count(*) INTO v_int FROM screening_programs;
  IF v_int <> 72 THEN RAISE EXCEPTION 'screening_programs: esperava 72 linhas, achei %', v_int; END IF;

  SELECT count(DISTINCT codigo) INTO v_int FROM screening_programs;
  IF v_int <> 24 THEN RAISE EXCEPTION 'screening_programs: esperava 24 códigos, achei %', v_int; END IF;

  -- migration-16: perguntas oficiais extraídas do documento da cliente.
  SELECT count(*) INTO v_int FROM questions WHERE status = 'ativo';
  IF v_int <> 150 THEN RAISE EXCEPTION 'perguntas oficiais ativas: esperava 150, achei %', v_int; END IF;

  SELECT count(*) INTO v_int FROM questions WHERE status = 'ativo' AND kind = 'inicial';
  IF v_int <> 24 THEN RAISE EXCEPTION 'perguntas iniciais: esperava 24, achei %', v_int; END IF;

  SELECT count(*) INTO v_int FROM questions WHERE status = 'ativo' AND kind = 'triagem';
  IF v_int <> 126 THEN RAISE EXCEPTION 'perguntas de triagem: esperava 126, achei %', v_int; END IF;

  SELECT count(*) INTO v_int FROM (
    SELECT age_bracket_id FROM questions WHERE status = 'ativo'
    GROUP BY age_bracket_id HAVING count(*) <> 25
  ) q;
  IF v_int <> 0 THEN RAISE EXCEPTION '% faixas sem exatamente 25 perguntas oficiais', v_int; END IF;

  -- migration-17: um card gratuito por código AT, fora do plano da criança.
  SELECT count(*) INTO v_int FROM plays
   WHERE codigo ~ '^F(0[1-6])AT00[1-4]$' AND plano = 'free' AND status = 'ativo';
  IF v_int <> 24 THEN RAISE EXCEPTION 'brincadeiras AT gratuitas: esperava 24, achei %', v_int; END IF;

  -- migration-18: produtos são conteúdo opcional e só admins escrevem.
  SELECT count(*) INTO v_int FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'play_products'
     AND policyname = 'Admins manage play products' AND cmd = 'ALL';
  IF v_int <> 1 THEN RAISE EXCEPTION 'policy de administração de play_products ausente'; END IF;

  SELECT count(*) INTO v_int FROM (
    SELECT codigo FROM screening_programs GROUP BY codigo HAVING count(DISTINCT nivel) <> 3
  ) q;
  IF v_int <> 0 THEN RAISE EXCEPTION '% códigos AT sem os 3 níveis', v_int; END IF;

  -- Total do material oficial: 450 registros / 150 códigos (378+72 e 126+24).
  SELECT (SELECT count(*) FROM exercises WHERE status = 'ativo')
       + (SELECT count(*) FROM screening_programs) INTO v_int;
  IF v_int <> 450 THEN RAISE EXCEPTION 'total oficial: esperava 450 registros, achei %', v_int; END IF;

  SELECT (SELECT count(DISTINCT codigo) FROM exercises WHERE status = 'ativo')
       + (SELECT count(DISTINCT codigo) FROM screening_programs) INTO v_int;
  IF v_int <> 150 THEN RAISE EXCEPTION 'total oficial: esperava 150 códigos, achei %', v_int; END IF;

  -- screening_programs não pode ganhar vínculo com habilidade nem com plano
  -- enquanto a regra de utilização estiver pendente da cliente.
  SELECT count(*) INTO v_int FROM information_schema.columns
   WHERE table_name = 'screening_programs' AND column_name IN ('skill_id', 'plano');
  IF v_int <> 0 THEN
    RAISE EXCEPTION 'screening_programs não pode ter skill_id/plano antes da definição da cliente';
  END IF;

  -- migration-09: a cadeia plano→sessão→tentativa é fechada por FK composta.
  SELECT count(*) INTO v_int FROM pg_constraint
   WHERE conname IN ('exercise_sessions_plan_child_fkey', 'exercise_attempts_session_plan_child_fkey')
     AND contype = 'f' AND cardinality(conkey) >= 2;
  IF v_int <> 2 THEN RAISE EXCEPTION 'FKs compostas de migration-09 ausentes (achei %)', v_int; END IF;

  -- Cada código oficial tem exatamente 3 níveis.
  SELECT count(*) INTO v_int FROM (
    SELECT codigo FROM exercises WHERE status = 'ativo'
    GROUP BY codigo HAVING count(DISTINCT nivel) <> 3
  ) q;
  IF v_int <> 0 THEN RAISE EXCEPTION '% códigos oficiais sem os 3 níveis', v_int; END IF;

  -- `ordem` igual nos três níveis do mesmo código: é o que mantém a travessia
  -- A -> G -> M do mesmo código em check_exercise_completion.
  SELECT count(*) INTO v_int FROM (
    SELECT codigo FROM exercises WHERE status = 'ativo'
    GROUP BY codigo HAVING count(DISTINCT ordem) <> 1
  ) q;
  IF v_int <> 0 THEN RAISE EXCEPTION '% códigos com ordem divergente entre níveis', v_int; END IF;

  -- Nenhuma atividade entrou como premium POR MIGRATION. Marcar conteúdo como
  -- premium é operação do backoffice (item 1.8), atividade por atividade — o
  -- que esta asserção protege é o seed não decidir isso sozinho.
  SELECT count(*) INTO v_int FROM exercises WHERE status = 'ativo' AND plano <> 'free';
  IF v_int <> 0 THEN RAISE EXCEPTION '% atividades marcadas como premium por migration', v_int; END IF;

  -- Faixas etárias conforme a decisão da cliente (migration-11): contíguas de
  -- 12 a 143 meses, sem lacuna. Continua sendo uma asserção travada de
  -- propósito — mexer nos limites exige nova decisão registrada.
  SELECT count(*) INTO v_int FROM age_brackets
   WHERE (codigo, meses_min, meses_max) IN (
     ('F01A',12,24),('F02A',25,36),('F03A',37,48),('F04A',49,60),('F05A',61,95),('F06A',96,143)
   );
  IF v_int <> 6 THEN RAISE EXCEPTION 'age_brackets foram alteradas (esperava as 6 da migration-11, achei %)', v_int; END IF;

  -- migration-13: catálogo público, fotos pessoais privadas.
  SELECT count(*) INTO v_int FROM storage.buckets
   WHERE (id = 'media' AND public) OR (id = 'avatars' AND NOT public);
  IF v_int <> 2 THEN
    RAISE EXCEPTION 'flags dos buckets incorretas: media deve ser público e avatars privado';
  END IF;

  SELECT count(*) INTO v_int FROM pg_policies
   WHERE schemaname = 'storage' AND tablename = 'objects'
     AND policyname = 'Public read app buckets';
  IF v_int <> 0 THEN RAISE EXCEPTION 'policy pública antiga ainda inclui avatars'; END IF;

  SELECT count(*) INTO v_int FROM pg_policies
   WHERE schemaname = 'storage' AND tablename = 'objects'
     AND policyname = 'Public read media bucket' AND cmd = 'SELECT'
     AND qual LIKE '%bucket_id%media%' AND qual NOT LIKE '%avatars%';
  IF v_int <> 1 THEN RAISE EXCEPTION 'policy pública exclusiva de media ausente'; END IF;

  SELECT count(*) INTO v_int FROM pg_policies
   WHERE schemaname = 'storage' AND tablename = 'objects'
     AND policyname = 'Users manage own avatar folder' AND cmd = 'ALL'
     AND roles @> ARRAY['authenticated']::name[]
     AND qual LIKE '%bucket_id%avatars%foldername%auth.uid%'
     AND with_check LIKE '%bucket_id%avatars%foldername%auth.uid%';
  IF v_int <> 1 THEN RAISE EXCEPTION 'policy de ownership de avatars ausente ou incompleta'; END IF;

  -- migration-14: event.id é a chave de idempotência e a tabela não fica
  -- exposta aos papéis usados pelo app.
  SELECT count(*) INTO v_int
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = 'public' AND c.relname = 'stripe_webhook_events'
     AND c.relrowsecurity;
  IF v_int <> 1 THEN RAISE EXCEPTION 'stripe_webhook_events sem RLS'; END IF;

  SELECT count(*) INTO v_int FROM pg_constraint
   WHERE conrelid = 'public.stripe_webhook_events'::regclass
     AND contype = 'p' AND pg_get_constraintdef(oid) LIKE '%event_id%';
  IF v_int <> 1 THEN RAISE EXCEPTION 'event_id não é chave única dos eventos Stripe'; END IF;

  SELECT count(*) INTO v_int FROM pg_policies
   WHERE schemaname = 'public' AND tablename = 'stripe_webhook_events';
  IF v_int <> 0 THEN RAISE EXCEPTION 'stripe_webhook_events não deve ter policies para o app'; END IF;

  IF has_table_privilege('anon', 'public.stripe_webhook_events', 'SELECT,INSERT')
     OR has_table_privilege('authenticated', 'public.stripe_webhook_events', 'SELECT,INSERT') THEN
    RAISE EXCEPTION 'anon/authenticated receberam acesso aos eventos Stripe';
  END IF;

  IF has_function_privilege(
       'anon', 'public.process_stripe_webhook_event(text,text,jsonb)', 'EXECUTE'
     ) OR has_function_privilege(
       'authenticated', 'public.process_stripe_webhook_event(text,text,jsonb)', 'EXECUTE'
     ) OR NOT has_function_privilege(
       'service_role', 'public.process_stripe_webhook_event(text,text,jsonb)', 'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'privilégios da RPC do webhook incorretos';
  END IF;

  RAISE NOTICE 'todas as conferências passaram';
END $$;
SQL

echo "==> testes de acesso ao bucket avatars"
psql_exec <<'SQL'
INSERT INTO storage.objects (bucket_id, name) VALUES
  ('media', 'catalogo/publico.jpg'),
  ('avatars', '11111111-1111-1111-1111-111111111111/child-a.jpg'),
  ('avatars', '22222222-2222-2222-2222-222222222222/child-b.jpg');

SET ROLE anon;
DO $$
DECLARE v_int INTEGER;
BEGIN
  SELECT count(*) INTO v_int FROM storage.objects WHERE bucket_id = 'media';
  IF v_int <> 1 THEN RAISE EXCEPTION 'anon deveria ler media público'; END IF;

  SELECT count(*) INTO v_int FROM storage.objects WHERE bucket_id = 'avatars';
  IF v_int <> 0 THEN RAISE EXCEPTION 'anon conseguiu ler avatars privados'; END IF;

  BEGIN
    INSERT INTO storage.objects (bucket_id, name)
    VALUES ('avatars', '11111111-1111-1111-1111-111111111111/anon.jpg');
    RAISE EXCEPTION 'anon conseguiu enviar avatar';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END $$;
RESET ROLE;

SELECT set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', false);
SET ROLE authenticated;
DO $$
DECLARE v_int INTEGER;
BEGIN
  SELECT count(*) INTO v_int FROM storage.objects WHERE bucket_id = 'avatars';
  IF v_int <> 1 THEN RAISE EXCEPTION 'usuário não ficou restrito à própria pasta de avatars'; END IF;

  INSERT INTO storage.objects (bucket_id, name)
  VALUES ('avatars', '11111111-1111-1111-1111-111111111111/child-c.jpg');

  -- O upload do app usa upsert: sobrescrever exige SELECT e UPDATE também.
  UPDATE storage.objects SET name = name
   WHERE bucket_id = 'avatars'
     AND name = '11111111-1111-1111-1111-111111111111/child-c.jpg';
  GET DIAGNOSTICS v_int = ROW_COUNT;
  IF v_int <> 1 THEN RAISE EXCEPTION 'usuário não conseguiu atualizar o próprio avatar'; END IF;

  UPDATE storage.objects SET name = name
   WHERE bucket_id = 'avatars'
     AND name = '22222222-2222-2222-2222-222222222222/child-b.jpg';
  GET DIAGNOSTICS v_int = ROW_COUNT;
  IF v_int <> 0 THEN RAISE EXCEPTION 'usuário atualizou avatar de outra conta'; END IF;

  DELETE FROM storage.objects
   WHERE bucket_id = 'avatars'
     AND name = '22222222-2222-2222-2222-222222222222/child-b.jpg';
  GET DIAGNOSTICS v_int = ROW_COUNT;
  IF v_int <> 0 THEN RAISE EXCEPTION 'usuário removeu avatar de outra conta'; END IF;

  BEGIN
    INSERT INTO storage.objects (bucket_id, name)
    VALUES ('avatars', '22222222-2222-2222-2222-222222222222/invasao.jpg');
    RAISE EXCEPTION 'usuário gravou na pasta de avatars de outra conta';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  BEGIN
    INSERT INTO storage.objects (bucket_id, name) VALUES ('media', 'catalogo/invasao.jpg');
    RAISE EXCEPTION 'usuário comum gravou no catálogo administrativo';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;

  DELETE FROM storage.objects
   WHERE bucket_id = 'avatars'
     AND name = '11111111-1111-1111-1111-111111111111/child-c.jpg';
  GET DIAGNOSTICS v_int = ROW_COUNT;
  IF v_int <> 1 THEN RAISE EXCEPTION 'usuário não conseguiu remover o próprio avatar'; END IF;
END $$;
RESET ROLE;
SQL

echo "==> testes de idempotência do webhook Stripe"
psql_exec <<'SQL'
BEGIN;

INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES (
  '14141414-1414-1414-1414-141414141414',
  'webhook-harness@exemplo.test',
  '{"nome":"Webhook Harness"}'::jsonb
);

-- Conta quantas vezes o efeito (UPDATE da assinatura) realmente aconteceu.
CREATE TEMP TABLE webhook_effect_counter (calls INTEGER NOT NULL);
INSERT INTO webhook_effect_counter VALUES (0);

CREATE FUNCTION pg_temp.count_webhook_effect()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE pg_temp.webhook_effect_counter SET calls = calls + 1;
  RETURN NEW;
END;
$$;

CREATE TRIGGER harness_count_webhook_effect
  AFTER UPDATE ON public.subscriptions
  FOR EACH ROW
  WHEN (NEW.user_id = '14141414-1414-1414-1414-141414141414'::UUID)
  EXECUTE FUNCTION pg_temp.count_webhook_effect();

-- O mesmo event.id é entregue duas vezes. A segunda chamada precisa gerar a
-- unique_violation que a Edge Function transforma em HTTP 200 de duplicata.
SET ROLE service_role;
DO $$
BEGIN
  PERFORM public.process_stripe_webhook_event(
    'evt_harness_duplicado',
    'checkout.session.completed',
    '{
      "user_id":"14141414-1414-1414-1414-141414141414",
      "customer_id":"cus_harness",
      "subscription_id":"sub_harness",
      "plano":"premium",
      "status":"trialing",
      "trial_start":"2026-09-01T00:00:00Z",
      "trial_end":"2026-09-16T00:00:00Z",
      "current_period_start":"2026-09-01T00:00:00Z",
      "current_period_end":"2026-10-01T00:00:00Z"
    }'::jsonb
  );

  BEGIN
    PERFORM public.process_stripe_webhook_event(
      'evt_harness_duplicado',
      'checkout.session.completed',
      '{
        "user_id":"14141414-1414-1414-1414-141414141414",
        "customer_id":"cus_harness",
        "subscription_id":"sub_harness",
        "plano":"premium",
        "status":"trialing"
      }'::jsonb
    );
    RAISE EXCEPTION 'a segunda entrega não gerou unique_violation';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
END;
$$;
RESET ROLE;

DO $$
DECLARE
  v_int INTEGER;
BEGIN
  SELECT calls INTO v_int FROM webhook_effect_counter;
  IF v_int <> 1 THEN
    RAISE EXCEPTION 'evento duplicado aplicou o efeito % vezes (esperava 1)', v_int;
  END IF;

  SELECT count(*) INTO v_int FROM stripe_webhook_events
   WHERE event_id = 'evt_harness_duplicado' AND received_at IS NOT NULL;
  IF v_int <> 1 THEN
    RAISE EXCEPTION 'event.id duplicado não ficou registrado exatamente uma vez';
  END IF;
END;
$$;

-- Prova a atomicidade: o cast inválido falha depois do INSERT do event.id.
-- O marcador deve sofrer rollback para que a entrega válida seguinte processe.
SET ROLE service_role;
DO $$
BEGIN
  PERFORM public.process_stripe_webhook_event(
    'evt_harness_rollback',
    'customer.subscription.updated',
    '{
      "customer_id":"cus_harness",
      "subscription_id":"sub_harness",
      "plano":"premium",
      "status":"status_invalido"
    }'::jsonb
  );
  RAISE EXCEPTION 'payload inválido deveria ter falhado depois do registro';
EXCEPTION WHEN invalid_text_representation THEN
  NULL;
END;
$$;
RESET ROLE;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM stripe_webhook_events WHERE event_id = 'evt_harness_rollback'
  ) THEN
    RAISE EXCEPTION 'falha no efeito deixou event.id registrado';
  END IF;
END;
$$;

SET ROLE service_role;
DO $$
BEGIN
  PERFORM public.process_stripe_webhook_event(
    'evt_harness_rollback',
    'customer.subscription.updated',
    '{
      "customer_id":"cus_harness",
      "subscription_id":"sub_harness",
      "plano":"free",
      "status":"past_due"
    }'::jsonb
  );
END;
$$;
RESET ROLE;

DO $$
DECLARE
  v_int INTEGER;
BEGIN
  SELECT count(*) INTO v_int FROM stripe_webhook_events
   WHERE event_id = 'evt_harness_rollback';
  IF v_int <> 1 THEN RAISE EXCEPTION 'retry após rollback não foi processado'; END IF;

  SELECT count(*) INTO v_int FROM subscriptions
   WHERE user_id = '14141414-1414-1414-1414-141414141414'
     AND plano = 'free' AND status = 'past_due';
  IF v_int <> 1 THEN RAISE EXCEPTION 'efeito do retry após rollback não foi aplicado'; END IF;
END;
$$;

ROLLBACK;
SQL

echo "==> testes de aceite e exclusão"
psql_exec < "$RAIZ/scripts/test_termos_exclusao.sql"

echo "==> testes de isolamento entre contas (multi-tenant)"
psql_exec < "$RAIZ/scripts/test_multi_tenant.sql"

echo "==> testes das decisões da cliente (migration-11)"
psql_exec < "$RAIZ/scripts/test_logica_cliente.sql"

# Não depende do Postgres, mas fecha o par com os cenários SQL do gate: o banco
# diz o que existe, este diz o que o app decide em cima disso.
echo "==> cenários do gate de reaceite dos termos"
bash "$RAIZ/scripts/test_terms_gate.sh"

echo "==> OK"

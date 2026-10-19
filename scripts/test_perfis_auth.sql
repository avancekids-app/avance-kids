-- Regressão do cadastro da criança após restauração sem trigger de signup.
\set ON_ERROR_STOP on

BEGIN;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('25252525-0000-0000-0000-000000000001', 'perfil-existente@exemplo.test',
   '{"nome":"Responsável existente","cpf":"25252525001"}');
UPDATE profiles SET telefone = '11999999999'
WHERE id = '25252525-0000-0000-0000-000000000001';
UPDATE subscriptions SET plano = 'premium', status = 'active',
  stripe_subscription_id = 'sub_preservar', teste_gratis_ate = now() - interval '30 days'
WHERE user_id = '25252525-0000-0000-0000-000000000001';
INSERT INTO children (user_id, nome, data_nascimento)
VALUES ('25252525-0000-0000-0000-000000000001', 'Criança existente', '2022-01-10');

CREATE TEMP TABLE perfis_antes AS SELECT id, to_jsonb(p) AS dados FROM profiles p;
CREATE TEMP TABLE assinaturas_antes AS SELECT user_id, to_jsonb(s) AS dados FROM subscriptions s;
CREATE TEMP TABLE criancas_antes AS SELECT id, to_jsonb(c) AS dados FROM children c;

-- Um restore pode preservar Auth e histórico de migrations sem este trigger.
DROP TRIGGER on_auth_user_created ON auth.users;
INSERT INTO auth.users (id, email, raw_user_meta_data, created_at) VALUES
  ('25252525-0000-0000-0000-000000000002', 'perfil-ausente@exemplo.test',
   '{"nome":"Responsável recuperado","cpf":"25252525002","data_nascimento":"1990-03-12","termos_aceitos":true}',
   now() - interval '60 days'),
  ('25252525-0000-0000-0000-000000000003', 'perfil-recadastro@exemplo.test',
   '{"full_name":"Conta Google","cpf":"25252525001","data_nascimento":"1990-02-31"}', now());
INSERT INTO account_deletions (user_id, email_hash) VALUES
  ('25252525-0000-0000-0000-000000000099',
   encode(sha256(convert_to('perfil-recadastro@exemplo.test', 'UTF8')), 'hex'));

DO $$
DECLARE v_constraint TEXT;
BEGIN
  BEGIN
    INSERT INTO children (user_id, nome, data_nascimento)
    VALUES ('25252525-0000-0000-0000-000000000002', 'Criança', '2022-01-10');
    RAISE EXCEPTION 'FALHA: cenário não reproduziu o erro de vínculo';
  EXCEPTION WHEN foreign_key_violation THEN
    GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
    IF v_constraint <> 'children_user_id_fkey' THEN RAISE; END IF;
  END;
END;
$$;

\ir ../supabase/migrations/20261019120000_migration-25_restaura_perfis_auth.sql

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM profiles WHERE id = '25252525-0000-0000-0000-000000000002'
      AND nome = 'Responsável recuperado' AND cpf = '25252525002'
      AND data_nascimento = '1990-03-12' AND termos_aceitos
  ) THEN RAISE EXCEPTION 'FALHA: dados disponíveis do perfil não foram recuperados'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM subscriptions s JOIN auth.users u ON u.id = s.user_id
    WHERE u.id = '25252525-0000-0000-0000-000000000002'
      AND s.teste_gratis_ate = fim_do_teste_gratis(u.created_at)
      AND s.teste_gratis_ate < now()
  ) THEN RAISE EXCEPTION 'FALHA: reparo renovou o teste grátis antigo'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM profiles p JOIN subscriptions s ON s.user_id = p.id
    WHERE p.id = '25252525-0000-0000-0000-000000000003'
      AND p.nome = 'Conta Google' AND p.cpf IS NULL
      AND p.data_nascimento IS NULL AND s.teste_gratis_ate IS NULL
  ) THEN RAISE EXCEPTION 'FALHA: recuperação alterou CPF existente ou renovou recadastro'; END IF;
END;
$$;

-- O mesmo INSERT usado pela Function funciona com a identidade do responsável.
SET LOCAL ROLE authenticated;
SET LOCAL request.jwt.claim.sub = '25252525-0000-0000-0000-000000000002';
INSERT INTO children (user_id, nome, data_nascimento)
VALUES ('25252525-0000-0000-0000-000000000002', 'Criança após reparo', '2022-01-10');
DO $$
BEGIN
  BEGIN
    INSERT INTO children (user_id, nome, data_nascimento)
    VALUES ('25252525-0000-0000-0000-000000000001', 'Vínculo alheio', '2022-01-10');
    RAISE EXCEPTION 'FALHA: cadastro atravessou contas';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END;
$$;
RESET ROLE;

CREATE TEMP TABLE perfis_reparados AS SELECT id, to_jsonb(p) AS dados FROM profiles p;
CREATE TEMP TABLE assinaturas_reparadas AS SELECT user_id, to_jsonb(s) AS dados FROM subscriptions s;

-- Também cobre trigger desativado e reaplicação sem duplicar/modificar dados.
ALTER TABLE auth.users DISABLE TRIGGER on_auth_user_created;
\ir ../supabase/migrations/20261019120000_migration-25_restaura_perfis_auth.sql

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM perfis_antes a LEFT JOIN profiles p ON p.id = a.id WHERE to_jsonb(p) IS DISTINCT FROM a.dados)
    OR EXISTS (SELECT 1 FROM assinaturas_antes a LEFT JOIN subscriptions s ON s.user_id = a.user_id WHERE to_jsonb(s) IS DISTINCT FROM a.dados)
    OR EXISTS (SELECT 1 FROM criancas_antes a LEFT JOIN children c ON c.id = a.id WHERE to_jsonb(c) IS DISTINCT FROM a.dados)
  THEN RAISE EXCEPTION 'FALHA: reparo modificou dados existentes'; END IF;

  IF EXISTS (SELECT 1 FROM perfis_reparados a FULL JOIN profiles p ON p.id = a.id WHERE to_jsonb(p) IS DISTINCT FROM a.dados)
    OR EXISTS (SELECT 1 FROM assinaturas_reparadas a FULL JOIN subscriptions s ON s.user_id = a.user_id WHERE to_jsonb(s) IS DISTINCT FROM a.dados)
  THEN RAISE EXCEPTION 'FALHA: reaplicação modificou perfis ou assinaturas'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgrelid = 'auth.users'::regclass
      AND tgname = 'on_auth_user_created' AND tgenabled = 'O'
      AND tgfoid = 'public.handle_new_user()'::regprocedure
  ) THEN RAISE EXCEPTION 'FALHA: trigger de signup não está ativo'; END IF;
END;
$$;

INSERT INTO auth.users (id, email, raw_user_meta_data) VALUES
  ('25252525-0000-0000-0000-000000000004', 'signup-apos-reparo@exemplo.test',
   '{"full_name":"Novo responsável Google"}');
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM profiles p JOIN subscriptions s ON s.user_id = p.id
    WHERE p.id = '25252525-0000-0000-0000-000000000004'
      AND p.nome = 'Novo responsável Google' AND s.teste_gratis_ate > now()
  ) THEN RAISE EXCEPTION 'FALHA: novo signup não criou perfil e assinatura'; END IF;
  RAISE NOTICE 'perfis Auth: FK reproduzida, cadastro recuperado, dados e isolamento preservados';
END;
$$;

ROLLBACK;

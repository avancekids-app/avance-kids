-- O histórico das migrations pode estar aplicado sem o trigger de auth.users
-- após uma restauração. Login funciona, mas children.user_id exige profiles.id.
-- Reutiliza a regra vigente da migration-22 para os próximos cadastros.
CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

ALTER TABLE auth.users ENABLE TRIGGER on_auth_user_created;

-- Recupera somente perfis ausentes, sem sobrescrever os dados já salvos.
DO $$
DECLARE
  v_user RECORD;
  v_nascimento DATE;
  v_cpf TEXT;
BEGIN
  FOR v_user IN
    SELECT u.id, u.raw_user_meta_data AS meta, u.created_at
    FROM auth.users u
    WHERE NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = u.id)
    ORDER BY u.created_at, u.id
  LOOP
    v_nascimento := NULL;
    BEGIN
      IF v_user.meta->>'data_nascimento' ~ '^\d{4}-\d{2}-\d{2}$' THEN
        v_nascimento := (v_user.meta->>'data_nascimento')::DATE;
      END IF;
    EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
      v_nascimento := NULL;
    END;

    v_cpf := NULLIF(v_user.meta->>'cpf', '');
    -- Um CPF já vinculado continua pertencendo ao perfil existente; a conta
    -- recuperada deverá completar o cadastro, sem transferir essa identidade.
    IF EXISTS (SELECT 1 FROM public.profiles p WHERE p.cpf = v_cpf) THEN
      v_cpf := NULL;
    END IF;

    INSERT INTO public.profiles
      (id, nome, cpf, data_nascimento, genero, telefone, termos_aceitos, created_at)
    VALUES (
      v_user.id,
      COALESCE(v_user.meta->>'nome', v_user.meta->>'full_name', ''),
      v_cpf,
      v_nascimento,
      NULLIF(v_user.meta->>'genero', ''),
      NULLIF(v_user.meta->>'telefone', ''),
      COALESCE(v_user.meta->>'termos_aceitos' = 'true', false),
      COALESCE(v_user.created_at, now())
    )
    ON CONFLICT (id) DO NOTHING;
  END LOOP;
END;
$$;

-- Recupera assinaturas ausentes sem alterar planos, cobranças ou prazos atuais.
-- O teste conta da criação original da conta: o reparo não concede mais 15 dias.
INSERT INTO public.subscriptions
  (user_id, plano, status, teste_gratis_ate, created_at)
SELECT u.id, 'free', 'active',
  CASE
    WHEN EXISTS (
      SELECT 1 FROM public.account_deletions d
      WHERE d.email_hash = encode(sha256(convert_to(lower(u.email), 'UTF8')), 'hex')
    ) THEN NULL
    ELSE public.fim_do_teste_gratis(u.created_at)
  END,
  COALESCE(u.created_at, now())
FROM auth.users u
JOIN public.profiles p ON p.id = u.id
WHERE NOT EXISTS (SELECT 1 FROM public.subscriptions s WHERE s.user_id = u.id)
ON CONFLICT (user_id) DO NOTHING;

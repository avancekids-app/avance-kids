-- migration-24: restaura as policies de Storage após importar o banco da nuvem.
-- O dump do Supabase exclui o schema gerenciado storage, mas o histórico das
-- migrations importado já marcava a criação destas policies como aplicada.
-- Não ignorar insufficient_privilege: o deploy precisa falhar se as regras
-- não puderem ser criadas (na VPS, postgres herda supabase_storage_admin).

UPDATE storage.buckets SET public = false WHERE id = 'avatars';

DROP POLICY IF EXISTS "Public read app buckets" ON storage.objects;
DROP POLICY IF EXISTS "Public read media bucket" ON storage.objects;
CREATE POLICY "Public read media bucket"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'media');

DROP POLICY IF EXISTS "Admins manage media bucket" ON storage.objects;
CREATE POLICY "Admins manage media bucket"
  ON storage.objects FOR ALL
  TO authenticated
  USING (bucket_id = 'media' AND public.is_admin())
  WITH CHECK (bucket_id = 'media' AND public.is_admin());

DROP POLICY IF EXISTS "Users manage own avatar folder" ON storage.objects;
CREATE POLICY "Users manage own avatar folder"
  ON storage.objects FOR ALL
  TO authenticated
  USING (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  )
  WITH CHECK (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

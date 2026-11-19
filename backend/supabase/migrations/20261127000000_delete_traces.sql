-- Deleting your account also deletes your stored run traces. Storage objects can't be
-- removed from SQL, so the app deletes its own folder through the Storage API first;
-- this lets it. Players can only ever touch their own folder.
drop policy if exists "Players delete their own traces" on storage.objects;
create policy "Players delete their own traces" on storage.objects for delete
  using (bucket_id = 'traces' and (storage.foldername(name))[1] = auth.uid()::text);

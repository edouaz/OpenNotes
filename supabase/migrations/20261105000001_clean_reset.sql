begin;
-- Test-phase "clean reset": lets a signed-in user wipe ONLY their own notebook data.
-- Drop both objects below once real documents exist (see docs/SYNC_AUDIT_AND_ROADMAP.md).
create policy own_notebook_files_delete on storage.objects for delete to authenticated
using (bucket_id = 'notebooks' and (storage.foldername(name))[1] = (select auth.uid())::text);
create function public.reset_my_notebook_data() returns void language plpgsql security definer set search_path = '' as $$
declare owner uuid := auth.uid();
begin
 if owner is null then raise exception 'authentication required' using errcode = '42501'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(owner::text || ':reset', 0));
 delete from public.notebook_heads where owner_id = owner;
 delete from public.notebook_audit where owner_id = owner;
 delete from public.notebook_revisions where owner_id = owner;
 delete from public.folder_audit where owner_id = owner;
 delete from public.cloud_folders where owner_id = owner;
end $$;
revoke all on function public.reset_my_notebook_data() from public, anon;
grant execute on function public.reset_my_notebook_data() to authenticated;
commit;

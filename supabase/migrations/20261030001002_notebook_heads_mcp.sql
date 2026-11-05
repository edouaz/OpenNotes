begin;
create table public.notebook_heads (
 owner_id uuid not null references auth.users(id), notebook_id uuid not null, revision_id uuid not null,
 primary key(owner_id, notebook_id), foreign key(owner_id, revision_id) references public.notebook_revisions(owner_id, id)
);
insert into public.notebook_heads(owner_id, notebook_id, revision_id)
select distinct on (owner_id, notebook_id) owner_id, notebook_id, id
from public.notebook_revisions order by owner_id, notebook_id, created_at desc, id desc;
alter table public.notebook_heads enable row level security;
revoke all on public.notebook_heads from public, anon, authenticated;
grant select on public.notebook_heads to authenticated;
create policy own_notebook_heads_read on public.notebook_heads for select to authenticated using ((select auth.uid()) = owner_id);
create table public.cloud_folders (
 owner_id uuid not null default auth.uid() references auth.users(id), id uuid not null,
 name text not null check (length(name) between 1 and 255), parent_id uuid,
 deleted_at timestamptz, updated_at timestamptz not null default now(),
 primary key(owner_id, id), foreign key(owner_id, parent_id) references public.cloud_folders(owner_id, id),
 check (id is distinct from parent_id)
);
alter table public.cloud_folders enable row level security;
revoke all on public.cloud_folders from public, anon, authenticated;
grant select, insert, update on public.cloud_folders to authenticated;
create policy own_folders_read on public.cloud_folders for select to authenticated using ((select auth.uid()) = owner_id);
create policy own_folders_insert on public.cloud_folders for insert to authenticated with check ((select auth.uid()) = owner_id);
create policy own_folders_update on public.cloud_folders for update to authenticated using ((select auth.uid()) = owner_id) with check ((select auth.uid()) = owner_id);
create function public.validate_cloud_folder_tree() returns trigger language plpgsql security invoker set search_path = '' as $$
begin
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(new.owner_id::text || ':folders', 0));
 if exists (with recursive ancestors(id, parent_id) as (
   select f.id, f.parent_id from public.cloud_folders f where f.owner_id = new.owner_id and f.id = new.parent_id
   union select f.id, f.parent_id from public.cloud_folders f join ancestors a on f.id = a.parent_id where f.owner_id = new.owner_id
 ) select 1 from ancestors where id = new.id) then
   raise exception 'folder cycle' using errcode = '23514';
 end if;
 return new;
end $$;
create trigger validate_cloud_folder_tree before insert or update of parent_id on public.cloud_folders
 for each row execute function public.validate_cloud_folder_tree();
create table public.folder_audit (
 id bigint generated always as identity primary key, owner_id uuid not null references auth.users(id),
 folder_id uuid not null, before_state jsonb, after_state jsonb not null, created_at timestamptz not null default now()
);
alter table public.folder_audit enable row level security;
revoke all on public.folder_audit from public, anon, authenticated;
grant select on public.folder_audit to authenticated;
create policy own_folder_audit_read on public.folder_audit for select to authenticated using ((select auth.uid()) = owner_id);
create function public.stamp_cloud_folder() returns trigger language plpgsql security invoker set search_path = '' as $$
begin
 if tg_op = 'UPDATE' and (new.owner_id is distinct from old.owner_id or new.id is distinct from old.id) then
  raise exception 'folder identity is immutable' using errcode = '22023';
 end if;
 new.updated_at := pg_catalog.clock_timestamp(); return new;
end $$;
create trigger stamp_cloud_folder before insert or update on public.cloud_folders
 for each row execute function public.stamp_cloud_folder();
-- Only this trigger may append folder audit records; clients cannot forge or delete history.
create function public.audit_cloud_folder() returns trigger language plpgsql security definer set search_path = '' as $$
begin
 if auth.uid() is distinct from new.owner_id then raise exception 'folder owner mismatch' using errcode = '42501'; end if;
 insert into public.folder_audit(owner_id,folder_id,before_state,after_state)
 values(new.owner_id,new.id,case when tg_op = 'UPDATE' then pg_catalog.to_jsonb(old) else null end,pg_catalog.to_jsonb(new));
 return new;
end $$;
revoke all on function public.audit_cloud_folder() from public, anon, authenticated;
create trigger audit_cloud_folder after insert or update on public.cloud_folders
 for each row execute function public.audit_cloud_folder();
create table public.notebook_audit (
 id bigint generated always as identity primary key, owner_id uuid not null references auth.users(id),
 notebook_id uuid not null, revision_id uuid not null, created_at timestamptz not null default now()
);
alter table public.notebook_audit enable row level security;
revoke all on public.notebook_audit from public, anon, authenticated;
grant select on public.notebook_audit to authenticated;
create policy own_audit_read on public.notebook_audit for select to authenticated using ((select auth.uid()) = owner_id);
create function public.commit_notebook_revision(p_notebook_id uuid, p_revision_id uuid, p_expected_revision uuid, p_checksum text, p_object_path text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare owner uuid := auth.uid(); current_revision uuid;
begin
 if owner is null then raise exception 'authentication required' using errcode = '42501'; end if;
 if p_notebook_id is null or p_revision_id is null or p_checksum !~ '^[a-f0-9]{64}$' or
    p_object_path is distinct from owner::text || '/' || p_notebook_id::text || '/' || p_revision_id::text || '.catnote' then
   raise exception 'invalid revision' using errcode = '22023';
 end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(owner::text || p_notebook_id::text, 0));
 select revision_id into current_revision from public.notebook_heads where owner_id = owner and notebook_id = p_notebook_id;
 if current_revision is distinct from p_expected_revision then raise exception 'notebook revision conflict' using errcode = '40001'; end if;
 if not exists (select 1 from storage.objects where bucket_id = 'notebooks' and name = p_object_path) then
   raise exception 'revision object missing' using errcode = '22023';
 end if;
 insert into public.notebook_revisions(id, owner_id, notebook_id, parent_id, checksum, object_path)
 values (p_revision_id, owner, p_notebook_id, p_expected_revision, p_checksum, p_object_path);
 insert into public.notebook_heads(owner_id, notebook_id, revision_id) values(owner, p_notebook_id, p_revision_id)
 on conflict (owner_id, notebook_id) do update set revision_id = excluded.revision_id;
 insert into public.notebook_audit(owner_id, notebook_id, revision_id) values(owner, p_notebook_id, p_revision_id);
 return p_revision_id;
end $$;
revoke all on function public.commit_notebook_revision(uuid, uuid, uuid, text, text) from public, anon;
grant execute on function public.commit_notebook_revision(uuid, uuid, uuid, text, text) to authenticated;
commit;

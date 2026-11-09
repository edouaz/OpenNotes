begin;
-- Keeps the newest p_keep revisions of each of the caller's notebooks (the head is always kept) and returns the
-- storage paths of the deleted ones so the client can remove the files. Clients cannot delete rows any other way.
create function public.prune_my_revisions(p_keep int default 10) returns table(removed_path text)
language plpgsql security definer set search_path = '' as $$
declare owner uuid := auth.uid(); doomed uuid[];
begin
 if owner is null then raise exception 'authentication required' using errcode = '42501'; end if;
 if p_keep is null or p_keep < 3 then raise exception 'keep at least 3 revisions' using errcode = '22023'; end if;
 perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(owner::text || ':prune', 0));
 select coalesce(array_agg(r.id), '{}') into doomed from (
   select id, row_number() over (partition by notebook_id order by created_at desc, id desc) as rn
   from public.notebook_revisions where owner_id = owner) r
 where r.rn > p_keep and not exists (select 1 from public.notebook_heads h where h.owner_id = owner and h.revision_id = r.id);
 update public.notebook_revisions k set parent_id = null
  where k.owner_id = owner and k.parent_id = any(doomed) and not (k.id = any(doomed));
 return query with d as (delete from public.notebook_revisions x where x.owner_id = owner and x.id = any(doomed) returning x.object_path)
  select d.object_path from d;
end $$;
revoke all on function public.prune_my_revisions(int) from public, anon;
grant execute on function public.prune_my_revisions(int) to authenticated;
commit;

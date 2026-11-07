Tu as accès à mon projet Supabase "Test" (ref `evuqpcklfxxnjzjcrwos`). Applique deux migrations SQL manquantes, dans cet ordre exact, puis vérifie. Ne touche à rien d'autre : ne supprime aucune table ni donnée, n'exécute pas de reset.

Contexte : l'app iOS appelle `public.commit_notebook_revision` avec un 6e paramètre `p_meta` ; la fonction à 6 arguments n'existe pas encore, donc tous les envois de carnets échouent (PostgREST 404 PGRST202). La migration 20261105 (clean reset) est déjà appliquée.

ÉTAPE 0 (lecture seule) : vérifie que `public.notebook_meta` n'existe pas, que `public.prune_my_revisions` n'existe pas, et que `public.commit_notebook_revision(uuid,uuid,uuid,text,text)` existe. Si l'un de ces états est différent, arrête-toi et dis-le-moi avant d'exécuter quoi que ce soit.

ÉTAPE 1 : exécute ce SQL tel quel (migration 20261106000001) :

```sql
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
```

ÉTAPE 2 : exécute ce SQL tel quel (migration 20261106000002). Elle supprime l'ancienne `commit_notebook_revision` à 5 arguments et crée celle à 6 arguments (p_meta par défaut null) :

```sql
begin;
-- Searchable notebook metadata, so agents can list/filter notebooks without downloading archives.
-- Written only by the SECURITY DEFINER functions below (same transaction as the head), never directly by clients.
create table public.notebook_meta (
 owner_id uuid not null references auth.users(id), notebook_id uuid not null, revision_id uuid not null,
 title text not null check (length(title) <= 1000), folder_id uuid, page_count int not null check (page_count >= 0),
 updated_at timestamptz not null, trashed boolean not null default false, purged boolean not null default false, favorite boolean not null default false,
 primary key (owner_id, notebook_id),
 foreign key (owner_id, notebook_id) references public.notebook_heads(owner_id, notebook_id) on delete cascade
);
create index notebook_meta_owner_updated on public.notebook_meta(owner_id, updated_at desc);
create index notebook_meta_owner_folder on public.notebook_meta(owner_id, folder_id);
alter table public.notebook_meta enable row level security;
alter table public.notebook_meta force row level security;
revoke all on public.notebook_meta from public, anon, authenticated;
grant select on public.notebook_meta to authenticated;
create policy own_notebook_meta_read on public.notebook_meta for select to authenticated using ((select auth.uid()) = owner_id);

create function public.upsert_notebook_meta(p_owner uuid, p_notebook_id uuid, p_revision_id uuid, p_meta jsonb) returns void
language plpgsql security definer set search_path = '' as $$
begin
 -- Metadata is a convenience index: a malformed value must never make a commit fail.
 begin
  insert into public.notebook_meta(owner_id, notebook_id, revision_id, title, folder_id, page_count, updated_at, trashed, purged, favorite)
  values (p_owner, p_notebook_id, p_revision_id, left(coalesce(p_meta->>'title', ''), 1000), nullif(p_meta->>'folder_id', '')::uuid,
          greatest(coalesce((p_meta->>'page_count')::int, 0), 0), coalesce((p_meta->>'updated_at')::timestamptz, pg_catalog.now()),
          coalesce((p_meta->>'trashed')::boolean, false), coalesce((p_meta->>'purged')::boolean, false), coalesce((p_meta->>'favorite')::boolean, false))
  on conflict (owner_id, notebook_id) do update set revision_id = excluded.revision_id, title = excluded.title, folder_id = excluded.folder_id,
    page_count = excluded.page_count, updated_at = excluded.updated_at, trashed = excluded.trashed, purged = excluded.purged, favorite = excluded.favorite;
 exception when others then null;
 end;
end $$;
revoke all on function public.upsert_notebook_meta(uuid, uuid, uuid, jsonb) from public, anon, authenticated;

-- Same commit protocol as before, plus optional metadata. The 5-argument calls of older app builds still resolve (p_meta defaults to null).
drop function public.commit_notebook_revision(uuid, uuid, uuid, text, text);
create function public.commit_notebook_revision(p_notebook_id uuid, p_revision_id uuid, p_expected_revision uuid, p_checksum text, p_object_path text, p_meta jsonb default null)
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
 if p_meta is not null then perform public.upsert_notebook_meta(owner, p_notebook_id, p_revision_id, p_meta); end if;
 return p_revision_id;
end $$;
revoke all on function public.commit_notebook_revision(uuid, uuid, uuid, text, text, jsonb) from public, anon;
grant execute on function public.commit_notebook_revision(uuid, uuid, uuid, text, text, jsonb) to authenticated;

-- One-time backfill for notebooks committed before this migration: the app sends metadata for the current head.
create function public.set_notebook_meta(p_notebook_id uuid, p_meta jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare owner uuid := auth.uid(); head uuid;
begin
 if owner is null then raise exception 'authentication required' using errcode = '42501'; end if;
 select revision_id into head from public.notebook_heads where owner_id = owner and notebook_id = p_notebook_id;
 if head is null then raise exception 'unknown notebook' using errcode = '22023'; end if;
 perform public.upsert_notebook_meta(owner, p_notebook_id, head, p_meta);
end $$;
revoke all on function public.set_notebook_meta(uuid, jsonb) from public, anon;
grant execute on function public.set_notebook_meta(uuid, jsonb) to authenticated;
commit;
```

Enregistre-les comme migrations nommées `20261106000001_prune_revisions` et `20261106000002_notebook_meta` si ton outil le permet. Chaque fichier a son propre begin/commit : si l'un échoue, ne continue pas, donne-moi l'erreur exacte.

ÉTAPE 3 (vérification) :
1. `select proname, pg_get_function_identity_arguments(oid) from pg_proc where pronamespace='public'::regnamespace and proname in ('commit_notebook_revision','prune_my_revisions','set_notebook_meta','upsert_notebook_meta');` doit montrer commit_notebook_revision UNIQUEMENT avec 6 arguments (p_meta jsonb inclus), plus les trois autres.
2. Les privilèges : `commit_notebook_revision`, `prune_my_revisions`, `set_notebook_meta` exécutables par `authenticated` et PAS par `anon`/`public` ; `upsert_notebook_meta` par personne.
3. `public.notebook_meta` a RLS activée et forcée, avec une seule policy de lecture `own_notebook_meta_read`.
4. Recharge le schema cache de PostgREST (`notify pgrst, 'reload schema';`).
Donne-moi un résumé court : ce qui a été exécuté, les résultats de chaque vérification, et toute anomalie.

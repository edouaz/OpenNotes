#!/usr/bin/env python3
"""Validate migration policies in disposable PostgreSQL, with minimal Supabase schema stubs."""
from pathlib import Path
import subprocess
import tempfile

BOOTSTRAP = """
create role anon;
create role authenticated;
create schema auth;
create schema storage;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as
$$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
create table storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects(id uuid primary key default gen_random_uuid(), bucket_id text, name text);
create function storage.foldername(text) returns text[] language sql immutable as
$$ select (string_to_array($1, '/'))[1:array_length(string_to_array($1, '/'),1)-1] $$;
alter table storage.objects enable row level security;
grant usage on schema public, auth, storage to anon, authenticated;
grant select, insert, update, delete on storage.objects to anon, authenticated;
insert into auth.users values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'), ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
"""


def checks(owner, other, revision, committed, stale):
    note = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
    path = f'{owner}/{note}/{revision}.catnote'
    committed_path = f'{owner}/{note}/{committed}.catnote'
    stale_path = f'{owner}/{note}/{stale}.catnote'
    return f"""
set role authenticated;
set request.jwt.claim.sub = '{owner}';
insert into storage.objects(bucket_id,name) values ('notebooks','{path}');
insert into public.notebook_revisions(id,owner_id,notebook_id,checksum,object_path)
values ('{revision}','{owner}','{note}',repeat('a',64),'{path}');
do $$ begin
  if not exists(select 1 from public.notebook_revisions where id = '{revision}') then raise exception 'owner read denied'; end if;
  if not exists(select 1 from storage.objects where name = '{path}') then raise exception 'owner binary denied'; end if;
end $$;
insert into storage.objects(bucket_id,name) values ('notebooks','{committed_path}'), ('notebooks','{stale_path}');
select public.commit_notebook_revision('{note}', '{committed}', null, repeat('a',64), '{committed_path}');
insert into public.cloud_folders(owner_id,id,name) values
 ('{owner}','dddddddd-dddd-dddd-dddd-dddddddddddd','parent'),
 ('{owner}','eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee','child');
update public.cloud_folders set parent_id='dddddddd-dddd-dddd-dddd-dddddddddddd'
 where id='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
do $$ begin
  if not exists(select 1 from public.notebook_heads where owner_id='{owner}' and notebook_id='{note}' and revision_id='{committed}') then raise exception 'committed head missing'; end if;
  if (select count(*) from public.cloud_folders where owner_id='{owner}') <> 2 then raise exception 'owner folders missing'; end if;
  begin
    perform public.commit_notebook_revision('{note}', '{stale}', null, repeat('a',64), '{stale_path}');
    raise exception 'stale head accepted';
  exception when serialization_failure then null; end;
  if exists(select 1 from public.notebook_revisions where id='{stale}') or
     not exists(select 1 from public.notebook_heads where owner_id='{owner}' and revision_id='{committed}') then raise exception 'conflict changed revision or head'; end if;
  begin
    update public.notebook_heads set revision_id='{revision}' where owner_id='{owner}' and notebook_id='{note}';
    raise exception 'direct head update allowed';
  exception when insufficient_privilege then null; end;
  begin
    insert into public.notebook_heads(owner_id,notebook_id,revision_id) values ('{owner}',gen_random_uuid(),'{revision}');
    raise exception 'direct head insert allowed';
  exception when insufficient_privilege then null; end;
  begin
    update public.cloud_folders set parent_id='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'
      where owner_id='{owner}' and id='dddddddd-dddd-dddd-dddd-dddddddddddd';
    raise exception 'folder cycle allowed';
  exception when check_violation then null; end;
end $$;
set request.jwt.claim.sub = '{other}';
do $$ declare affected integer; begin
  if exists(select 1 from public.notebook_heads where owner_id = '{owner}') then raise exception 'cross owner head visible'; end if;
  if exists(select 1 from public.cloud_folders where owner_id = '{owner}') then raise exception 'cross owner folders visible'; end if;
  update public.cloud_folders set name='changed' where owner_id='{owner}';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'cross owner folders changed'; end if;
  begin
    insert into public.cloud_folders(owner_id,id,name) values ('{owner}',gen_random_uuid(),'invalid');
    raise exception 'cross owner folder insert allowed';
  exception when insufficient_privilege then null; end;
  if exists(select 1 from public.notebook_revisions where id = '{revision}') then raise exception 'cross owner metadata visible'; end if;
  if exists(select 1 from storage.objects where name = '{path}') then raise exception 'cross owner binary visible'; end if;
  begin
    insert into storage.objects(bucket_id,name) values ('notebooks','{path}');
    raise exception 'cross owner binary insert allowed';
  exception when insufficient_privilege then null; end;
  begin
    insert into public.notebook_revisions(id,owner_id,notebook_id,checksum,object_path)
    values (gen_random_uuid(),'{owner}','{note}',repeat('a',64),'{path}');
    raise exception 'cross owner metadata insert allowed';
  exception when insufficient_privilege then null; end;
  begin
    update public.notebook_revisions set checksum=repeat('b',64) where id='{revision}';
    raise exception 'immutable metadata update allowed';
  exception when insufficient_privilege then null; end;
  update storage.objects set name='changed' where name='{path}';
  get diagnostics affected = row_count;
  if affected <> 0 then raise exception 'immutable binary changed'; end if;
end $$;
reset role;
"""


META_CHECKS = """
reset role;
set request.jwt.claim.sub = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
do $$ declare nb uuid := gen_random_uuid(); rid uuid := gen_random_uuid(); rid2 uuid := gen_random_uuid(); owner uuid := 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'; p text; begin
  -- old 5-argument call still works and creates no metadata
  p := owner||'/'||nb||'/'||rid||'.catnote';
  insert into storage.objects(bucket_id,name) values ('notebooks', p);
  perform public.commit_notebook_revision(nb, rid, null, repeat('a',64), p);
  if exists (select 1 from public.notebook_meta where notebook_id = nb) then raise exception 'meta created without p_meta'; end if;
  -- backfill, then a commit with metadata replaces it
  perform public.set_notebook_meta(nb, '{"title":"Backfilled","folder_id":"c1dfd123-1234-4abc-8def-0123456789ab","page_count":3,"updated_at":"2026-11-06T10:00:00Z"}'::jsonb);
  if (select title from public.notebook_meta where notebook_id = nb) <> 'Backfilled' then raise exception 'backfill failed'; end if;
  p := owner||'/'||nb||'/'||rid2||'.catnote';
  insert into storage.objects(bucket_id,name) values ('notebooks', p);
  perform public.commit_notebook_revision(nb, rid2, rid, repeat('b',64), p, '{"title":"Calculus","page_count":12,"trashed":true,"favorite":true,"updated_at":"2026-11-06T11:00:00Z"}'::jsonb);
  if not exists (select 1 from public.notebook_meta where notebook_id = nb and title = 'Calculus' and page_count = 12 and trashed and favorite and revision_id = rid2) then raise exception 'meta not updated by commit'; end if;
  -- malformed metadata must NOT fail the commit
  rid := gen_random_uuid(); p := owner||'/'||nb||'/'||rid||'.catnote';
  insert into storage.objects(bucket_id,name) values ('notebooks', p);
  perform public.commit_notebook_revision(nb, rid, rid2, repeat('c',64), p, '{"page_count":"not a number","trashed":"maybe"}'::jsonb);
  if (select revision_id from public.notebook_heads where notebook_id = nb) <> rid then raise exception 'malformed meta blocked the commit'; end if;
  if (select title from public.notebook_meta where notebook_id = nb) <> 'Calculus' then raise exception 'malformed meta overwrote good meta'; end if;
end $$;
set role authenticated;
do $$ begin
  begin insert into public.notebook_meta(owner_id,notebook_id,revision_id,title,page_count,updated_at) values (auth.uid(), gen_random_uuid(), gen_random_uuid(), 'x', 1, now()); raise exception 'direct meta insert allowed';
  exception when insufficient_privilege then null; end;
  if exists (select 1 from public.notebook_meta where owner_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') then raise exception 'cross owner meta visible'; end if;
  begin perform public.upsert_notebook_meta(auth.uid(), gen_random_uuid(), gen_random_uuid(), '{}'::jsonb); raise exception 'internal upsert callable';
  exception when insufficient_privilege then null; end;
end $$;
set role anon;
do $$ begin begin perform * from public.notebook_meta; raise exception 'anon meta allowed'; exception when insufficient_privilege then null; end; end $$;
reset role;
"""

PRUNE_AND_RESET = """
reset role;
set request.jwt.claim.sub = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
create table chain(i int, id uuid, nb uuid);
do $$ declare prev uuid; rid uuid; nb uuid := gen_random_uuid(); owner uuid := 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; begin
  for i in 1..12 loop
    rid := gen_random_uuid();
    insert into storage.objects(bucket_id,name) values ('notebooks', owner||'/'||nb||'/'||rid||'.catnote');
    perform public.commit_notebook_revision(nb, rid, prev, repeat('a',64), owner||'/'||nb||'/'||rid||'.catnote');
    insert into chain values (i, rid, nb);
    prev := rid;
  end loop;
end $$;
update public.notebook_revisions r set created_at = now() + (c.i || ' seconds')::interval from chain c where r.id = c.id;
do $$ declare n int; begin
  select count(*) into n from public.prune_my_revisions(10) where removed_path like '%/' || (select nb from chain limit 1) || '/%';
  if n <> 2 then raise exception 'expected 2 pruned revisions, got %', n; end if;
  if (select count(*) from public.notebook_revisions r join chain c on c.id = r.id) <> 10 then raise exception 'wrong survivor count'; end if;
  if exists (select 1 from public.notebook_revisions r join chain c on c.id = r.id where c.i <= 2) then raise exception 'oldest revision kept'; end if;
  if not exists (select 1 from public.notebook_revisions r join chain c on c.id = r.id where c.i = 12) then raise exception 'newest revision deleted'; end if;
  if not exists (select 1 from public.notebook_heads h join chain c on c.id = h.revision_id where c.i = 12) then raise exception 'head lost'; end if;
  if (select count(*) from public.notebook_revisions r join chain c on c.id = r.id where r.parent_id is null) <> 1 then raise exception 'parent chain not re-rooted'; end if;
  begin perform public.prune_my_revisions(1); raise exception 'prune below 3 allowed'; exception when invalid_parameter_value then null; end;
end $$;
set role anon;
do $$ begin
  begin perform public.prune_my_revisions(10); raise exception 'anon prune allowed'; exception when insufficient_privilege then null; end;
  begin perform public.reset_my_notebook_data(); raise exception 'anon reset allowed'; exception when insufficient_privilege then null; end;
end $$;
reset role;
set request.jwt.claim.sub = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
select public.reset_my_notebook_data();
do $$ begin
  if exists (select 1 from public.notebook_revisions where owner_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') or
     exists (select 1 from public.notebook_heads where owner_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') or
     exists (select 1 from public.cloud_folders where owner_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') then raise exception 'reset left owner data'; end if;
  if not exists (select 1 from public.notebook_revisions where owner_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') then raise exception 'reset touched another owner'; end if;
end $$;
"""


def main():
    with tempfile.TemporaryDirectory(prefix='opennotes-pg-') as temp:
        root = Path(temp)
        data = root / 'data'
        subprocess.run(['initdb', '-D', str(data), '--auth=trust', '--no-locale', '-E', 'UTF8'], check=True, stdout=subprocess.DEVNULL)
        started = False
        try:
            subprocess.run(['pg_ctl', '-D', str(data), '-l', str(root/'server.log'), '-o', f"-k {temp} -h '' -p 55439", '-w', 'start'], check=True, stdout=subprocess.DEVNULL)
            started = True
            migration = Path(__file__).resolve().parents[1] / 'supabase/migrations/202610210001_notebooks.sql'
            sql = BOOTSTRAP + migration.read_text()
            sql += (migration.parent / '20261030001002_notebook_heads_mcp.sql').read_text()
            for extra in ('20261105000001_clean_reset.sql', '20261106000001_prune_revisions.sql', '20261106000002_notebook_meta.sql'):
                sql += (migration.parent / extra).read_text()
            sql += checks('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', '11111111-1111-1111-1111-111111111111', '33333333-3333-3333-3333-333333333333', '55555555-5555-5555-5555-555555555555')
            sql += checks('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', '22222222-2222-2222-2222-222222222222', '44444444-4444-4444-4444-444444444444', '66666666-6666-6666-6666-666666666666')
            sql += """
set role anon;
set request.jwt.claim.sub = '';
do $$ begin
  begin perform * from public.notebook_revisions; raise exception 'anonymous metadata allowed';
  exception when insufficient_privilege then null; end;
  if exists(select 1 from storage.objects) then raise exception 'anonymous storage visible'; end if;
end $$;
"""
            sql += META_CHECKS
            sql += PRUNE_AND_RESET
            result = subprocess.run(['psql', '-h', temp, '-p', '55439', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1'], input=sql, capture_output=True, text=True)
            assert result.returncode == 0, result.stderr
            print('PASS: SQL migration, notebook metadata, prune/reset functions, owner read/write, A/B isolation, immutable revisions/files, head commits and conflicts, folder cycles, anonymous denial (local PostgreSQL stubs only).')
        finally:
            if started:
                subprocess.run(['pg_ctl', '-D', str(data), '-m', 'fast', '-w', 'stop'], check=True, stdout=subprocess.DEVNULL)


if __name__ == '__main__':
    main()

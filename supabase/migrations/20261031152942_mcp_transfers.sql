begin;
-- Temporary MCP transfers are separate from immutable notebook revisions.
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('mcp-transfers', 'mcp-transfers', false, 157286400, array['application/octet-stream']);
create policy mcp_transfers_read on storage.objects for select to authenticated
using (bucket_id = 'mcp-transfers' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy mcp_transfers_insert on storage.objects for insert to authenticated
with check (bucket_id = 'mcp-transfers' and (storage.foldername(name))[1] = (select auth.uid())::text
and name ~ '^[a-f0-9-]{36}/[a-f0-9-]{36}/[a-f0-9-]{36}\.bin$');
create policy mcp_transfers_delete on storage.objects for delete to authenticated
using (bucket_id = 'mcp-transfers' and (storage.foldername(name))[1] = (select auth.uid())::text);

commit;

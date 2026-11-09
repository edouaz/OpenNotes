begin;
create index cloud_folders_owner_parent on public.cloud_folders(owner_id, parent_id);
create index folder_audit_owner on public.folder_audit(owner_id);
create index notebook_audit_owner on public.notebook_audit(owner_id);
create index notebook_heads_owner_revision on public.notebook_heads(owner_id, revision_id);
create index notebook_revisions_owner_parent on public.notebook_revisions(owner_id, parent_id);
commit;

export function memoryClient() {
  const objects = new Map(), revisions = new Map(); let head = null;
  return {
    from(table) { let value; return { select() { return this; }, eq(_key, x) { value = x; return this; }, async maybeSingle() { return { data: head ? { revision_id: head } : null }; }, async single() { return { data: revisions.get(value) }; } }; },
    storage: { from() { return { async upload(path, bytes) { objects.set(path, bytes); return {}; }, async download(path) { return { data: new Blob([objects.get(path)]) }; }, async remove(paths) { for (const path of paths) objects.delete(path); return {}; }, async createSignedUploadUrl(path) { return { data: { signedUrl: `https://storage.example/upload/${path}` } }; }, async createSignedUrl(path) { return { data: { signedUrl: `https://storage.example/download/${path}` } }; } }; } },
    async rpc(_name, args) {
      if (args.p_expected_revision !== head) return { error: new Error('Revision conflict') };
      revisions.set(args.p_revision_id, { id: args.p_revision_id, notebook_id: args.p_notebook_id, checksum: args.p_checksum, object_path: args.p_object_path });
      head = args.p_revision_id; return { data: head };
    }, objects,
  };
}

import { randomBytes } from 'node:crypto';
import { PDFDocument } from 'pdf-lib';

// In-memory Supabase with several users: tables are owner-scoped like RLS, storage paths must start with the caller's ID,
// foreign keys and primary keys are enforced for folders, and `hooks` injects failures. Not a model of Supabase's limits.
export function backend() {
  const tables = { cloud_folders: [], notebook_heads: [], notebook_revisions: [], notebook_meta: [] }, objects = new Map();
  const hooks = { upload: null, download: null }, stats = { inFlight: 0, maxInFlight: 0 };
  const same = (a, b) => String(a).toLowerCase() === String(b).toLowerCase();
  function query(table, owner) {
    const filters = []; let insert = null;
    const rows = () => tables[table].filter(r => r.owner_id === owner && filters.every(f => f(r)));
    const run = () => {
      if (!insert) return { data: rows().map(({ owner_id, ...r }) => r), error: null };
      for (const r of insert) {
        if (tables[table].some(x => x.owner_id === owner && same(x.id, r.id))) return { data: null, error: Object.assign(new Error('duplicate key'), { code: '23505' }) };
        if (r.parent_id && !tables[table].some(x => x.owner_id === owner && same(x.id, r.parent_id))) return { data: null, error: Object.assign(new Error('foreign key'), { code: '23503' }) };
      }
      for (const r of insert) tables[table].push({ owner_id: owner, deleted_at: null, ...r });
      return { data: null, error: null };
    };
    const q = {
      select() { return q; }, eq(key, value) { filters.push(r => same(r[key], value)); return q; }, is(key, value) { filters.push(r => (r[key] ?? null) === value); return q; },
      in(key, values) { filters.push(r => values.some(v => same(v, r[key]))); return q; }, insert(value) { insert = [].concat(value); return q; },
      async maybeSingle() { return { data: run().data?.[0] ?? null, error: null }; }, async single() { const { data } = run(); return data?.[0] ? { data: data[0], error: null } : { data: null, error: new Error('no row') }; },
      then(resolve, reject) { return Promise.resolve(run()).then(resolve, reject); },
    };
    return q;
  }
  const guard = (owner, path) => path.startsWith(`${owner}/`) ? null : new Error('new row violates row-level security policy');
  function client(owner) {
    return {
      from: table => query(table, owner),
      storage: { from: bucket => ({
        async upload(path, bytes) { const err = guard(owner, path) ?? hooks.upload?.(bucket, path); if (err) return { error: err }; objects.set(`${bucket}/${path}`, Buffer.from(bytes)); return { error: null }; },
        async download(path) {
          const err = guard(owner, path) ?? hooks.download?.(bucket, path); if (err) return { data: null, error: err };
          stats.maxInFlight = Math.max(stats.maxInFlight, ++stats.inFlight); await new Promise(r => setTimeout(r, 15)); stats.inFlight--;
          const bytes = objects.get(`${bucket}/${path}`); return bytes ? { data: new Blob([bytes]), error: null } : { data: null, error: new Error('Object not found') };
        },
        async remove(paths) { for (const path of paths) objects.delete(`${bucket}/${path}`); return { error: null }; },
        async list(dir) { const err = guard(owner, dir); if (err) return { data: null, error: err }; return { data: [...objects.keys()].filter(k => k.startsWith(`${bucket}/${dir}/`)).map(k => ({ name: k.slice(`${bucket}/${dir}/`.length) })), error: null }; },
        async createSignedUploadUrl(path) { const err = guard(owner, path); if (err) return { data: null, error: err }; return { data: { signedUrl: `https://storage.example/upload/${path}` }, error: null }; },
        async createSignedUrl(path) { return { data: { signedUrl: `https://storage.example/download/${path}` }, error: null }; },
      }) },
      async rpc(_name, a) {
        const head = tables.notebook_heads.find(h => h.owner_id === owner && same(h.notebook_id, a.p_notebook_id));
        if ((head?.revision_id ?? null) !== a.p_expected_revision) return { error: Object.assign(new Error('notebook revision conflict'), { code: '40001' }) };
        if (!objects.has(`notebooks/${a.p_object_path}`)) return { error: new Error('revision object missing') };
        tables.notebook_revisions.push({ owner_id: owner, id: a.p_revision_id, notebook_id: a.p_notebook_id, checksum: a.p_checksum, object_path: a.p_object_path });
        if (head) head.revision_id = a.p_revision_id; else tables.notebook_heads.push({ owner_id: owner, notebook_id: a.p_notebook_id, revision_id: a.p_revision_id });
        tables.notebook_meta = tables.notebook_meta.filter(m => !(m.owner_id === owner && same(m.notebook_id, a.p_notebook_id)));
        tables.notebook_meta.push({ owner_id: owner, notebook_id: a.p_notebook_id, ...a.p_meta });
        return { data: a.p_revision_id, error: null };
      },
    };
  }
  return { client, tables, objects, hooks, stats };
}

// A PDF with `pages` pages of distinct widths (100, 101, …) so order is checkable. With `bytes`, an incompressible attachment
// and trailing whitespace (valid after %%EOF) bring the file to exactly that size.
export async function makePdf(pages, bytes) {
  const pdf = await PDFDocument.create(); for (let i = 0; i < pages; i++) pdf.addPage([100 + i, 200]);
  if (bytes) await pdf.attach(randomBytes(Math.max(0, bytes - 6000)), 'filler.bin', { mimeType: 'application/octet-stream' });
  const out = Buffer.from(await pdf.save());
  return bytes && out.length < bytes ? Buffer.concat([out, Buffer.alloc(bytes - out.length, 0x20)]) : out;
}

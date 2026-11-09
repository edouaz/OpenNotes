import { createHash, randomUUID } from 'node:crypto';
import { coded, metaOf, validateArchive } from './archive.mjs';

const digest = bytes => createHash('sha256').update(bytes).digest('hex');

// Revisions are immutable, so a verified archive can be reused safely. Keyed by owner + revision; least recently used entries are dropped first.
// Cached archives are deeply frozen: callers must clone before editing (every operation already does).
const cache = new Map(); let cacheBytes = 0;
const cacheLimit = () => Number(process.env.ARCHIVE_CACHE_MB ?? 64) * 1024 * 1024;
export const clearArchiveCache = () => { cache.clear(); cacheBytes = 0; };
const freeze = value => { if (value && typeof value === 'object' && !Object.isFrozen(value)) { Object.freeze(value); for (const child of Object.values(value)) freeze(child); } return value; };
function remember(key, archive, size) {
  if (size > cacheLimit()) return;
  cache.set(key, { archive, size }); cacheBytes += size;
  while (cacheBytes > cacheLimit()) { const [oldest, entry] = cache.entries().next().value; cache.delete(oldest); cacheBytes -= entry.size; }
}

// All operations use the caller's Supabase client, which carries their access token and RLS.
export class NotebookRepository {
  constructor(client, ownerID) { this.client = client; this.ownerID = ownerID.toLowerCase(); }
  async read(notebookID) {
    const { data: head, error } = await this.client.from('notebook_heads').select('revision_id').eq('notebook_id', notebookID).maybeSingle();
    if (error) throw error;
    if (!head) throw new Error('Notebook not found');
    return this.readRevision(notebookID, head.revision_id);
  }
  async readRevision(notebookID, revisionID) {
    const { data: revision, error: revisionError } = await this.client.from('notebook_revisions').select('id,notebook_id,checksum,object_path').eq('id', revisionID).single();
    if (revisionError) throw revisionError;
    if (revision.notebook_id.toLowerCase() !== notebookID.toLowerCase() || !revision.object_path.startsWith(`${this.ownerID}/${notebookID.toLowerCase()}/`)) throw new Error('Invalid revision');
    const key = `${this.ownerID}:${revision.id}`, hit = cache.get(key);
    if (hit) { cache.delete(key); cache.set(key, hit); return { archive: hit.archive, revisionID: revision.id }; }
    const { data: blob, error: storageError } = await this.client.storage.from('notebooks').download(revision.object_path);
    if (storageError) throw storageError;
    const bytes = Buffer.from(await blob.arrayBuffer());
    if (digest(bytes) !== revision.checksum) throw new Error('Notebook checksum mismatch');
    const archive = validateArchive(JSON.parse(bytes.toString('utf8')));
    if (archive.note.id.toLowerCase() !== notebookID.toLowerCase()) throw new Error('Archive notebook ID mismatch');
    remember(key, freeze(archive), bytes.length);
    return { archive, revisionID: revision.id };
  }
  async commit(archive, expectedRevision = null) {
    validateArchive(archive);
    const notebookID = archive.note.id.toLowerCase(), revisionID = randomUUID();
    const path = `${this.ownerID}/${notebookID}/${revisionID}.catnote`;
    const bytes = Buffer.from(JSON.stringify(archive));
    // The stored archive is the whole JSON (PDFs inside as base64, ~4/3 of their size). Set ARCHIVE_MAX_BYTES to the smallest of the
    // Supabase global limit and the notebooks bucket limit to fail here, before the upload, instead of on Supabase's 413.
    const limit = Number(process.env.ARCHIVE_MAX_BYTES ?? 150 * 1024 * 1024);
    if (bytes.length > limit) throw coded('FILE_TOO_LARGE', `Notebook archive is ${bytes.length} bytes, above the ${limit} byte storage limit (a PDF counts about 4/3 of its size)`);
    const { error: storageError } = await this.client.storage.from('notebooks').upload(path, bytes, { contentType: 'application/octet-stream', upsert: false });
    if (storageError) throw storageError;
    const { data, error } = await this.client.rpc('commit_notebook_revision', {
      p_notebook_id: notebookID, p_revision_id: revisionID, p_expected_revision: expectedRevision,
      p_checksum: digest(bytes), p_object_path: path, p_meta: metaOf(archive),
    });
    if (error) throw error;
    if (data !== revisionID) throw new Error('Unexpected revision returned');
    return revisionID;
  }
}

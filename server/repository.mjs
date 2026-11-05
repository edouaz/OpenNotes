import { createHash, randomUUID } from 'node:crypto';
import { validateArchive } from './archive.mjs';

const digest = bytes => createHash('sha256').update(bytes).digest('hex');

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
    const { data: blob, error: storageError } = await this.client.storage.from('notebooks').download(revision.object_path);
    if (storageError) throw storageError;
    const bytes = Buffer.from(await blob.arrayBuffer());
    if (digest(bytes) !== revision.checksum) throw new Error('Notebook checksum mismatch');
    const archive = validateArchive(JSON.parse(bytes.toString('utf8')));
    if (archive.note.id.toLowerCase() !== notebookID.toLowerCase()) throw new Error('Archive notebook ID mismatch');
    return { archive, revisionID: revision.id };
  }
  async commit(archive, expectedRevision = null) {
    validateArchive(archive);
    const notebookID = archive.note.id.toLowerCase(), revisionID = randomUUID();
    const path = `${this.ownerID}/${notebookID}/${revisionID}.catnote`;
    const bytes = Buffer.from(JSON.stringify(archive));
    if (bytes.length > 150 * 1024 * 1024) throw new Error('Archive exceeds storage limit');
    const { error: storageError } = await this.client.storage.from('notebooks').upload(path, bytes, { contentType: 'application/octet-stream', upsert: false });
    if (storageError) throw storageError;
    const { data, error } = await this.client.rpc('commit_notebook_revision', {
      p_notebook_id: notebookID, p_revision_id: revisionID, p_expected_revision: expectedRevision,
      p_checksum: digest(bytes), p_object_path: path,
    });
    if (error) throw error;
    if (data !== revisionID) throw new Error('Unexpected revision returned');
    return revisionID;
  }
}

import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { createHash } from 'node:crypto';
import { NotebookRepository, clearArchiveCache } from '../repository.mjs';
import { newBlankPage } from '../archive.mjs';
import { memoryClient } from './helpers.mjs';
const owner = 'a1dfd123-1234-4abc-8def-0123456789ab', noteID = 'e1dfd123-1234-4abc-8def-0123456789ab', folderID = 'c1dfd123-1234-4abc-8def-0123456789ab';
const archive = () => { const { page, drawing } = newBlankPage(noteID, 0); return { version: 2, note: { id: noteID, folderID, title: 'Test', pageIDs: [page.id], createdAt: 0, updatedAt: 0 }, pages: [page], resources: { [page.drawingResourceID]: drawing } }; };
test('publication retains the first writer when a second is stale', async () => {
  const client = memoryClient(), repository = new NotebookRepository(client, owner), first = archive();
  const revision = await repository.commit(first);
  const a = structuredClone(await repository.read(noteID)), b = structuredClone(await repository.read(noteID)); // cached archives are frozen
  a.archive.note.title = 'First'; b.archive.note.title = 'Second';
  await repository.commit(a.archive, revision);
  await assert.rejects(repository.commit(b.archive, revision), /conflict/);
  assert.equal((await repository.read(noteID)).archive.note.title, 'First');
});
test('read refuses a changed object checksum', async () => {
  const client = memoryClient(), repository = new NotebookRepository(client, owner);
  await repository.commit(archive());
  const path = [...client.objects.keys()][0]; client.objects.set(path, Buffer.from('{}'));
  await assert.rejects(repository.read(noteID), /checksum/);
});
test('every commit carries the searchable metadata the app also writes', async () => {
  let sent; const client = memoryClient(), rpc = client.rpc; client.rpc = async (name, args) => { sent = args; return rpc(name, args); };
  const repository = new NotebookRepository(client, owner), a = archive();
  a.note.title = 'Calculus'; a.note.favorite = true; a.note.deletedAt = 100; a.note.updatedAt = 794_000_000; // seconds since 2001-01-01
  await repository.commit(a);
  assert.deepEqual(sent.p_meta, { title: 'Calculus', folder_id: folderID, page_count: 1, updated_at: new Date((794_000_000 + 978307200) * 1000).toISOString(), trashed: true, purged: false, favorite: true });
});

test('an immutable revision is downloaded once, then served frozen from the cache; a new revision is fetched', async () => {
  clearArchiveCache();
  let downloads = 0; const client = memoryClient(), from = client.storage.from.bind(client.storage);
  client.storage.from = bucket => { const api = from(bucket), download = api.download; api.download = async path => { downloads++; return download(path); }; return api; };
  const repository = new NotebookRepository(client, owner), first = await repository.commit(archive());
  const a = await repository.read(noteID), b = await repository.read(noteID);
  assert.equal(downloads, 1); assert.equal(b.revisionID, first);
  assert.ok(Object.isFrozen(a.archive) && Object.isFrozen(a.archive.note) && Object.isFrozen(a.archive.pages[0]), 'cached archives cannot be mutated by accident');
  const edited = structuredClone(a.archive); edited.note.title = 'Changed';
  const second = await repository.commit(edited, first);
  assert.equal((await repository.read(noteID)).archive.note.title, 'Changed'); assert.notEqual(second, first); assert.equal(downloads, 2);
  clearArchiveCache();
});
test('the cache is bounded and evicts least recently used archives', async () => {
  clearArchiveCache(); process.env.ARCHIVE_CACHE_MB = '0.0001'; // far smaller than one archive: nothing may be retained
  try {
    let downloads = 0; const client = memoryClient(), from = client.storage.from.bind(client.storage);
    client.storage.from = bucket => { const api = from(bucket), download = api.download; api.download = async path => { downloads++; return download(path); }; return api; };
    const repository = new NotebookRepository(client, owner); await repository.commit(archive());
    await repository.read(noteID); await repository.read(noteID);
    assert.equal(downloads, 2);
  } finally { delete process.env.ARCHIVE_CACHE_MB; clearArchiveCache(); }
});

import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { createHash } from 'node:crypto';
import { NotebookRepository } from '../repository.mjs';
import { newBlankPage } from '../archive.mjs';
import { memoryClient } from './helpers.mjs';
const owner = 'a1dfd123-1234-4abc-8def-0123456789ab', noteID = 'e1dfd123-1234-4abc-8def-0123456789ab', folderID = 'c1dfd123-1234-4abc-8def-0123456789ab';
const archive = () => { const { page, drawing } = newBlankPage(noteID, 0); return { version: 2, note: { id: noteID, folderID, title: 'Test', pageIDs: [page.id], createdAt: 0, updatedAt: 0 }, pages: [page], resources: { [page.drawingResourceID]: drawing } }; };
test('publication retains the first writer when a second is stale', async () => {
  const client = memoryClient(), repository = new NotebookRepository(client, owner), first = archive();
  const revision = await repository.commit(first);
  const a = await repository.read(noteID), b = await repository.read(noteID);
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

import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { PDFDocument } from 'pdf-lib';
import { createServer } from '../mcp.mjs';
import { memoryClient } from './helpers.mjs';
const user = 'a1dfd123-1234-4abc-8def-0123456789ab', folderID = 'c1dfd123-1234-4abc-8def-0123456789ab';
const fourPages = async () => { const pdf = await PDFDocument.create(); for (const w of [100, 200, 300, 400]) pdf.addPage([w, 500]); return Buffer.from(await pdf.save()); };

async function session() {
  const fake = memoryClient(), server = createServer(fake, user, { allowWrite: true }), client = new Client({ name: 'test', version: '1.0.0' });
  const [a, b] = InMemoryTransport.createLinkedPair(); await Promise.all([server.connect(b), client.connect(a)]);
  const raw = (name, args) => client.callTool({ name, arguments: args });
  const call = async (name, args) => { const r = await raw(name, args); assert.ok(!r.isError, JSON.stringify(r)); return JSON.parse(r.content[0].text); };
  const archive = async notebookID => (await call('get_notebook', { notebookID, includeResources: true })).archive;
  return { fake, raw, call, archive, close: async () => { await client.close(); await server.close(); } };
}

test('a notebook created from a PDF holds exactly the PDF pages, in order', async () => {
  const s = await session();
  try {
    const pdf = await fourPages();
    const created = await s.call('create_notebook', { title: 'Course', folderID, pdfBase64: pdf.toString('base64') });
    assert.equal(created.pageCount, 4);
    const a = await s.archive(created.notebookID);
    assert.deepEqual(a.pages.map(p => [p.index, p.pdfIndex, p.width]), [[0, 0, 100], [1, 1, 200], [2, 2, 300], [3, 3, 400]]);
    assert.deepEqual(a.note.pageIDs, a.pages.map(p => p.id));
    const background = a.pages[0].backgroundID;
    assert.ok(a.pages.every(p => p.backgroundID === background));
    assert.ok(Buffer.from(a.resources[background], 'base64').equals(pdf), 'original PDF preserved byte for byte');
    assert.deepEqual(Object.keys(a.resources).sort(), [background, ...a.pages.map(p => p.drawingResourceID)].sort(), 'no orphan starter drawing');

    // Same through a large-file upload reserved without a notebook.
    const t = await session();
    try {
      const upload = await t.call('create_upload', {});
      t.fake.objects.set(upload.path, pdf);
      const viaUpload = await t.call('create_notebook', { title: 'Big course', folderID, uploadPath: upload.path });
      assert.equal(viaUpload.pageCount, 4); assert.equal(viaUpload.notebookID, upload.path.split('/')[1]);
      assert.equal(t.fake.objects.has(upload.path), false, 'transfer cleaned up');
    } finally { await t.close(); }
  } finally { await s.close(); }
});

test('a plain notebook still starts with one blank page', async () => {
  const s = await session();
  try {
    const created = await s.call('create_notebook', { title: 'Blank', folderID });
    const a = await s.archive(created.notebookID);
    assert.equal(a.pages.length, 1); assert.equal(a.pages[0].backgroundID, undefined);
  } finally { await s.close(); }
});

test('importing into an existing notebook keeps every existing page, blank ones included', async () => {
  const s = await session();
  try {
    const created = await s.call('create_notebook', { title: 'Mine', folderID }), { notebookID } = created;
    const added = await s.call('add_page', { notebookID, expectedRevision: created.revisionID });   // two blank pages of the user
    const before = await s.archive(notebookID);
    const imported = await s.call('import_pdf', { notebookID, expectedRevision: added.revisionID, pdfBase64: (await fourPages()).toString('base64') });
    assert.equal(imported.addedPages, 4);
    const after = await s.archive(notebookID);
    assert.equal(after.pages.length, 6);
    assert.deepEqual(after.pages.slice(0, 2), before.pages, 'existing pages untouched');
    assert.deepEqual(after.pages.slice(2).map(p => p.pdfIndex), [0, 1, 2, 3]);
  } finally { await s.close(); }
});

test('a failed or concurrent import saves nothing', async () => {
  const s = await session();
  try {
    const bad = await s.raw('create_notebook', { title: 'Broken', folderID, pdfBase64: Buffer.from('not a pdf').toString('base64') });
    assert.equal(bad.isError, true);
    assert.equal(s.fake.objects.size, 0, 'no revision uploaded for a failed creation');

    const created = await s.call('create_notebook', { title: 'Mine', folderID }), { notebookID } = created;
    const edit = await s.call('add_page', { notebookID, expectedRevision: created.revisionID });
    const before = await s.archive(notebookID);
    assert.equal((await s.raw('import_pdf', { notebookID, expectedRevision: edit.revisionID, pdfBase64: Buffer.from('%PDF-1.4 broken').toString('base64') })).isError, true);
    assert.equal((await s.raw('import_pdf', { notebookID, expectedRevision: created.revisionID, pdfBase64: (await fourPages()).toString('base64') })).isError, true, 'stale revision rejected');
    assert.deepEqual(await s.archive(notebookID), before);

    // A reserved upload ID cannot overwrite a notebook that already exists.
    const upload = await s.call('create_upload', { notebookID });
    s.fake.objects.set(upload.path, await fourPages());
    assert.equal((await s.raw('create_notebook', { title: 'Clash', folderID, uploadPath: upload.path })).isError, true);
    assert.deepEqual(await s.archive(notebookID), before);
  } finally { await s.close(); }
});

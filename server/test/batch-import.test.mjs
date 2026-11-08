import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { createServer, classifyError } from '../mcp.mjs';
import { validateArchive } from '../archive.mjs';
import { backend, makePdf } from './batch-fake.mjs';
const alice = 'a1dfd123-1234-4abc-8def-0123456789ab', bob = 'b1dfd123-1234-4abc-8def-0123456789ab';
const root = 'c1dfd123-1234-4abc-8def-0123456789ab', otherRoot = 'd1dfd123-1234-4abc-8def-0123456789ab';

async function open(db, user = alice) {
  const server = createServer(db.client(user), user, { allowWrite: true }, { requestID: 'req-test' }), client = new Client({ name: 'test', version: '1.0.0' });
  const [a, b] = InMemoryTransport.createLinkedPair(); await Promise.all([server.connect(b), client.connect(a)]);
  const raw = async (name, args) => { const r = await client.callTool({ name, arguments: args }); return { isError: r.isError, body: JSON.parse(r.content[0].text) }; };
  const call = async (name, args) => { const r = await raw(name, args); assert.ok(!r.isError, JSON.stringify(r.body)); return r.body; };
  return { raw, call, close: async () => { await client.close(); await server.close(); } };
}
const seedRoot = (db, owner = alice, id = root) => db.tables.cloud_folders.push({ owner_id: owner, id, name: 'Root', parent_id: null, deleted_at: null });
// What the assistant's `curl -T` does with the signed URL.
const put = (db, uploadURL, bytes) => db.objects.set(`mcp-transfers/${uploadURL.split('/upload/')[1]}`, bytes);
const archiveOf = (db, owner, notebookID) => {
  const head = db.tables.notebook_heads.find(h => h.owner_id === owner && h.notebook_id === notebookID), rev = db.tables.notebook_revisions.find(r => r.id === head.revision_id);
  return JSON.parse(db.objects.get(`notebooks/${rev.object_path}`).toString());
};
const widths = a => a.pages.map(p => p.width);

test('the two PDFs that failed (4,546,454 and 3,584,881 bytes) import with every page and no blank page', async () => {
  const db = backend(), s = await open(db); seedRoot(db);
  try {
    for (const [name, size] of [['2 - Logique Propositionnelle.pdf', 4_546_454], ['LINFO1116 - fiche cours.pdf', 3_584_881]]) {
      const pdf = await makePdf(7, size); assert.equal(pdf.length, size);
      const upload = await s.call('create_upload', {}); db.objects.set(`mcp-transfers/${upload.path}`, pdf);
      const created = await s.call('create_notebook', { title: name, folderID: root, uploadPath: upload.path });
      assert.equal(created.pageCount, 7, name);
      const a = archiveOf(db, alice, created.notebookID);
      assert.deepEqual(widths(a), [100, 101, 102, 103, 104, 105, 106]); assert.deepEqual(a.pages.map(p => p.pdfIndex), [0, 1, 2, 3, 4, 5, 6]);
      assert.ok(a.pages.every(p => p.backgroundID), 'no blank page');
      assert.ok(Buffer.from(a.resources[a.pages[0].backgroundID], 'base64').equals(pdf), 'original PDF kept byte for byte');
      assert.equal(a.note.title, name);
    }
  } finally { await s.close(); }
});

test('validateArchive accepts large resources without overflowing the stack, and still rejects bad base64', async () => {
  const { createNotebook } = await import('../operations.mjs');
  const withResource = value => { const a = createNotebook('t', root); a.resources['x.pdf'] = value; return a; };
  for (const bytes of [3_400_000, 6_000_000, 40_000_000]) assert.doesNotThrow(() => validateArchive(withResource(Buffer.alloc(bytes, 1).toString('base64'))), `${bytes} bytes`);
  for (const value of ['AAA', 'AA=A', 'A===', 'AAAA=', 'AA\n==', 'é', 'AAAA'.repeat(2_000_000) + '!']) assert.throws(() => validateArchive(withResource(value)), /Invalid resource/, value.slice(0, 8));
});

test('errors are distinct: too large, invalid PDF, quota, internal; a stack overflow is never blamed on the caller', async () => {
  assert.equal(classifyError(new RangeError('Maximum call stack size exceeded')), 'INTERNAL');
  assert.equal(classifyError(Object.assign(new Error('The object exceeded the maximum allowed size'), { statusCode: '413' })), 'FILE_TOO_LARGE');
  assert.equal(classifyError(Object.assign(new Error('Payload too large'), { status: 413 })), 'FILE_TOO_LARGE');
  assert.equal(classifyError(Object.assign(new Error('Storage quota exceeded'), { statusCode: '402' })), 'QUOTA_EXCEEDED');
  assert.equal(classifyError(new Error('Notebook revision conflict')), 'REVISION_CONFLICT');
  const db = backend(), s = await open(db); seedRoot(db);
  try {
    const up = async bytes => { const u = await s.call('create_upload', {}); db.objects.set(`mcp-transfers/${u.path}`, bytes); return u.path; };
    const invalid = await s.raw('create_notebook', { title: 'x', folderID: root, uploadPath: await up(Buffer.from('this is not a pdf')) });
    assert.equal(invalid.body.error.code, 'INVALID_PDF'); assert.match(invalid.body.error.message, /Not a readable PDF/);
    assert.equal((await s.raw('create_notebook', { title: 'x', folderID: root, uploadPath: await up(Buffer.alloc(0)) })).body.error.code, 'INVALID_PDF');
    db.hooks.upload = bucket => bucket === 'notebooks' ? Object.assign(new Error('The object exceeded the maximum allowed size'), { statusCode: '413' }) : null;
    assert.equal((await s.raw('create_notebook', { title: 'x', folderID: root, uploadPath: await up(await makePdf(1)) })).body.error.code, 'FILE_TOO_LARGE');
    db.hooks.upload = bucket => bucket === 'notebooks' ? Object.assign(new Error('Storage quota exceeded'), { statusCode: '402' }) : null;
    assert.equal((await s.raw('create_notebook', { title: 'x', folderID: root, uploadPath: await up(await makePdf(1)) })).body.error.code, 'QUOTA_EXCEEDED');
    db.hooks.upload = () => { throw new TypeError('boom'); };
    const internal = await s.raw('create_notebook', { title: 'x', folderID: root, uploadPath: await up(await makePdf(1)) });
    assert.equal(internal.body.error.code, 'INTERNAL'); assert.equal(internal.body.error.message, 'Unexpected server error');
  } finally { await s.close(); }
});

test('configured size limits: accepted at the limit, FILE_TOO_LARGE one byte above (PDF and stored archive)', async () => {
  const db = backend(), s = await open(db); seedRoot(db);
  const pdf = await makePdf(3, 200_000), now = Date.now, saved = { pdf: process.env.MAX_PDF_BYTES, archive: process.env.ARCHIVE_MAX_BYTES };
  const create = async () => { const u = await s.call('create_upload', {}); db.objects.set(`mcp-transfers/${u.path}`, pdf); return s.raw('create_notebook', { title: 'L', folderID: root, uploadPath: u.path }); };
  try {
    Date.now = () => 1.8e12;   // timestamps in the archive vary in digits; freeze them so equal inputs give equal sizes
    process.env.MAX_PDF_BYTES = String(pdf.length); assert.ok(!(await create()).isError, 'PDF exactly at the limit');
    process.env.MAX_PDF_BYTES = String(pdf.length - 1); const over = await create();
    assert.equal(over.body.error.code, 'FILE_TOO_LARGE'); assert.match(over.body.error.message, new RegExp(String(pdf.length)));
    delete process.env.MAX_PDF_BYTES;
    const stored = [...db.objects].find(([k]) => k.endsWith('.catnote'))[1].length;   // the archive of the successful import above
    process.env.ARCHIVE_MAX_BYTES = String(stored); assert.ok(!(await create()).isError, 'archive exactly at the limit');
    process.env.ARCHIVE_MAX_BYTES = String(stored - 1); assert.equal((await create()).body.error.code, 'FILE_TOO_LARGE');
    assert.ok(stored > pdf.length * 4 / 3, 'the archive is larger than the base64 of the PDF');
  } finally { Date.now = now; for (const [k, v] of [['MAX_PDF_BYTES', saved.pdf], ['ARCHIVE_MAX_BYTES', saved.archive]]) v === undefined ? delete process.env[k] : process.env[k] = v; await s.close(); }
});

const tree = async () => ({
  'Logique/Cours/Chapitre 1.pdf': await makePdf(3), 'Logique/TP/TP1/Énoncé.pdf': await makePdf(2), 'Logique/TP/TP1/Correction.pdf': await makePdf(4),
  'Logique/TP/TP2/Énoncé.pdf': await makePdf(5), 'Racine.pdf': await makePdf(1),   // same file name "Énoncé" in two folders
});
const manifest = bytes => Object.keys(bytes).map(path => ({ path }));

test('a whole tree imports in two calls: folders, one notebook per PDF in its folder, titles, pages and order', async () => {
  const db = backend(), s = await open(db); seedRoot(db);
  try {
    const bytes = await tree(), files = manifest(bytes);
    const first = await s.call('import_pdfs', { folderID: root, files });
    assert.equal(first.progress.awaitingUpload, 5); assert.equal(first.progress.done, 0); assert.ok(first.files.every(f => f.uploadURL && f.state === 'awaiting_upload'));
    assert.equal(db.tables.notebook_heads.length, 0);
    for (const f of first.files) put(db, f.uploadURL, bytes[f.path]);
    const second = await s.call('import_pdfs', { folderID: root, importID: first.importID, files });
    assert.deepEqual(second.progress, { total: 5, done: 5, failed: 0, queued: 0, awaitingUpload: 0, percent: 100 });
    assert.deepEqual(Object.keys(second.timingsMs).sort(), ['download', 'pdf', 'prepare', 'save', 'total']);
    // Hierarchy: Logique, Logique/Cours, Logique/TP, Logique/TP/TP1, Logique/TP/TP2.
    const folders = db.tables.cloud_folders.filter(f => f.id !== root), byID = new Map(folders.map(f => [f.id, f]));
    const pathOf = id => { const f = byID.get(id); return f.parent_id === root ? f.name : `${pathOf(f.parent_id)}/${f.name}`; };
    assert.deepEqual(folders.map(f => pathOf(f.id)).sort(), ['Logique', 'Logique/Cours', 'Logique/TP', 'Logique/TP/TP1', 'Logique/TP/TP2']);
    assert.equal(byID.get(second.folders.find(f => f.path === 'Logique').folderID).parent_id, root);
    assert.equal(new Set(second.files.map(f => f.notebookID)).size, 5);
    for (const f of second.files) {
      assert.equal(f.state, 'done');
      const a = archiveOf(db, alice, f.notebookID), want = bytes[f.path];
      assert.equal(a.note.title, f.path.split('/').at(-1).replace(/\.pdf$/, '')); assert.equal(a.note.folderID, f.folderID);
      assert.equal(f.pageCount, a.pages.length); assert.equal(a.pages.length, (await import('pdf-lib').then(m => m.PDFDocument.load(want))).getPageCount());
      assert.deepEqual(widths(a), widths(a).map((_, i) => 100 + i), 'page order'); assert.ok(a.pages.every(p => p.backgroundID && p.pdfIndex != null), 'no blank page');
      assert.ok(Buffer.from(a.resources[a.pages[0].backgroundID], 'base64').equals(want));
      assert.equal(f.path.includes('/') ? pathOf(f.folderID) : root, f.path.includes('/') ? f.path.split('/').slice(0, -1).join('/') : root);
    }
    assert.equal([...db.objects.keys()].filter(k => k.startsWith('mcp-transfers/')).length, 0, 'transfers cleaned up');
  } finally { await s.close(); }
});

test('partial failure then resume: only the failures are redone, no duplicate folder, notebook or revision', async () => {
  const db = backend(), s = await open(db); seedRoot(db);
  try {
    const bytes = await tree(), files = manifest(bytes), bad = 'Logique/TP/TP1/Correction.pdf', flaky = 'Racine.pdf';
    const first = await s.call('import_pdfs', { folderID: root, files }), id = first.importID;
    for (const f of first.files) put(db, f.uploadURL, f.path === bad ? Buffer.from('%PDF-1.7 truncated') : bytes[f.path]);
    // Racine.pdf hits a transient storage error on save.
    const flakyID = first.files.find(f => f.path === flaky).notebookID; let failed = false;
    db.hooks.upload = (bucket, path) => bucket === 'notebooks' && path.includes(`/${flakyID}/`) && !failed && (failed = true) ? new Error('fetch failed') : null;
    const run = await s.call('import_pdfs', { folderID: root, importID: id, files });
    assert.deepEqual([run.progress.done, run.progress.failed], [3, 2]);
    assert.equal(run.files.find(f => f.path === bad).error.code, 'INVALID_PDF'); assert.equal(run.files.find(f => f.path === flaky).error.code, 'INTERNAL');
    const doneBefore = run.files.filter(f => f.state === 'done').map(f => [f.notebookID, db.tables.notebook_heads.find(h => h.notebook_id === f.notebookID).revision_id]);
    const foldersBefore = db.tables.cloud_folders.length;
    // The invalid file was dropped from storage (asks for a fixed upload); the transient one kept its bytes.
    const again = await s.call('import_pdfs', { folderID: root, importID: id, files });
    assert.equal(again.files.find(f => f.path === bad).state, 'awaiting_upload'); assert.ok(again.files.find(f => f.path === bad).uploadURL);
    assert.equal(again.files.find(f => f.path === flaky).state, 'done', 'transient failure retried from the stored bytes');
    put(db, again.files.find(f => f.path === bad).uploadURL, bytes[bad]);
    const last = await s.call('import_pdfs', { folderID: root, importID: id, files });
    assert.equal(last.progress.done, 5); assert.equal(last.next, 'All files imported.');
    assert.equal(db.tables.cloud_folders.length, foldersBefore, 'no duplicate folder');
    assert.equal(db.tables.notebook_heads.length, 5); assert.equal(db.tables.notebook_revisions.length, 5, 'one revision each: done notebooks were not rewritten');
    for (const [nb, rev] of doneBefore) assert.equal(db.tables.notebook_heads.find(h => h.notebook_id === nb).revision_id, rev);
    // Replaying a finished import changes nothing.
    await s.call('import_pdfs', { folderID: root, importID: id, files }); assert.equal(db.tables.notebook_revisions.length, 5);
  } finally { await s.close(); }
});

test('the same names under another importID are a different import, not a duplicate of the first', async () => {
  const db = backend(), s = await open(db); seedRoot(db);
  try {
    const pdfs = [await makePdf(2), await makePdf(3)], files = [{ path: 'Cours.pdf', title: 'Cours' }];
    const ids = [];
    for (const pdf of pdfs) {
      const first = await s.call('import_pdfs', { folderID: root, files }); put(db, first.files[0].uploadURL, pdf);
      const done = await s.call('import_pdfs', { folderID: root, importID: first.importID, files }); ids.push(done.files[0].notebookID); assert.equal(done.files[0].state, 'done');
    }
    assert.notEqual(ids[0], ids[1]); assert.deepEqual(ids.map(id => archiveOf(db, alice, id).pages.length), [2, 3]);
  } finally { await s.close(); }
});

test('files that are uploaded but over the time budget stay queued and finish on the next call', async () => {
  const db = backend(), s = await open(db), saved = process.env.IMPORT_BUDGET_MS; seedRoot(db);
  try {
    const bytes = await tree(), files = manifest(bytes), first = await s.call('import_pdfs', { folderID: root, files });
    for (const f of first.files) put(db, f.uploadURL, bytes[f.path]);
    process.env.IMPORT_BUDGET_MS = '-1';
    const none = await s.call('import_pdfs', { folderID: root, importID: first.importID, files }); assert.equal(none.progress.queued, 5); assert.equal(none.progress.done, 0);
    delete process.env.IMPORT_BUDGET_MS;
    assert.equal((await s.call('import_pdfs', { folderID: root, importID: first.importID, files })).progress.done, 5);
  } finally { saved === undefined ? delete process.env.IMPORT_BUDGET_MS : process.env.IMPORT_BUDGET_MS = saved; await s.close(); }
});

test('parallelism is bounded by IMPORT_CONCURRENCY', async () => {
  const db = backend(), s = await open(db); seedRoot(db);
  const previous = process.env.IMPORT_CONCURRENCY;
  try {
    const files = Array.from({ length: 12 }, (_, i) => ({ path: `f${i}.pdf` })), pdf = await makePdf(1);
    for (const limit of [1, 3]) {
      process.env.IMPORT_CONCURRENCY = String(limit); db.stats.maxInFlight = 0;
      const first = await s.call('import_pdfs', { folderID: root, files: files.map(f => ({ path: `${limit}/${f.path}` })) });
      for (const f of first.files) put(db, f.uploadURL, pdf);
      await s.call('import_pdfs', { folderID: root, importID: first.importID, files: files.map(f => ({ path: `${limit}/${f.path}` })) });
      assert.equal(db.stats.maxInFlight, limit);
    }
  } finally { previous === undefined ? delete process.env.IMPORT_CONCURRENCY : process.env.IMPORT_CONCURRENCY = previous; await s.close(); }
});

test('manifest validation: unsafe or ambiguous paths are rejected before anything is created', async () => {
  const db = backend(), s = await open(db); seedRoot(db);
  try {
    for (const path of ['../x.pdf', 'a/../x.pdf', '/abs.pdf', 'a//b.pdf', 'a\\b.pdf', './x.pdf', 'x.txt', 'dir/', 'a/\u0000.pdf', `${'d/'.repeat(9)}x.pdf`]) {
      const r = await s.raw('import_pdfs', { folderID: root, files: [{ path }] });
      assert.equal(r.body.error?.code, 'INVALID_ARGUMENT', path);
    }
    assert.equal((await s.raw('import_pdfs', { folderID: root, files: [{ path: 'a.pdf' }, { path: 'a.pdf' }] })).body.error.code, 'INVALID_ARGUMENT');
    assert.equal(db.tables.cloud_folders.length, 1, 'no folder created by a rejected manifest');
    // A macOS NFD name and its NFC form are the same file.
    const nfd = 'Énoncé.pdf', nfc = 'Énoncé.pdf';
    const a = await s.call('import_pdfs', { folderID: root, importID: 'e1dfd123-1234-4abc-8def-0123456789ab', files: [{ path: nfd }] });
    const b = await s.call('import_pdfs', { folderID: root, importID: 'e1dfd123-1234-4abc-8def-0123456789ab', files: [{ path: nfc }] });
    assert.equal(a.files[0].notebookID, b.files[0].notebookID); assert.equal(a.files[0].title, nfc.replace('.pdf', ''));
  } finally { await s.close(); }
});

test('access: another user\'s folder, transfers and notebooks are out of reach', async () => {
  const db = backend(); seedRoot(db, alice, root); seedRoot(db, bob, otherRoot);
  const a = await open(db, alice), b = await open(db, bob);
  try {
    // Alice cannot import into Bob's folder: it does not exist for her (RLS).
    const denied = await a.raw('import_pdfs', { folderID: otherRoot, files: [{ path: 'x.pdf' }] }); assert.equal(denied.body.error.code, 'NOT_FOUND');
    // The same importID and path give each user their own IDs and storage prefix.
    const files = [{ path: 'Cours/x.pdf' }], importID = 'f1dfd123-1234-4abc-8def-0123456789ab', pdf = await makePdf(2);
    const fa = await a.call('import_pdfs', { folderID: root, importID, files }), fb = await b.call('import_pdfs', { folderID: otherRoot, importID, files });
    assert.notEqual(fa.files[0].notebookID, fb.files[0].notebookID); assert.ok(fa.files[0].uploadURL.includes(`/upload/${alice}/`)); assert.ok(fb.files[0].uploadURL.includes(`/upload/${bob}/`));
    // Bob's bytes sitting under Alice's prefix are never read by Bob, and Alice's upload path is refused to Bob.
    put(db, fa.files[0].uploadURL, pdf);
    const stolen = await b.raw('create_notebook', { title: 'x', folderID: otherRoot, uploadPath: fa.files[0].uploadURL.split('/upload/')[1] });
    assert.equal(stolen.body.error.code, 'INVALID_ARGUMENT'); assert.match(stolen.body.error.message, /Invalid transfer path/);
    assert.equal((await b.call('import_pdfs', { folderID: otherRoot, importID, files })).files[0].state, 'awaiting_upload');
    const done = await a.call('import_pdfs', { folderID: root, importID, files }); assert.equal(done.files[0].state, 'done');
    assert.ok(db.tables.notebook_heads.every(h => h.owner_id === alice)); assert.ok(db.tables.cloud_folders.filter(f => f.name === 'Cours').every(f => f.owner_id === alice || f.owner_id === bob));
    assert.equal(db.tables.cloud_folders.filter(f => f.name === 'Cours' && f.owner_id === alice).length, 1);
    // Trashed target folders are refused too.
    db.tables.cloud_folders.find(f => f.id === root).deleted_at = '2026-01-01T00:00:00Z';
    assert.equal((await a.raw('import_pdfs', { folderID: root, files })).body.error.code, 'NOT_FOUND');
  } finally { await a.close(); await b.close(); }
});

test('appending the same PDF twice to a notebook stores it once', async () => {
  const { importPDF, createNotebook } = await import('../operations.mjs'), pdf = await makePdf(2, 100_000);
  const once = await importPDF(createNotebook('t', root), pdf), twice = await importPDF(once, pdf);
  assert.equal(Object.keys(twice.resources).filter(k => k.endsWith('.pdf')).length, 1); assert.equal(twice.pages.length, 5);
  const other = await importPDF(twice, await makePdf(2, 100_000)); assert.equal(Object.keys(other.resources).filter(k => k.endsWith('.pdf')).length, 2, 'a different PDF is stored separately');
});

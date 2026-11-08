import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { PDFDocument, StandardFonts } from 'pdf-lib';
import { createServer } from '../mcp.mjs';
import { createNotebook, importPDF, addElement } from '../operations.mjs';
import { exportPDF, renderPage } from '../render.mjs';
import { memoryClient } from './helpers.mjs';
const user = 'a1dfd123-1234-4abc-8def-0123456789ab', folderID = 'c1dfd123-1234-4abc-8def-0123456789ab';
const FONTS = ['NOTES_FONT_REGULAR', 'NOTES_FONT_BOLD', 'NOTES_FONT_ITALIC', 'NOTES_FONT_BOLD_ITALIC'];
const unicodeFont = '/System/Library/Fonts/Supplemental/Arial Unicode.ttf';

// A course handout: text on pages 1–2, page 3 is an image-only scan (no text layer).
async function handout() {
  const pdf = await PDFDocument.create(), font = await pdf.embedFont(StandardFonts.Helvetica);
  pdf.addPage([400, 300]).drawText('Exercices prévus pour la séance', { x: 30, y: 250, size: 16, font });
  const second = pdf.addPage([400, 300]); second.drawText('Exercices section 2.2', { x: 30, y: 250, size: 16, font }); second.drawText('Valeurs absolues', { x: 30, y: 200, size: 16, font });
  pdf.addPage([400, 300]).drawRectangle({ x: 20, y: 20, width: 200, height: 100 });
  return Buffer.from(await pdf.save());
}
async function session() {
  const fake = memoryClient(), server = createServer(fake, user, { allowWrite: true }, { requestID: 'req-test' }), client = new Client({ name: 'test', version: '1.0.0' });
  const [a, b] = InMemoryTransport.createLinkedPair(); await Promise.all([server.connect(b), client.connect(a)]);
  const raw = (name, args) => client.callTool({ name, arguments: args });
  const call = async (name, args) => { const r = await raw(name, args); assert.ok(!r.isError, JSON.stringify(r)); return JSON.parse(r.content[0].text); };
  const error = async (name, args) => { const r = await raw(name, args); assert.equal(r.isError, true, JSON.stringify(r)); return JSON.parse(r.content[0].text).error; };
  return { fake, client, raw, call, error, close: async () => { await client.close(); await server.close(); } };
}
async function withFonts(paths, run) {
  const saved = FONTS.map(k => process.env[k]);
  FONTS.forEach((k, i) => { if (paths[i] == null) delete process.env[k]; else process.env[k] = paths[i]; });
  try { return await run(); } finally { FONTS.forEach((k, i) => { if (saved[i] == null) delete process.env[k]; else process.env[k] = saved[i]; }); }
}

test('1. the deployed image installs every configured export font', async () => {
  const docker = await readFile(new URL('../Dockerfile', import.meta.url), 'utf8');
  const paths = [...docker.matchAll(/NOTES_FONT_\w+=(\S+)/g)].map(m => m[1]);
  assert.equal(paths.length, 4);
  // Debian bookworm: fonts-dejavu-core ships only Sans and Sans-Bold; the Oblique faces live in fonts-dejavu-extra.
  if (paths.some(p => /Oblique/.test(p))) assert.match(docker, /fonts-dejavu-extra/, 'Oblique fonts need fonts-dejavu-extra');
  assert.match(docker, /fonts-dejavu-core/);
});

test('1. a missing font is reported as a server rendering error naming the variable', async () => {
  const archive = createNotebook('Notes', folderID);
  await withFonts([null, null, '/nonexistent/DejaVuSans-Oblique.ttf', null], async () => {
    await assert.rejects(exportPDF(archive), e => e.code === 'RENDER_FAILED' && e.step === 'font' && /NOTES_FONT_ITALIC=\/nonexistent/.test(e.message));
    const s = await session();
    try {
      const created = await s.call('create_notebook', { title: 'T', folderID });
      const page = (await s.call('get_notebook_outline', { notebookID: created.notebookID })).pages[0].pageID;
      const e = await s.error('export_pdf', { notebookID: created.notebookID });
      assert.equal(e.code, 'RENDER_FAILED'); assert.equal(e.requestID, 'req-test'); assert.equal(e.retryable, false);
      assert.equal((await s.error('render_page', { notebookID: created.notebookID, pageID: page })).code, 'RENDER_FAILED');
    } finally { await s.close(); }
  });
});

test('1. with Unicode fonts, French accents and math symbols export and render', { skip: !existsSync(unicodeFont) && 'no local Unicode font' }, async () => {
  await withFonts(FONTS.map(() => unicodeFont), async () => {
    const base = createNotebook('Maths', folderID);
    const archive = addElement(base, base.pages[0].id, { kind: 'text', x: 20, y: 20, width: 400, height: 60, text: 'Démontrer que |x| ≤ √(x²) et ∑ αᵢ ≥ 0 — à rendre' });
    const pdf = await PDFDocument.load(await exportPDF(archive));
    assert.equal(pdf.getPageCount(), 1);
    const png = await renderPage(archive, archive.pages[0].id);
    assert.equal(png.subarray(1, 4).toString(), 'PNG');
  });
});

test('2. PDF text is stored at import, read per page, searched and marked', async () => {
  const s = await session();
  try {
    const created = await s.call('create_notebook', { title: 'TP1', folderID, pdfBase64: (await handout()).toString('base64') });
    const { pages } = await s.call('get_page_text', { notebookID: created.notebookID });
    assert.match(pages[0].text, /Exercices prévus pour la séance/);
    assert.match(pages[1].text, /Exercices section 2\.2/); assert.match(pages[1].text, /Valeurs absolues/);
    assert.deepEqual(pages.map(p => p.pdfText), ['available', 'available', 'empty'], 'a scan is reported empty, not as a success');
    const hits = await s.call('search_notebook', { notebookID: created.notebookID, query: 'section 2.2' });
    assert.deepEqual(hits.map(h => h.pageID), [pages[1].pageID]);
    const marked = await s.call('mark_text', { notebookID: created.notebookID, pageID: pages[1].pageID, expectedRevision: created.revisionID, query: 'Exercices section 2.2', style: 'highlight', colorHex: '#FFFF00' });
    assert.equal(marked.matches, 1);
    const { archive } = await s.call('get_notebook', { notebookID: created.notebookID });
    const added = archive.pages[1].elements.find(e => e.id === marked.elementIDs[0]);
    assert.equal(added.kind, 'highlight'); assert.equal(added.fillColorHex, '#FFFF00');
    assert.ok(archive.pages[1].backgroundID, 'the PDF stays the background; the mark is a separate element');
  } finally { await s.close(); }
});

test('2. notebooks imported before text extraction still read their PDF text (not saved back)', async () => {
  const s = await session();
  try {
    const old = await importPDF(createNotebook('Old', folderID), await handout());
    for (const page of old.pages) delete page.pdfText;   // as written by the previous server
    const { NotebookRepository } = await import('../repository.mjs');
    const revisionID = await new NotebookRepository(s.fake, user).commit(old);
    const { pages } = await s.call('get_page_text', { notebookID: old.note.id });
    assert.match(pages[2].text, /section 2\.2/);
    assert.equal(pages[0].pdfText, undefined, 'the blank starter page is not a PDF page');
    assert.equal((await s.call('get_notebook_outline', { notebookID: old.note.id })).revisionID, revisionID, 'reading created no revision');
  } finally { await s.close(); }
});

test('3. errors say whether to fix the call, re-read, or report a server fault', async () => {
  const s = await session();
  try {
    const created = await s.call('create_notebook', { title: 'E', folderID }), { notebookID } = created;
    const page = await s.call('add_page', { notebookID, expectedRevision: created.revisionID });
    const conflict = await s.error('add_page', { notebookID, expectedRevision: created.revisionID });
    assert.equal(conflict.code, 'REVISION_CONFLICT'); assert.equal(conflict.retryable, true); assert.match(conflict.action, /read it again/);
    assert.equal((await s.call('get_notebook_outline', { notebookID })).revisionID, page.revisionID, 'the conflicting write changed nothing');
    assert.equal((await s.error('update_page', { notebookID, pageID: '00000000-0000-4000-8000-000000000000', expectedRevision: page.revisionID, bookmark: true })).code, 'NOT_FOUND');
    assert.equal((await s.error('create_notebook', { title: 'X', folderID, pdfBase64: 'AA==', uploadPath: 'a/b' })).code, 'INVALID_ARGUMENT');
  } finally { await s.close(); }
});

test('4. colors accept both cases, in the schema clients receive and at run time', async () => {
  const s = await session();
  try {
    const { tools } = await s.client.listTools();
    const schemas = tools.flatMap(t => Object.entries(t.inputSchema.properties ?? {}).filter(([k]) => /color/i.test(k)).map(([k, v]) => [`${t.name}.${k}`, v.pattern]));
    assert.ok(schemas.length >= 4, JSON.stringify(schemas));
    for (const [field, pattern] of schemas) {
      const re = new RegExp(pattern);   // as a client compiles it: no flags
      assert.ok(re.test('#FFF59D') && re.test('#fff59d') && re.test('#AbC123'), field);
      assert.ok(!re.test('#FFF') && !re.test('FFF59D') && !re.test('#GGGGGG'), field);
    }
    const created = await s.call('create_notebook', { title: 'C', folderID }), pageID = (await s.call('get_notebook_outline', { notebookID: created.notebookID })).pages[0].pageID;
    await s.call('add_element', { notebookID: created.notebookID, pageID, expectedRevision: created.revisionID, kind: 'rectangle', x: 10, y: 10, width: 50, height: 50, fillColorHex: '#FFF59D' });
  } finally { await s.close(); }
});

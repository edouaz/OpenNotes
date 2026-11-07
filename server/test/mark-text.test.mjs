import test from 'node:test';
import assert from 'node:assert/strict';
import { PDFDocument, StandardFonts } from 'pdf-lib';
import { createNotebook, importPDF } from '../operations.mjs';
import { pageWords, matchRects } from '../render.mjs';

test('PDF phrases resolve to page-coordinate boxes, one per line', async () => {
  const pdf = await PDFDocument.create(), page = pdf.addPage([400, 300]), font = await pdf.embedFont(StandardFonts.Helvetica);
  page.drawText('The quick brown fox', { x: 50, y: 250, size: 20, font });   // top-left y ≈ 300-250-20
  page.drawText('jumps over, the dog.', { x: 50, y: 200, size: 20, font });
  const archive = await importPDF(createNotebook('PDF', '00000000-0000-4000-8000-000000000001'), Buffer.from(await pdf.save()));
  const words = await pageWords(archive, archive.pages[1].id);
  const [[box]] = matchRects(words, 'Quick Brown');
  assert.ok(box.x > 80 && box.x < 110 && box.y > 25 && box.y < 50 && box.width > 80, JSON.stringify(box));
  const across = matchRects(words, 'fox jumps over');
  assert.equal(across.length, 1); assert.equal(across[0].length, 2);   // spans two lines
  assert.equal(matchRects(words, 'the').length, 2);                    // all occurrences, case-insensitive
  assert.equal(matchRects(words, 'over the').length, 1);               // punctuation ignored
  assert.deepEqual(matchRects(words, 'cat'), []);
});

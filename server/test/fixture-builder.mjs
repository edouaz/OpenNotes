// Builds an archive the way the MCP does (real operations, every ink type, every element kind it can create).
// `node test/fixture-builder.mjs --write` refreshes ../fixtures/node-archive.json, which the iPad app's tests must keep decoding.
import { writeFileSync } from 'node:fs';
import { PDFDocument } from 'pdf-lib';
import { addBlankPage, addElement, addImage, addInk, createNotebook, editPage, importPDF, updateElement } from '../operations.mjs';

const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
export async function makeNodeArchive() {
  const folderID = 'c1dfd123-1234-4abc-8def-0123456789ab';
  let archive = createNotebook('Interop fixture', folderID);
  const firstPage = () => archive.pages[0].id;
  archive = editPage(archive, firstPage(), { text: 'Typed page text', bookmark: true, template: 'grid' });
  for (const kind of ['text', 'rectangle', 'ellipse', 'line', 'arrow', 'highlight']) archive = addElement(archive, firstPage(), { kind, x: 20, y: 20, width: 100, height: 40, text: kind === 'text' ? 'Hello' : '', strokeColorHex: '#315bb1', fillColorHex: '#ffe66d', strokeWidth: 2 });
  archive = addElement(archive, firstPage(), { kind: 'stickyNote', x: 40, y: 200, width: 180, height: 120, text: 'Remember', fillColorHex: '#ffe66d' });
  const sticky = archive.pages[0].elements.at(-1);
  archive = updateElement(archive, firstPage(), sticky.id, { x: 60, y: 220, rotation: 0.1, collapsed: false, isLocked: false });
  for (const inkType of ['pen', 'monoline', 'fountainPen', 'marker', 'pencil']) archive = addInk(archive, firstPage(), [[10, 10], [60, 80], [120, 40]], 3, [0.1, 0.2, 0.8, 1], inkType);
  archive = await addImage(archive, firstPage(), PNG, { x: 30, y: 400, width: 50, height: 50 });
  const pdf = await PDFDocument.create(); pdf.addPage([300, 400]);
  archive = await importPDF(archive, Buffer.from(await pdf.save({ updateMetadata: false })));
  return addBlankPage(archive);
}
if (process.argv.includes('--write')) {
  writeFileSync(new URL('../../fixtures/node-archive.json', import.meta.url), JSON.stringify(await makeNodeArchive()));
  console.log('wrote fixtures/node-archive.json');
}

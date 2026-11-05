import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { PDFDocument, degrees } from 'pdf-lib';
import { createNotebook, addElement, importPDF } from '../operations.mjs';
import { exportPDF } from '../render.mjs';
const folder = 'c1dfd123-1234-4abc-8def-0123456789ab';
test('PDF import and export preserve page count, sizes, and text content', async () => {
  const input = await PDFDocument.create(); input.addPage([200, 300]);
  const archive = await importPDF(createNotebook('Example', folder), Buffer.from(await input.save()));
  const edited = addElement(archive, archive.pages[0].id, {kind: 'text', x: 10, y: 10, width: 100, height: 50, text: 'Hello'});
  const output = await PDFDocument.load(await exportPDF(edited));
  assert.equal(output.getPageCount(), 2); assert.equal(output.getPage(1).getWidth(), 200); assert.equal(output.getPage(1).getHeight(), 300);
});
test('PDF export rejects unsupported rich text rather than omitting formatting', async () => {
  const archive = createNotebook('Example', folder);
  const edited = addElement(archive, archive.pages[0].id, {kind: 'text', x: 0, y: 0, width: 100, height: 50, text: 'Hello', richTextRTF: 'e30='});
  await assert.rejects(exportPDF(edited), /rich text/i);
});
test('rendered page returns a real PNG', async () => {
  const { renderPage } = await import('../render.mjs');
  const archive = createNotebook('Example', folder);
  const png = await renderPage(archive, archive.pages[0].id);
  assert.deepEqual([...png.subarray(0, 8)], [137,80,78,71,13,10,26,10]);
});
test('exports native lined pages, rotated shapes, dashed ink and erased outlines', async () => {
  const { addInk } = await import('../operations.mjs');
  const original = createNotebook('Ink', folder);
  original.pages[0].template = 'ruled';
  const withShape = addElement(original, original.pages[0].id, {kind:'rectangle', x:20,y:20,width:80,height:80, rotation:.4});
  const inked = addInk(withShape, original.pages[0].id, [[40,40],[100,100]], 3, [0,0,0,1]);
  const key=inked.pages[0].drawingResourceID, ink=JSON.parse(Buffer.from(inked.resources[key], 'base64'));
  ink.strokes[0].style={kind:'ballpoint',width:3,pattern:'dashed',sharpness:0,stabilization:0,pressureResponse:.5,inkAlgorithmVersion:1};
  const erased=structuredClone(ink.strokes[0]); erased.id='d1dfd123-1234-4abc-8def-0123456789ab'; erased.vectorOutline={elements:[{kind:0,points:[[5,5]]},{kind:1,points:[[10,5]]},{kind:1,points:[[10,10]]},{kind:4,points:[]}]}; ink.strokes.push(erased);
  inked.resources[key]=Buffer.from(JSON.stringify(ink)).toString('base64');
  const pdf=await PDFDocument.load(await exportPDF(inked)); assert.equal(pdf.getPageCount(),1);
});
test('rich text preserves mixed styles and cropped rotated PDF pages use displayed dimensions', async () => {
  const original=createNotebook('Rich',folder), pageID=original.pages[0].id;
  const rtf=Buffer.from('{\\rtf1\\ansi\\fs32 Hello \\b bold\\b0\\par second}').toString('base64');
  const edited=addElement(original,pageID,{kind:'stickyNote',x:20,y:20,width:200,height:150,text:'Hello bold\nsecond',richTextRTF:rtf});
  assert.equal((await PDFDocument.load(await exportPDF(edited))).getPageCount(),1);
  const pdf=await PDFDocument.create(), page=pdf.addPage([200,300]);
  page.setCropBox(10,20,100,200); page.setRotation(degrees(90)); page.drawText('Crop',{x:20,y:40,size:12});
  const imported=await importPDF(original,Buffer.from(await pdf.save()));
  assert.equal(imported.pages[1].width,200); assert.equal(imported.pages[1].height,100);
  const result=await PDFDocument.load(await exportPDF(imported));
  assert.equal(result.getPage(1).getWidth(),200); assert.equal(result.getPage(1).getHeight(),100);
});

import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { createNotebook, addBlankPage, addElement, searchArchive } from '../operations.mjs';
import { editPage, reorderPages, updateElement, addInk, removeInk } from '../operations.mjs';
const folder = 'c1dfd123-1234-4abc-8def-0123456789ab';
test('create pages and add searchable text without mutating the original', () => {
  const initial = createNotebook('Notebook', folder), next = addBlankPage(initial);
  const edited = addElement(next, next.pages[1].id, { kind: 'text', x: 5, y: 5, width: 100, height: 50, text: 'A searchable note' });
  assert.equal(initial.pages.length, 1); assert.equal(next.pages.length, 2); assert.equal(next.pages[1].elements, undefined);
  assert.equal(searchArchive(edited, 'searchable')[0].pageID, next.pages[1].id);
});

test('PDF pages retain their original resource and dimensions', async () => {
  const { PDFDocument } = await import('pdf-lib');
  const { importPDF } = await import('../operations.mjs');
  const pdf = await PDFDocument.create(); pdf.addPage([200, 300]); pdf.addPage([400, 500]);
  const input = createNotebook('PDF', folder), imported = await importPDF(input, Buffer.from(await pdf.save()));
  assert.equal(imported.pages.length, 3);
  assert.equal(imported.pages[1].width, 200); assert.equal(imported.pages[2].pdfIndex, 1);
  assert.equal(imported.pages[1].backgroundID, imported.pages[2].backgroundID);
  assert.ok(imported.resources[imported.pages[1].backgroundID]);
  assert.equal(input.pages.length, 1);
});
test('new ink uses the version 2 editable native schema', async () => {
  const { addInk } = await import('../operations.mjs');
  const input = createNotebook('Ink', folder);
  const edited = addInk(input, input.pages[0].id, [[1,2],[3,4]], 3, [0,0,0,1]);
  const ink = JSON.parse(Buffer.from(edited.resources[edited.pages[0].drawingResourceID], 'base64'));
  assert.equal(ink.inkSchemaVersion, 2); assert.deepEqual(ink.strokes[0].path.controlPoints[1].location, [3,4]);
  assert.equal(JSON.parse(Buffer.from(input.resources[input.pages[0].drawingResourceID], 'base64')).strokes.length, 0);
});

test('page and element edits preserve originals and reject missing IDs', () => {
  const initial=createNotebook('Test',folder), pageID=initial.pages[0].id;
  const second=addBlankPage(initial), ordered=reorderPages(second,[second.pages[1].id,pageID]);
  assert.equal(ordered.pages[0].index,0); assert.equal(ordered.note.pageIDs[0],second.pages[1].id);
  const edited=editPage(ordered,pageID,{text:'exercise',bookmark:true,template:'grid'});
  assert.equal(edited.pages[1].bookmark,true); assert.equal(initial.pages[0].text,undefined);
  assert.throws(()=>reorderPages(second,[pageID,pageID]),/order/);
  const withElement=addElement(edited,pageID,{kind:'text',x:10,y:10,width:100,height:30,text:'before'});
  const id=withElement.pages[1].elements[0].id;
  const changed=updateElement(withElement,pageID,id,{text:'after'});
  assert.equal(changed.pages[1].elements[0].text,'after');
  assert.equal(updateElement(changed,pageID,id,null).pages[1].elements.length,0);
});

test('sticky resize preserves ink, moving attaches it and removing recovers through original archive', () => {
  let archive=createNotebook('Test',folder), pageID=archive.pages[0].id;
  archive=addElement(archive,pageID,{kind:'stickyNote',x:10,y:10,width:100,height:100,text:''});
  const noteID=archive.pages[0].elements[0].id;
  archive=addInk(archive,pageID,[[20,20],[40,40]],3,[0,0,0,1]);
  const key=archive.pages[0].drawingResourceID, ink=JSON.parse(Buffer.from(archive.resources[key],'base64'));
  ink.strokes[0].parentID=noteID; archive.resources[key]=Buffer.from(JSON.stringify(ink)).toString('base64');
  const resized=updateElement(archive,pageID,noteID,{width:150,height:120});
  assert.equal(resized.resources[key],archive.resources[key]);
  const moved=updateElement(resized,pageID,noteID,{x:30,y:40});
  assert.deepEqual(JSON.parse(Buffer.from(moved.resources[key],'base64')).strokes[0].transform,[1,0,0,1,20,30]);
  assert.equal(JSON.parse(Buffer.from(updateElement(moved,pageID,noteID,null).resources[key],'base64')).strokes.length,0);
  assert.equal(JSON.parse(Buffer.from(removeInk(moved,pageID,[ink.strokes[0].id]).resources[key],'base64')).strokes.length,0);
  assert.equal(JSON.parse(Buffer.from(archive.resources[key],'base64')).strokes.length,1);
});

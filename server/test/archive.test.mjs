import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { editNotebook, newBlankPage, validateArchive } from '../archive.mjs';
const noteID = 'e1dfd123-1234-4abc-8def-0123456789ab';
const folderID = 'c1dfd123-1234-4abc-8def-0123456789ab';
function archive() {
  const { page, drawing } = newBlankPage(noteID, 0);
  return { version: 2, note: { id: noteID, folderID, title: 'Example', pageIDs: [page.id], createdAt: 0, updatedAt: 0 }, pages: [page], resources: { [page.drawingResourceID]: drawing } };
}
test('metadata edit preserves the original and all opaque content', () => {
  const original = archive(); const copy = editNotebook(original, { title: 'New', favorite: true });
  assert.equal(original.note.title, 'Example'); assert.equal(copy.note.title, 'New');
  assert.deepEqual(copy.pages, original.pages); assert.deepEqual(copy.resources, original.resources);
});
test('reject broken page references and unsafe resources', () => {
  const value = archive(); value.note.pageIDs = [noteID]; assert.throws(() => validateArchive(value));
  const other = archive(); other.resources['../secrets'] = 'AA=='; assert.throws(() => validateArchive(other));
});
test('reject malformed ink before publishing or rendering it', () => {
  const value=archive(), key=value.pages[0].drawingResourceID;
  value.resources[key]=Buffer.from('{"inkSchemaVersion":2,"strokes":[{"id":"bad"}]}').toString('base64');
  assert.throws(()=>validateArchive(value),/stroke/);
  const cyclic=archive(); cyclic.pages[0].elements=[{id:noteID,kind:'stickyNote',x:0,y:0,width:100,height:100,text:'',parentID:noteID}];
  assert.throws(()=>validateArchive(cyclic),/parent/);
});

import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { existsSync, readFileSync } from 'node:fs';
import { validateArchive } from '../archive.mjs';
import { addBlankPage, addElement, addInk, editPage, removeInk, reorderPages, searchArchive, updateElement } from '../operations.mjs';
import { NotebookRepository } from '../repository.mjs';
import { renderPage } from '../render.mjs';
import { makeNodeArchive } from './fixture-builder.mjs';
import { memoryClient } from './helpers.mjs';

const fixture = name => JSON.parse(readFileSync(new URL(`../../fixtures/${name}`, import.meta.url), 'utf8'));
// Structure of a value, ignoring content: keys and types. Resource file names are data, not structure.
const shape = (value, key) => {
  if (Array.isArray(value)) return [...new Set(value.map(x => JSON.stringify(shape(x))))].sort().map(x => JSON.parse(x));
  if (value && typeof value === 'object') return key === 'resources' ? { '*': 'string' } : Object.fromEntries(Object.keys(value).sort().map(k => [k, shape(value[k], k)]));
  return value === null ? 'null' : typeof value;
};

test('the app-written reference archive is accepted, searchable, editable and renderable by the MCP code', async () => {
  assert.ok(existsSync(new URL('../../fixtures/swift-archive.json', import.meta.url)), 'run the Swift test with TEST_RUNNER_REGENERATE_FIXTURES=1 to create it');
  const swift = fixture('swift-archive.json');
  validateArchive(swift);
  assert.equal(searchArchive(swift, 'Typed page text').length, 1);
  assert.equal(searchArchive(swift, 'Remember').length, 1, 'sticky note text is searchable');
  const [first] = swift.pages, sticky = first.elements.find(e => e.kind === 'stickyNote');
  let edited = addElement(swift, first.id, { kind: 'text', x: 10, y: 10, width: 50, height: 20, text: 'From MCP' });
  edited = addInk(edited, first.id, [[5, 5], [50, 50]], 2, [0, 0, 0, 1], 'fountainPen');
  edited = updateElement(edited, first.id, sticky.id, { x: sticky.x + 10, y: sticky.y + 10 });
  edited = editPage(edited, first.id, { bookmark: false, template: 'dotted' });
  edited = reorderPages(addBlankPage(edited), [edited.pages[0].id].reverse().concat());
  validateArchive(edited);
  const ink = JSON.parse(Buffer.from(swift.resources[first.drawingResourceID], 'base64'));
  assert.ok(ink.strokes.length > 0, 'the reference page has real native ink');
  const afterRemoval = removeInk(swift, first.id, [ink.strokes[0].id]);
  assert.equal(JSON.parse(Buffer.from(afterRemoval.resources[first.drawingResourceID], 'base64')).strokes.length, ink.strokes.length - 1);
  // Survives the storage round trip exactly as the app would read it back.
  const repository = new NotebookRepository(memoryClient(), 'a1dfd123-1234-4abc-8def-0123456789ab');
  await repository.commit(swift);
  assert.deepEqual((await repository.read(swift.note.id)).archive, swift);
  // The server renderer draws the app's ink, shapes and sticky notes without throwing.
  const png = await renderPage(swift, first.id);
  assert.equal(png.subarray(0, 4).toString('hex'), '89504e47');
});

test('archives written by the MCP keep exactly the structure the app is tested to decode', async () => {
  const committed = fixture('node-archive.json'), fresh = JSON.parse(JSON.stringify(await makeNodeArchive()));
  validateArchive(committed); validateArchive(fresh);
  assert.deepEqual(shape(fresh), shape(committed), 'MCP output structure changed: run `node test/fixture-builder.mjs --write`, then make the Swift interop test pass');
});

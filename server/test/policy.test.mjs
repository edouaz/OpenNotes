import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { createServer } from '../mcp.mjs';
import { clientIDOf, createRateLimiter, originAllowed, policyFromEnv, toolAllowed, toolMode } from '../policy.mjs';
import { memoryClient } from './helpers.mjs';

const USER = 'a1dfd123-1234-4abc-8def-0123456789ab', FOLDER = 'c1dfd123-1234-4abc-8def-0123456789ab';
const names = async policy => {
  const server = createServer(memoryClient(), USER, policy), client = new Client({ name: 'test', version: '1.0.0' });
  const [a, b] = InMemoryTransport.createLinkedPair(); await Promise.all([server.connect(b), client.connect(a)]);
  return { client, tools: (await client.listTools()).tools, close: async () => { await client.close(); await server.close(); } };
};

test('default policy is read-only: write and destructive tools are not even visible', async () => {
  const { tools, close } = await names();
  const listed = tools.map(t => t.name);
  assert.ok(listed.includes('list_notebooks') && listed.includes('render_page') && listed.includes('search_notebooks'));
  for (const hidden of ['create_notebook', 'add_ink', 'import_pdf', 'update_page', 'remove_element', 'restore_revision', 'reorder_pages']) assert.ok(!listed.includes(hidden), hidden);
  assert.ok(tools.every(t => t.annotations.readOnlyHint !== false || t.name === 'render_page'));
  await close();
});

test('write permission alone hides destructive tools and refuses trashing', async () => {
  const { client, tools, close } = await names({ allowWrite: true });
  const listed = tools.map(t => t.name);
  assert.ok(listed.includes('create_notebook') && listed.includes('update_notebook'));
  for (const hidden of ['remove_element', 'remove_ink', 'reorder_pages', 'restore_revision']) assert.ok(!listed.includes(hidden), hidden);
  const created = JSON.parse((await client.callTool({ name: 'create_notebook', arguments: { title: 'T', folderID: FOLDER } })).content[0].text);
  const refused = await client.callTool({ name: 'update_notebook', arguments: { notebookID: created.notebookID, expectedRevision: created.revisionID, trashed: true } });
  assert.ok(refused.isError); assert.match(refused.content[0].text, /destructive permission/);
  await close();
});

test('destructive tools are flagged and need both permissions', async () => {
  const { tools, close } = await names({ allowWrite: true, allowDestructive: true });
  assert.equal(tools.find(t => t.name === 'remove_ink').annotations.destructiveHint, true);
  assert.equal(tools.find(t => t.name === 'create_notebook').annotations.destructiveHint, false);
  assert.equal(toolAllowed('remove_ink', { allowDestructive: true }), false, 'destructive without write is still denied');
  assert.equal(toolMode('some_future_tool'), 'write', 'unknown tools default to write, never read');
  assert.deepEqual(policyFromEnv({ ALLOW_DESTRUCTIVE: 'true' }), { allowWrite: false, allowDestructive: false });
  assert.deepEqual(policyFromEnv({ ALLOW_WRITE: 'true' }), { allowWrite: true, allowDestructive: false });
  await close();
});

test('rate limiter blocks after the limit and recovers when the window passes', () => {
  let now = 0; const limit = createRateLimiter(2, 60_000, () => now);
  assert.equal(limit('u'), 0); assert.equal(limit('u'), 0);
  assert.ok(limit('u') > 0); assert.equal(limit('other'), 0);
  now = 61_000; assert.equal(limit('u'), 0);
});

test('origin and OAuth-client helpers', () => {
  assert.ok(originAllowed(undefined, ['https://a'])); assert.ok(originAllowed('https://a', ['https://a'])); assert.ok(!originAllowed('https://b', ['https://a']));
  const token = payload => `x.${Buffer.from(JSON.stringify(payload)).toString('base64url')}.y`;
  assert.equal(clientIDOf(token({ client_id: 'abc' })), 'abc');
  assert.equal(clientIDOf(token({ role: 'authenticated' })), null);
  assert.equal(clientIDOf('garbage'), null);
});

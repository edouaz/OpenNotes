import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const run = (args, env = {}) => spawnSync(process.execPath, ['cli.mjs', ...args], { encoding: 'utf8', env: { PATH: process.env.PATH, OPENNOTES_HOME: mkdtempSync(join(tmpdir(), 'on-')), OPENNOTES_SUPABASE_URL: 'https://x.supabase.co', OPENNOTES_SUPABASE_KEY: 'sb_publishable_x', ...env } });

test('cli refuses to start without a publishable key', () => {
  const r = run(['documents', 'list'], { OPENNOTES_SUPABASE_KEY: 'sb_secret_nope' });
  assert.equal(r.status, 1); assert.match(r.stderr, /publishable key/);
});
test('cli requires a stored session for every data command, including mcp serve', () => {
  for (const args of [['documents', 'list'], ['sync', 'status'], ['mcp', 'serve']]) { const r = run(args); assert.equal(r.status, 1); assert.match(r.stderr, /Not signed in/); }
});
test('unknown command prints usage', () => { assert.match(run(['nope']).stderr, /Usage: opennote/); });

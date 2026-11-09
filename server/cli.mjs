#!/usr/bin/env node
// OpenNote CLI: read-only by default. Same repository/MCP code as the HTTP service; talks to Supabase with the user's own session (RLS), never a service key.
import { mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { createClient } from '@supabase/supabase-js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { createServer } from './mcp.mjs';
import { NotebookRepository } from './repository.mjs';

const dir = process.env.OPENNOTES_HOME ?? join(homedir(), '.opennotes'), file = join(dir, 'session.json');
// ponytail: session in a 0600 file; move to the macOS Keychain if the machine is shared.
const url = process.env.OPENNOTES_SUPABASE_URL, key = process.env.OPENNOTES_SUPABASE_KEY;
const fail = message => { console.error(message); process.exit(1); };
if (!url || !key?.startsWith('sb_publishable_')) fail('Set OPENNOTES_SUPABASE_URL and OPENNOTES_SUPABASE_KEY (the publishable key, never a service key).');
const client = createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } });

const save = async session => { await mkdir(dir, { recursive: true, mode: 0o700 }); await writeFile(file, JSON.stringify({ access_token: session.access_token, refresh_token: session.refresh_token }), { mode: 0o600 }); };
async function ask(prompt, hidden) {
  const rl = createInterface({ input: process.stdin, output: process.stderr, terminal: true });
  if (hidden) rl._writeToOutput = text => { if (text.includes(prompt)) process.stderr.write(text); };
  return new Promise(resolve => rl.question(prompt, answer => { rl.close(); if (hidden) process.stderr.write('\n'); resolve(answer); }));
}
async function login() {
  const email = process.argv[3] ?? await ask('Email: '), password = process.env.OPENNOTES_PASSWORD ?? await ask('Password: ', true);
  const { data, error } = await client.auth.signInWithPassword({ email, password });
  if (error) fail(`Login failed: ${error.message}`);
  await save(data.session); console.error(`Signed in as ${data.user.email}`);
}
async function session() {
  let stored; try { stored = JSON.parse(await readFile(file, 'utf8')); } catch { fail('Not signed in. Run: opennote login <email>'); }
  const { data, error } = await client.auth.setSession(stored);
  if (error || !data.session) fail('Session expired. Run: opennote login <email>');
  await save(data.session); // refresh tokens rotate
  return { user: data.user, client: createClient(url, key, { accessToken: async () => data.session.access_token, auth: { persistSession: false } }) };
}
const print = value => console.log(JSON.stringify(value, null, 2));
const flag = name => { const i = process.argv.indexOf(name); return i < 0 ? undefined : process.argv.splice(i, 2)[1]; };
const has = name => { const i = process.argv.indexOf(name); if (i >= 0) process.argv.splice(i, 1); return i >= 0; };

const allowWrite = has('--allow-write'), [, , cmd, sub, a, b] = process.argv;
if (cmd === 'login') await login();
else if (cmd === 'logout') { await rm(file, { force: true }); console.error('Signed out (local session removed).'); }
else if (cmd === 'documents' && sub === 'list') {
  const { client: c } = await session();
  let request = c.from('notebook_meta').select('notebook_id,title,folder_id,page_count,updated_at').eq('trashed', false).eq('purged', false);
  if (a) request = request.ilike('title', `%${a.replace(/[\\%_]/g, '\\$&')}%`);
  const { data, error } = await request.order('updated_at', { ascending: false }).limit(100);
  if (error) fail(error.message); print(data);
} else if (cmd === 'documents' && sub === 'get' && a) {
  const { client: c, user } = await session(), { archive, revisionID } = await new NotebookRepository(c, user.id).read(a);
  print({ revisionID, archive: { ...archive, resources: Object.fromEntries(Object.entries(archive.resources).map(([k, v]) => [k, { omittedBytes: Buffer.byteLength(v, 'base64') }])) } });
} else if (cmd === 'documents' && sub === 'export' && a && b) {
  const { client: c, user } = await session(), { archive } = await new NotebookRepository(c, user.id).read(a);
  await writeFile(b, JSON.stringify(archive)); console.error(`Wrote ${b}`);
} else if (cmd === 'sync' && sub === 'status') {
  const { client: c } = await session();
  const [heads, meta] = await Promise.all([c.from('notebook_heads').select('notebook_id', { count: 'exact', head: true }), c.from('notebook_meta').select('updated_at').order('updated_at', { ascending: false }).limit(1)]);
  print({ notebooks: heads.count, latestUpdate: meta.data?.[0]?.updated_at ?? null, error: heads.error?.message ?? meta.error?.message });
} else if (cmd === 'mcp' && sub === 'serve') {
  const { client: c, user } = await session();
  await createServer(c, user.id, { allowWrite, allowDestructive: false }).connect(new StdioServerTransport()); // stdout is the protocol: log to stderr only
  console.error(`opennote mcp: ${allowWrite ? 'read+write' : 'read-only'}`);
} else fail('Usage: opennote login <email> | logout | documents list [query] | documents get <id> | documents export <id> <file> | sync status | mcp serve [--allow-write]');

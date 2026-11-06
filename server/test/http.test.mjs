import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { createServer } from 'node:net';

test('HTTP discovery is public and MCP requires a bearer token', async () => {
  const probe = createServer(); probe.listen(0, '127.0.0.1'); await once(probe, 'listening');
  const port = probe.address().port; await new Promise(resolve => probe.close(resolve));
  const proc = spawn(process.execPath, ['index.mjs'], { cwd: new URL('..', import.meta.url), env: { ...process.env, PORT: String(port), PUBLIC_ORIGIN: 'https://notes.example', SUPABASE_URL: 'https://project.supabase.co', SUPABASE_PUBLISHABLE_KEY: 'sb_publishable_example' } });
  try {
    let response;
    for (let i = 0; i < 500; i++) {
      try { response = await fetch(`http://127.0.0.1:${port}/.well-known/oauth-protected-resource/mcp`); break; }
      catch { await new Promise(resolve => setTimeout(resolve, 20)); }
    }
    assert.ok(response); assert.deepEqual((await response.json()).authorization_servers, ['https://project.supabase.co/auth/v1']);
    const consent = await fetch(`http://127.0.0.1:${port}/oauth/consent?authorization_id=test`);
    assert.match(consent.headers.get('content-security-policy'), /connect-src 'self' https:\/\/project\.supabase\.co/);
    assert.match(await consent.text(), /src=\"\/oauth\/consent\.js\"/);
    const config = await fetch(`http://127.0.0.1:${port}/oauth/config`);
    assert.equal((await config.json()).supabaseURL, 'https://project.supabase.co');
    const welcome = await fetch(`http://127.0.0.1:${port}/`);
    assert.equal(welcome.status, 200);
    assert.match(await welcome.text(), /OpenNotes authorization/);
    const rootMetadata = await fetch(`http://127.0.0.1:${port}/.well-known/oauth-protected-resource`);
    assert.equal(rootMetadata.status, 200);
    const getDenied = await fetch(`http://127.0.0.1:${port}/mcp`);
    assert.equal(getDenied.status, 401);
    assert.match(getDenied.headers.get('www-authenticate'), /resource_metadata/);
    const foreign = await fetch(`http://127.0.0.1:${port}/mcp`, { method: 'POST', headers: { Origin: 'https://evil.example' } });
    assert.equal(foreign.status, 403);
    const denied = await fetch(`http://127.0.0.1:${port}/mcp`, { method: 'POST' });
    assert.equal(denied.status, 401); assert.match(denied.headers.get('www-authenticate'), /resource_metadata/);
  } finally { proc.kill(); }
});

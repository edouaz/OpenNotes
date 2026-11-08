import { randomUUID } from 'node:crypto';
import { createServer as createHTTPServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { createClient } from '@supabase/supabase-js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { createServer } from './mcp.mjs';
import { clientIDOf, createRateLimiter, originAllowed, policyFromEnv } from './policy.mjs';

const supabaseURL = process.env.SUPABASE_URL;
const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY;
const publicOrigin = process.env.PUBLIC_ORIGIN;
if (!supabaseURL || !publishableKey || !publicOrigin || !publishableKey.startsWith('sb_publishable_') || new URL(publicOrigin).origin !== publicOrigin || new URL(publicOrigin).protocol !== 'https:' || new URL(supabaseURL).protocol !== 'https:') throw new Error('Set HTTPS PUBLIC_ORIGIN, SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY');
const policy = policyFromEnv(process.env), requireOAuthClient = process.env.REQUIRE_OAUTH_CLIENT === 'true';
const allowedOrigins = [publicOrigin, ...(process.env.ALLOWED_ORIGINS ?? '').split(',').map(x => x.trim()).filter(Boolean)];
const rateLimit = createRateLimiter(Number(process.env.RATE_LIMIT_PER_MIN ?? 120)), ipLimit = createRateLimiter(Number(process.env.IP_RATE_LIMIT_PER_MIN ?? 600));
const maxBody = Number(process.env.MAX_BODY_MB ?? 8) * 1024 * 1024; // larger files go through the transfer tools
console.log(JSON.stringify({ event: 'start', write: policy.allowWrite, destructive: policy.allowDestructive, requireOAuthClient }));
const resource = `${publicOrigin}/mcp`, metadata = `${publicOrigin}/.well-known/oauth-protected-resource/mcp`;
const json = (res, status, object) => { res.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(object)); };
const consentHTML = await readFile(new URL('./public/consent.html', import.meta.url));
const consentJS = await readFile(new URL('./public/consent.js', import.meta.url));
const library = await readFile(new URL('./node_modules/@supabase/supabase-js/dist/umd/supabase.js', import.meta.url));

createHTTPServer(async (req, res) => {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  try {
    const path = new URL(req.url, publicOrigin).pathname;
    if (req.method === 'GET' && ['/.well-known/oauth-protected-resource/mcp', '/.well-known/oauth-protected-resource'].includes(path)) return json(res, 200, { resource, authorization_servers: [`${supabaseURL}/auth/v1`], bearer_methods_supported: ['header'] });
    if (req.method === 'GET' && path === '/oauth/config') return json(res, 200, { supabaseURL, publishableKey });
    if (req.method === 'GET' && ['/', '/oauth/consent', '/oauth/consent.js', '/oauth/supabase.js'].includes(path)) {
      res.setHeader('Content-Security-Policy', `default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self' ${new URL(supabaseURL).origin}; form-action 'self'; base-uri 'none'; frame-ancestors 'none'`);
      res.setHeader('Cache-Control', 'no-store');
      res.setHeader('Content-Type', path.endsWith('.js') ? 'text/javascript; charset=utf-8' : 'text/html; charset=utf-8');
      return res.end(path.endsWith('consent.js') ? consentJS : path.endsWith('supabase.js') ? library : consentHTML);
    }
    if (path !== '/mcp') return json(res, 404, { error: 'Not found' });
    if (!originAllowed(req.headers.origin, allowedOrigins)) return json(res, 403, { error: 'Origin not allowed' });
    // Before the (network) token check, so floods of bad tokens cannot exhaust Supabase calls.
    const ipWait = ipLimit((req.headers['x-forwarded-for'] ?? req.socket.remoteAddress ?? '').toString().split(',')[0].trim());
    if (ipWait) { res.setHeader('Retry-After', String(ipWait)); return json(res, 429, { error: 'Too many requests' }); }
    const match = /^Bearer ([^\s]+)$/.exec(req.headers.authorization ?? '');
    if (!match) { res.setHeader('WWW-Authenticate', `Bearer resource_metadata="${metadata}"`); return json(res, 401, { error: 'Authentication required' }); }
    const token = match[1];
    const verifier = createClient(supabaseURL, publishableKey, { auth: { persistSession: false } });
    const { data, error } = await verifier.auth.getUser(token);
    if (error || !data.user) { res.setHeader('WWW-Authenticate', `Bearer error="invalid_token", resource_metadata="${metadata}"`); return json(res, 401, { error: 'Invalid token' }); }
    if (requireOAuthClient && !clientIDOf(token)) { res.setHeader('WWW-Authenticate', `Bearer error="invalid_token", resource_metadata="${metadata}"`); return json(res, 401, { error: 'An OAuth client token is required' }); }
    const wait = rateLimit(data.user.id);
    if (wait) { res.setHeader('Retry-After', String(wait)); return json(res, 429, { error: 'Too many requests' }); }
    if (req.method !== 'POST') { res.writeHead(405, { Allow: 'POST' }); return res.end(); }
    const client = createClient(supabaseURL, publishableKey, { accessToken: async () => token, auth: { persistSession: false } });
    let bytes = 0, chunks = [];
    for await (const chunk of req) { bytes += chunk.length; if (bytes > maxBody) return json(res, 413, { error: 'Request too large' }); chunks.push(chunk); }
    let body; try { body = JSON.parse(Buffer.concat(chunks).toString()); } catch { return json(res, 400, { error: 'Invalid JSON' }); }
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
    const server = createServer(client, data.user.id, policy, { requestID: String(req.headers['x-vercel-id'] ?? randomUUID()) }); res.on('close', () => { void transport.close(); void server.close(); });
    await server.connect(transport); await transport.handleRequest(req, res, body);
  } catch { if (!res.headersSent) json(res, 500, { error: 'Server error' }); else res.end(); }
}).listen(Number(process.env.PORT ?? 3000));

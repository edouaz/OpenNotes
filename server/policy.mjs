// Access policy for agents. Default-deny: a tool not listed here is treated as a write tool.
export const READ_TOOLS = new Set(['list_folders', 'list_notebooks', 'get_notebook', 'get_history', 'get_folder_history', 'search_notebooks', 'search_notebook', 'export_pdf', 'download_notebook', 'download_pdf', 'remove_transfer']);
// Remove or overwrite content (recoverable from history, but never silently): need an explicit, separate permission.
export const DESTRUCTIVE_TOOLS = new Set(['remove_element', 'remove_ink', 'reorder_pages', 'restore_revision']);

export function toolMode(name) { return READ_TOOLS.has(name) ? 'read' : DESTRUCTIVE_TOOLS.has(name) ? 'destructive' : 'write'; }
export function toolAllowed(name, { allowWrite = false, allowDestructive = false } = {}) {
  const mode = toolMode(name);
  return mode === 'read' || (allowWrite && (mode === 'write' || allowDestructive));
}
export const policyFromEnv = env => ({ allowWrite: env.ALLOW_WRITE === 'true', allowDestructive: env.ALLOW_WRITE === 'true' && env.ALLOW_DESTRUCTIVE === 'true' });

// Sliding window per key. Returns 0 when allowed, otherwise the seconds to wait.
export function createRateLimiter(limit, windowMs = 60_000, now = Date.now) {
  const hits = new Map();
  return key => {
    const t = now(), recent = (hits.get(key) ?? []).filter(x => t - x < windowMs);
    if (recent.length >= limit) { hits.set(key, recent); return Math.max(1, Math.ceil((windowMs - (t - recent[0])) / 1000)); }
    recent.push(t); hits.set(key, recent); return 0;
  };
}

// Browsers always send Origin; MCP clients do not. Rejecting unknown browser origins blocks DNS-rebinding style calls.
export const originAllowed = (origin, allowed) => !origin || allowed.includes(origin);

// Call only after the token was validated by Supabase: the payload is then trusted, not re-verified here.
// OAuth-client tokens carry client_id; password-login session tokens (the app's own) do not.
export function clientIDOf(token) {
  try { return JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString()).client_id ?? null; } catch { return null; }
}

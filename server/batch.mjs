import { createHash } from 'node:crypto';

// Pure helpers for import_pdfs. The server is stateless (one HTTP request per tool call), so a resumable import keeps no
// state of its own: every ID below is derived from (user, importID, relative path). Replaying the same manifest therefore
// addresses the same folders, uploads and notebooks, and "already created by this operation" is a lookup by ID,
// never a guess from titles (two different versions of "Cours.pdf" are two imports).
export const MAX_FILES = 100, MAX_DEPTH = 8;

export function derivedID(userID, importID, kind, path) {
  const h = createHash('sha256').update(`${userID.toLowerCase()}\0${importID.toLowerCase()}\0${kind}\0${path}`).digest();
  h[6] = (h[6] & 0x0f) | 0x50; h[8] = (h[8] & 0x3f) | 0x80;   // well-formed v5-style UUID
  const x = h.subarray(0, 16).toString('hex');
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20)}`;
}

// Validates the manifest and expands it. Throws "Invalid …" (INVALID_ARGUMENT) naming the offending path.
export function planImport(userID, importID, files) {
  if (!files.length || files.length > MAX_FILES) throw new Error(`Invalid manifest: 1 to ${MAX_FILES} files per call`);
  const seen = new Set(), folders = new Map(), entries = [];
  for (const file of files) {
    const path = file.path.normalize('NFC');   // macOS hands out NFD names; a resume must hash the same bytes
    const segments = path.split('/'), name = segments.at(-1);
    if (path.startsWith('/') || path.includes('\\') || /[\u0000-\u001f\u007f]/.test(path) || segments.some(s => !s.trim() || s === '.' || s === '..' || s.length > 255))
      throw new Error(`Invalid path "${file.path}": use a relative path with "/" separators, no empty, "." or ".." segment`);
    if (segments.length - 1 > MAX_DEPTH) throw new Error(`Invalid path "${file.path}": more than ${MAX_DEPTH} folder levels`);
    if (!/\.pdf$/i.test(name)) throw new Error(`Invalid path "${file.path}": only .pdf files are imported`);
    if (seen.has(path)) throw new Error(`Invalid manifest: duplicate path "${path}"`);
    seen.add(path);
    let parent = null;
    for (let depth = 1; depth < segments.length; depth++) {
      const dir = segments.slice(0, depth).join('/');
      if (!folders.has(dir)) folders.set(dir, { path: dir, name: segments[depth - 1], depth, id: derivedID(userID, importID, 'folder', dir), parentPath: parent });
      parent = dir;
    }
    const notebookID = derivedID(userID, importID, 'notebook', path);
    entries.push({ path, title: file.title ?? (name.replace(/\.pdf$/i, '').trim() || name), notebookID, folderPath: parent, uploadPath: `${userID.toLowerCase()}/${notebookID}/${derivedID(userID, importID, 'upload', path)}.bin` });
  }
  return { entries, folders: [...folders.values()].sort((a, b) => a.depth - b.depth) };
}

// Runs `worker` over `items` with at most `limit` in flight; stops starting new items once `stop()` is true.
// Items never started are returned as `skipped` so the caller can report them as still queued.
export async function pool(items, limit, worker, stop = () => false) {
  const skipped = []; let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) { const item = items[next++]; if (stop()) skipped.push(item); else await worker(item); }
  }));
  return skipped;
}

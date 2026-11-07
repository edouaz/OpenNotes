import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';
import { randomUUID } from 'node:crypto';
import { editNotebook, swiftNow } from './archive.mjs';
import { createNotebook, addBlankPage, addElement, searchArchive, importPDF, addImage, addInk, editPage, reorderPages, updateElement, removeInk } from './operations.mjs';
import { NotebookRepository } from './repository.mjs';
import { exportPDF, renderPage, pageWords, matchRects } from './render.mjs';
import { toolAllowed, toolMode } from './policy.mjs';
const uuid = z.string().uuid();
const response = value => { const text = JSON.stringify(value); if (Buffer.byteLength(JSON.stringify(text)) > 3 * 1024 * 1024) throw new Error('Response too large; use download_notebook or download_pdf when applicable'); return { content: [{ type: 'text', text }] }; };

// The caller must authenticate and pass a user-scoped Supabase client.
// Read-only unless the operator grants write (and, separately, destructive) permission.
export function createServer(client, userID, policy = {}) {
  const server = new McpServer({ name: 'opennotes', version: '0.1.0' });
  const repository = new NotebookRepository(client, userID);
  const tool = (name, description, inputSchema, run) => {
    if (!toolAllowed(name, policy)) return; // not registered: the agent cannot even see it
    const mode = toolMode(name);
    return server.registerTool(name, { description, inputSchema, annotations: { readOnlyHint: mode === 'read', destructiveHint: mode === 'destructive' } }, async args => response(await run(args)));
  };
  const trashAllowed = () => { if (!(policy.allowWrite && policy.allowDestructive)) throw new Error('Trashing requires destructive permission'); };
  tool('list_folders', 'List folders, including their parent and trash state.', { limit: z.number().int().min(1).max(100).default(50), offset: z.number().int().min(0).default(0) }, async ({ limit, offset }) => {
    const { data, error } = await client.from('cloud_folders').select('id,name,parent_id,deleted_at,updated_at').order('id').range(offset, offset + limit - 1);
    if (error) throw error; return data;
  }, true);
  tool('create_folder', 'Create a folder, optionally nested in a parent folder.', { name: z.string().trim().min(1).max(255), parentID: uuid.nullable().default(null) }, async ({ name, parentID }) => {
    const { data, error } = await client.from('cloud_folders').insert({ id: crypto.randomUUID(), name, parent_id: parentID }).select('id,name,parent_id,deleted_at,updated_at').single();
    if (error) throw error; return data;
  });
  tool('update_folder', 'Rename, move, trash or restore a folder.', { folderID: uuid, name: z.string().trim().min(1).max(255).optional(), parentID: uuid.nullable().optional(), trashed: z.boolean().optional(), expectedUpdatedAt: z.string().datetime({ offset: true }) }, async ({ folderID, name, parentID, trashed, expectedUpdatedAt }) => {
    if (trashed === true) trashAllowed();
    const changes = { updated_at: new Date().toISOString() };
    if (name !== undefined) changes.name = name;
    if (parentID !== undefined) changes.parent_id = parentID;
    if (trashed !== undefined) changes.deleted_at = trashed ? new Date().toISOString() : null;
    const { data, error } = await client.from('cloud_folders').update(changes).eq('id', folderID).eq('updated_at', expectedUpdatedAt).select('id,name,parent_id,deleted_at,updated_at').single();
    if (error) throw error; return data;
  });
  const escapeLike = text => text.replace(/[\\%_]/g, '\\$&');
  tool('list_notebooks', 'List notebooks with title, folder, page count and dates, newest first, without downloading them. Hides trashed notebooks unless includeTrashed. Notebooks saved by an app older than the metadata index appear after the app syncs once.', {
    query: z.string().trim().min(1).max(200).optional(), folderID: uuid.optional(), updatedAfter: z.string().datetime({ offset: true }).optional(), includeTrashed: z.boolean().default(false),
    limit: z.number().int().min(1).max(100).default(50), offset: z.number().int().min(0).default(0),
  }, async ({ query, folderID, updatedAfter, includeTrashed, limit, offset }) => {
    let request = client.from('notebook_meta').select('notebook_id,revision_id,title,folder_id,page_count,updated_at,trashed,favorite');
    if (!includeTrashed) request = request.eq('trashed', false).eq('purged', false);
    if (folderID) request = request.eq('folder_id', folderID);
    if (updatedAfter) request = request.gt('updated_at', updatedAfter);
    if (query) request = request.ilike('title', `%${escapeLike(query)}%`);
    const { data, error } = await request.order('updated_at', { ascending: false }).order('notebook_id').range(offset, offset + limit - 1);
    if (error) throw error; return data;
  });
  const pageText = page => [page.text, page.recognizedText, page.pdfText?.text, page.ocrText?.text, ...(page.elements ?? []).map(item => item.text)].filter(x => typeof x === 'string' && x).join('\n');
  tool('get_notebook', 'Read a notebook: note metadata, pages and annotations. Resources (PDF/image/ink bytes) are left out unless includeResources is true; prefer get_notebook_outline, get_page_text or render_page for large notebooks.', { notebookID: uuid, includeResources: z.boolean().default(false) }, async ({ notebookID, includeResources }) => {
    const { archive, revisionID } = await repository.read(notebookID);
    if (includeResources) return { archive, revisionID };
    return { archive: { ...archive, resources: Object.fromEntries(Object.entries(archive.resources).map(([name, encoded]) => [name, { omittedBytes: Buffer.byteLength(encoded, 'base64') }])) }, revisionID };
  });
  tool('get_notebook_outline', 'Cheap overview of a notebook: title, folder, and for every page its ID, paper, bookmark, PDF page, annotation count and amount of text.', { notebookID: uuid }, async ({ notebookID }) => {
    const { archive, revisionID } = await repository.read(notebookID);
    return { revisionID, title: archive.note.title, folderID: archive.note.folderID, trashed: archive.note.deletedAt != null, favorite: archive.note.favorite === true,
      pages: archive.pages.map((page, index) => ({ index, pageID: page.id, template: page.template, bookmark: page.bookmark === true, pdfPage: page.backgroundID && page.pdfIndex != null ? page.pdfIndex : null, annotations: (page.elements ?? []).length, textChars: pageText(page).length })) };
  });
  tool('get_page_text', 'Read the extracted text (typed text, PDF text, OCR, annotation text) of selected pages only. Handwriting is not transcribed; use render_page to see it.', { notebookID: uuid, pageIDs: z.array(uuid).min(1).max(20).optional(), maxCharsPerPage: z.number().int().min(100).max(100000).default(20000) }, async ({ notebookID, pageIDs, maxCharsPerPage }) => {
    const { archive, revisionID } = await repository.read(notebookID), wanted = pageIDs && new Set(pageIDs.map(id => id.toLowerCase()));
    if (wanted && [...wanted].some(id => !archive.pages.some(page => page.id.toLowerCase() === id))) throw new Error('Page not found');
    const pages = archive.pages.map((page, index) => ({ page, index })).filter(({ page }) => !wanted || wanted.has(page.id.toLowerCase())).slice(0, wanted ? 20 : 20)
      .map(({ page, index }) => { const text = pageText(page); return { index, pageID: page.id, text: text.slice(0, maxCharsPerPage), truncated: text.length > maxCharsPerPage }; });
    return { revisionID, pages, ...(!wanted && archive.pages.length > 20 ? { note: 'Only the first 20 pages are returned; pass pageIDs for others.' } : {}) };
  });
  tool('create_notebook', 'Create a notebook containing one blank page in a folder.', { title: z.string().trim().min(1).max(1000), folderID: uuid }, async ({ title, folderID }) => {
    const archive = createNotebook(title, folderID); return { notebookID: archive.note.id, revisionID: await repository.commit(archive) };
  });
  tool('update_notebook', 'Update notebook metadata; pass the revision last read to prevent overwriting a concurrent change.', {
    notebookID: uuid, expectedRevision: uuid, title: z.string().trim().min(1).max(1000).optional(), favorite: z.boolean().optional(), folderID: uuid.optional(), trashed: z.boolean().optional(),
  }, async ({ notebookID, expectedRevision, trashed, ...changes }) => {
    if (trashed === true) trashAllowed();
    const { archive, revisionID } = await repository.read(notebookID);
    if (revisionID !== expectedRevision) throw new Error('Notebook revision conflict');
    if (trashed !== undefined) changes.deletedAt = trashed ? swiftNow() : null;
    return { revisionID: await repository.commit(editNotebook(archive, changes), revisionID) };
  });
  tool('add_page', 'Append a blank page, requiring the current revision.', { notebookID: uuid, expectedRevision: uuid }, async ({ notebookID, expectedRevision }) => {
    const { archive, revisionID } = await repository.read(notebookID);
    if (revisionID !== expectedRevision) throw new Error('Notebook revision conflict');
    const edited = addBlankPage(archive); return { pageID: edited.pages.at(-1).id, revisionID: await repository.commit(edited, revisionID) };
  });
  tool('add_element', 'Add a text, highlight, shape or sticky note to a page using document coordinates.', {
    notebookID: uuid, pageID: uuid, expectedRevision: uuid, kind: z.enum(['text', 'rectangle', 'ellipse', 'line', 'arrow', 'stickyNote', 'highlight']),
    x: z.number().nonnegative(), y: z.number().nonnegative(), width: z.number().positive().max(20000), height: z.number().positive().max(20000), text: z.string().max(100000).default(''), strokeColorHex:z.string().regex(/^#[0-9a-f]{6}$/i).optional(), fillColorHex:z.string().regex(/^#[0-9a-f]{6}$/i).optional(), textColorHex:z.string().regex(/^#[0-9a-f]{6}$/i).optional(), strokeWidth:z.number().min(.5).max(32).optional(), parentID:uuid.optional(),
  }, async ({ notebookID, pageID, expectedRevision, ...element }) => {
    const { archive, revisionID } = await repository.read(notebookID);
    if (revisionID !== expectedRevision) throw new Error('Notebook revision conflict');
    const edited = addElement(archive, pageID, element);
    return { elementID: edited.pages.find(page => page.id.toLowerCase() === pageID.toLowerCase()).elements.at(-1).id, revisionID: await repository.commit(edited, revisionID) };
  });
  tool('mark_text', 'Highlight, box or underline every occurrence of a phrase on a page (PDF text or typed text) without guessing coordinates. Handwriting is not searchable. Returns the created element IDs; call get_page_text first to pick an exact phrase.', {
    notebookID: uuid, pageID: uuid, expectedRevision: uuid, query: z.string().trim().min(1).max(500), style: z.enum(['highlight', 'box', 'underline']).default('highlight'),
    colorHex: z.string().regex(/^#[0-9a-f]{6}$/i).optional(), occurrence: z.number().int().min(1).optional().describe('Only mark the Nth occurrence; all occurrences when omitted'),
  }, async ({ notebookID, pageID, expectedRevision, query, style, colorHex, occurrence }) => {
    const { archive, revisionID } = await repository.read(notebookID);
    if (revisionID !== expectedRevision) throw new Error('Notebook revision conflict');
    let matches = matchRects(await pageWords(archive, pageID), query);
    if (occurrence) matches = matches.slice(occurrence - 1, occurrence);
    if (!matches.length) throw new Error('Text not found on this page');
    const pad = 2, rects = matches.flat().map(r => ({ x: Math.max(0, r.x - pad), y: Math.max(0, r.y - pad), width: r.width + 2 * pad, height: r.height + 2 * pad }));
    const element = r => style === 'highlight' ? { kind: 'highlight', ...r, fillColorHex: colorHex ?? '#FFE600' }
      : style === 'box' ? { kind: 'rectangle', ...r, strokeColorHex: colorHex ?? '#E5484D', strokeWidth: 2 }
      : { kind: 'line', x: r.x, y: r.y + r.height, width: r.width, height: 0.5, strokeColorHex: colorHex ?? '#E5484D', strokeWidth: 2 };
    // ponytail: one box per line; a multi-line phrase boxed as several rectangles, not one outline
    let edited = archive; const elementIDs = [];
    for (const r of rects) { edited = addElement(edited, pageID, element(r)); elementIDs.push(edited.pages.find(p => p.id.toLowerCase() === pageID.toLowerCase()).elements.at(-1).id); }
    return { matches: matches.length, elementIDs, revisionID: await repository.commit(edited, revisionID) };
  });
  const transferPath = notebookID => `${userID.toLowerCase()}/${notebookID.toLowerCase()}/${randomUUID()}.bin`;
  const storage = () => client.storage.from('mcp-transfers');
  const downloadTransfer = async (notebookID, path) => {
    if (!new RegExp(`^${userID.toLowerCase()}/${notebookID.toLowerCase()}/[a-f0-9-]{36}\\.bin$`).test(path)) throw new Error('Invalid transfer path');
    const { data, error } = await storage().download(path); if (error) throw error;
    return Buffer.from(await data.arrayBuffer());
  };
  const signedDownload = async (notebookID, bytes) => {
    const path = transferPath(notebookID);
    const { error } = await storage().upload(path, bytes, { contentType: 'application/octet-stream', upsert: false }); if (error) throw error;
    const { data, error: signedError } = await storage().createSignedUrl(path, 300); if (signedError) { await storage().remove([path]); throw signedError; }
    return { path, url: data.signedUrl, expiresInSeconds: 300 };
  };
  tool('create_upload', 'Create a private upload URL for a PDF or image too large for an MCP request. PUT bytes with Content-Type application/octet-stream; use the returned path with the corresponding import tool.', {notebookID:uuid}, async ({notebookID}) => {
    await repository.read(notebookID);
    const path = transferPath(notebookID), {data,error} = await storage().createSignedUploadUrl(path); if (error) throw error;
    return {path, url:data.signedUrl};
  });
  tool('import_uploaded_pdf', 'Append pages from a PDF uploaded with create_upload.', {notebookID:uuid,expectedRevision:uuid,path:z.string().max(200)}, async ({notebookID,expectedRevision,path}) => {
    const {archive,revisionID} = await repository.read(notebookID); if (revisionID !== expectedRevision) throw new Error('Notebook revision conflict');
    const edited = await importPDF(archive, await downloadTransfer(notebookID,path));
    const nextRevision = await repository.commit(edited,revisionID);
    let cleanupRequired; try { const {error} = await storage().remove([path]); if (error) cleanupRequired = path; } catch { cleanupRequired = path; }
    return {addedPages:edited.pages.length-archive.pages.length,revisionID:nextRevision,...(cleanupRequired ? {cleanupRequired} : {})};
  });
  tool('add_uploaded_image', 'Insert a PNG or JPEG uploaded with create_upload.', {notebookID:uuid,expectedRevision:uuid,pageID:uuid,path:z.string().max(200),x:z.number().nonnegative(),y:z.number().nonnegative(),width:z.number().positive(),height:z.number().positive()}, async ({notebookID,expectedRevision,pageID,path,...rect}) => {
    const {archive,revisionID} = await repository.read(notebookID); if (revisionID !== expectedRevision) throw new Error('Notebook revision conflict');
    const nextRevision = await repository.commit(await addImage(archive,pageID,await downloadTransfer(notebookID,path),rect),revisionID);
    let cleanupRequired; try { const {error} = await storage().remove([path]); if (error) cleanupRequired = path; } catch { cleanupRequired = path; }
    return {revisionID:nextRevision,...(cleanupRequired ? {cleanupRequired} : {})};
  });
  tool('remove_transfer', 'Delete a previously uploaded or downloaded temporary transfer after use.', {notebookID:uuid,path:z.string().max(200)}, async ({notebookID,path}) => {
    if (!new RegExp(`^${userID.toLowerCase()}/${notebookID.toLowerCase()}/[a-f0-9-]{36}\\.bin$`).test(path)) throw new Error('Invalid transfer path');
    const {error} = await storage().remove([path]); if (error) throw error; return {deleted:true};
  });
  tool('download_notebook', 'Get a short-lived private download URL for the complete notebook archive.', {notebookID:uuid}, async ({notebookID}) => {
    const {archive,revisionID} = await repository.read(notebookID);
    return {revisionID,...await signedDownload(notebookID,Buffer.from(JSON.stringify(archive)))};
  });
  tool('download_pdf', 'Get a short-lived private download URL for the exported PDF.', {notebookID:uuid}, async ({notebookID}) => signedDownload(notebookID,await exportPDF((await repository.read(notebookID)).archive)));
  tool('import_pdf', 'Append pages from a base64-encoded PDF, preserving its original as a page background.', { notebookID: uuid, expectedRevision: uuid, pdfBase64: z.string().max(70000000) }, async ({ notebookID, expectedRevision, pdfBase64 }) => {
    const { archive, revisionID } = await repository.read(notebookID);
    if (revisionID !== expectedRevision) throw new Error('Notebook revision conflict');
    const edited = await importPDF(archive, Buffer.from(pdfBase64, 'base64'));
    return { addedPages: edited.pages.length - archive.pages.length, revisionID: await repository.commit(edited, revisionID) };
  });
  tool('add_image', 'Insert a base64-encoded PNG or JPEG on a page.', { notebookID: uuid, expectedRevision: uuid, pageID: uuid, imageBase64: z.string().max(28000000), x: z.number().nonnegative(), y: z.number().nonnegative(), width: z.number().positive(), height: z.number().positive() }, async ({ notebookID, expectedRevision, pageID, imageBase64, ...rect }) => {
    const { archive, revisionID } = await repository.read(notebookID);
    if (revisionID !== expectedRevision) throw new Error('Notebook revision conflict');
    const edited = await addImage(archive, pageID, Buffer.from(imageBase64, 'base64'), rect);
    return { revisionID: await repository.commit(edited, revisionID) };
  });
  tool('add_ink', 'Draw a solid stroke through page-coordinate points.', { notebookID: uuid, expectedRevision: uuid, pageID: uuid, points: z.array(z.array(z.number()).length(2)).min(1).max(10000).describe('[[x, y], ...] in page coordinates'), width: z.number().min(.1).max(128), rgba: z.array(z.number().min(0).max(1)).length(4).describe('[red, green, blue, alpha], each 0–1'), inkType: z.enum(['pen','monoline','fountainPen','marker','pencil']).default('pen') }, async ({ notebookID, expectedRevision, pageID, points, width, rgba, inkType }) => {
    const { archive, revisionID } = await repository.read(notebookID);
    if (revisionID !== expectedRevision) throw new Error('Notebook revision conflict');
    return { revisionID: await repository.commit(addInk(archive, pageID, points, width, rgba, inkType), revisionID) };
  });
  const mutate = async (notebookID, expectedRevision, edit) => {
    const { archive, revisionID } = await repository.read(notebookID);
    if (revisionID !== expectedRevision) throw new Error('Notebook revision conflict');
    return { revisionID: await repository.commit(await edit(archive), revisionID) };
  };
  tool('update_page', 'Edit page text, paper or bookmark.', { notebookID: uuid, pageID: uuid, expectedRevision: uuid, text: z.string().max(100000).optional(), bookmark: z.boolean().optional(), template: z.enum(['blank','ruled','grid','dotted']).optional() }, ({notebookID,pageID,expectedRevision,...changes}) => mutate(notebookID,expectedRevision,a=>editPage(a,pageID,changes)));
  tool('reorder_pages', 'Set page order. Omitted pages are removed from this revision and remain recoverable in history. At least one page must remain.', {notebookID:uuid,expectedRevision:uuid,pageIDs:z.array(uuid).min(1).max(10000)}, ({notebookID,expectedRevision,pageIDs})=>mutate(notebookID,expectedRevision,a=>reorderPages(a,pageIDs)));
  tool('update_element', 'Edit text, geometry or appearance of an annotation. Moving a sticky note moves attached ink and elements; resizing never scales ink. Text edits replace rich formatting.', {
    notebookID:uuid,pageID:uuid,elementID:uuid,expectedRevision:uuid,
    changes:z.object({text:z.string().max(100000).optional(),x:z.number().nonnegative().optional(),y:z.number().nonnegative().optional(),width:z.number().positive().max(20000).optional(),height:z.number().positive().max(20000).optional(),rotation:z.number().min(-100).max(100).optional(),isLocked:z.boolean().optional(),parentID:uuid.nullable().optional(),zIndex:z.number().optional(),collapsed:z.boolean().optional(),textFontSize:z.number().min(8).max(96).optional(),textColorHex:z.string().regex(/^#[0-9a-f]{6}$/i).optional(),strokeWidth:z.number().min(.5).max(32).optional(),strokeColorHex:z.string().regex(/^#[0-9a-f]{6}$/i).optional(),fillColorHex:z.string().regex(/^#[0-9a-f]{6}$/i).nullable().optional()}).strict()
  },({notebookID,pageID,elementID,expectedRevision,changes})=>mutate(notebookID,expectedRevision,a=>updateElement(a,pageID,elementID,changes)));
  tool('remove_element', 'Remove an annotation and its attached content; recoverable through revision history.', {notebookID:uuid,pageID:uuid,elementID:uuid,expectedRevision:uuid}, ({notebookID,pageID,elementID,expectedRevision})=>mutate(notebookID,expectedRevision,a=>updateElement(a,pageID,elementID,null)));
  tool('remove_ink', 'Erase specified ink stroke IDs; recoverable through revision history.', {notebookID:uuid,pageID:uuid,expectedRevision:uuid,strokeIDs:z.array(uuid).min(1).max(10000)}, ({notebookID,pageID,expectedRevision,strokeIDs})=>mutate(notebookID,expectedRevision,a=>removeInk(a,pageID,strokeIDs)));
  tool('get_history', 'List immutable notebook revisions and their parents for audit and restoration.', {notebookID:uuid,limit:z.number().int().min(1).max(100).default(50),offset:z.number().int().nonnegative().default(0)}, async ({notebookID,limit,offset})=>{
    const {data,error}=await client.from('notebook_revisions').select('id,parent_id,checksum,created_at').eq('notebook_id',notebookID).order('created_at',{ascending:false}).range(offset,offset+limit-1); if(error) throw error; return data;
  },true);
  tool('restore_revision', 'Restore a historical notebook as a new current revision, retaining all history.', {notebookID:uuid,revisionID:uuid,expectedRevision:uuid}, ({notebookID,revisionID,expectedRevision})=>mutate(notebookID,expectedRevision,async()=>{
    const {archive:old}=await repository.readRevision(notebookID,revisionID), archive=structuredClone(old); archive.note.updatedAt=swiftNow(); return archive;
  }));
  tool('get_folder_history', 'Inspect recorded folder creations, moves, renames and trash changes.', {folderID:uuid,limit:z.number().int().min(1).max(100).default(50)}, async ({folderID,limit})=>{
    const {data,error}=await client.from('folder_audit').select('id,folder_id,before_state,after_state,created_at').eq('folder_id',folderID).order('id',{ascending:false}).limit(limit); if(error) throw error; return data;
  },true);
  tool('search_notebooks', 'Search titles and extracted text across a paginated batch of notebooks. Page renders can reveal handwriting without OCR.', {query:z.string().trim().min(1).max(500),limit:z.number().int().min(1).max(20).default(10),offset:z.number().int().nonnegative().default(0)},async({query,limit,offset})=>{
    const {data,error}=await client.from('notebook_heads').select('notebook_id').order('notebook_id').range(offset,offset+limit-1); if(error) throw error;
    return Promise.all(data.map(async head=>{const {archive,revisionID}=await repository.read(head.notebook_id); return {notebookID:head.notebook_id,title:archive.note.title,titleMatch:archive.note.title.toLocaleLowerCase().includes(query.toLocaleLowerCase()),revisionID,matches:searchArchive(archive,query)};}));
  },true);
  tool('export_pdf', 'Export notebook as a PDF. Fails explicitly for formatting that cannot be faithfully exported.', { notebookID: uuid }, async ({ notebookID }) => ({ mimeType: 'application/pdf', base64: (await exportPDF((await repository.read(notebookID)).archive)).toString('base64') }), true);
  server.registerTool('render_page', { description:'View a page as an image, including handwriting, PDF background and annotations.', inputSchema:{notebookID:uuid,pageID:uuid}, annotations:{readOnlyHint:true} }, async ({notebookID,pageID}) => ({content:[{type:'image',mimeType:'image/png',data:(await renderPage((await repository.read(notebookID)).archive,pageID)).toString('base64')}]}));
  tool('search_notebook', 'Search extracted page, OCR and element text in a notebook.', { notebookID: uuid, query: z.string().trim().min(1).max(500) }, async ({ notebookID, query }) => searchArchive((await repository.read(notebookID)).archive, query), true);
  return server;
}

import { randomUUID } from 'node:crypto';

// Swift Date encodes seconds since 2001-01-01.
export const swiftNow = () => Date.now() / 1000 - 978307200;
// Searchable summary stored next to each revision (see notebook_meta); mirrors CloudSync.metadata in the app.
export const metaOf = archive => ({ title: archive.note.title, folder_id: archive.note.folderID.toLowerCase(), page_count: archive.pages.length,
  updated_at: new Date((archive.note.updatedAt + 978307200) * 1000).toISOString(), trashed: archive.note.deletedAt != null, purged: archive.note.purgedAt != null, favorite: archive.note.favorite === true });
const id = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value);
const safeResource = name => typeof name === 'string' && name.length > 0 && name.length < 128 && name !== '.' && name !== '..' && /^[\p{L}\p{N}._ -]+$/u.test(name);

// Reject structural corruption before saving; this does not replace Swift's full archive validator.
export function validateArchive(archive) {
  if (!archive || ![1, 2].includes(archive.version) || !archive.note || !id(archive.note.id) || !id(archive.note.folderID) ||
      typeof archive.note.title !== 'string' || !Number.isFinite(archive.note.createdAt) || !Number.isFinite(archive.note.updatedAt) ||
      (archive.note.deletedAt != null && !Number.isFinite(archive.note.deletedAt)) || (archive.note.favorite != null && typeof archive.note.favorite !== 'boolean') ||
      !Array.isArray(archive.note.pageIDs) || !Array.isArray(archive.pages) ||
      archive.pages.length < 1 || archive.pages.length > 10000 || !archive.resources || typeof archive.resources !== 'object' || Array.isArray(archive.resources)) throw new Error('Invalid notebook archive');
  if (archive.note.pageIDs.some(value => !id(value)) || archive.pages.length !== archive.note.pageIDs.length || new Set(archive.note.pageIDs.map(x => x.toLowerCase())).size !== archive.pages.length) throw new Error('Invalid notebook page order');
  let bytes = 0;
  for (const [name, encoded] of Object.entries(archive.resources)) {
    if (!safeResource(name) || typeof encoded !== 'string' || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) throw new Error('Invalid resource');
    bytes += Buffer.byteLength(encoded, 'base64');
    if (bytes > 150 * 1024 * 1024) throw new Error('Archive resources exceed size limit');
  }
  for (const [index, page] of archive.pages.entries()) {
    if (!id(page.id) || page.id.toLowerCase() !== archive.note.pageIDs[index]?.toLowerCase() || page.noteID?.toLowerCase() !== archive.note.id.toLowerCase() ||
        !Object.hasOwn(archive.resources, page.drawingResourceID) || (page.backgroundID != null && !Object.hasOwn(archive.resources, page.backgroundID)) ||
        !Number.isFinite(page.width ?? 794) || !Number.isFinite(page.height ?? 1123) || (page.width ?? 794) <= 0 || (page.width ?? 794) > 20000 ||
        (page.height ?? 1123) <= 0 || (page.height ?? 1123) > 20000) throw new Error('Invalid page');
    if (!['blank','ruled','grid','dotted'].includes(page.template) || page.format !== 'a4Portrait' ||
        !Number.isInteger(page.index) || page.index < 0 || (page.pdfIndex != null && (!Number.isInteger(page.pdfIndex) || page.pdfIndex < 0)) ||
        (page.text != null && (typeof page.text !== 'string' || page.text.length > 1000000)) ||
        (page.elements != null && (!Array.isArray(page.elements) || page.elements.length > 100000))) throw new Error('Invalid page metadata');
    const elements = page.elements ?? [];
    if (new Set(elements.map(e => e.id?.toLowerCase())).size !== elements.length) throw new Error('Duplicate element ID');
    for (const element of elements) {
      if (!id(element.id) || !['text', 'image', 'rectangle', 'ellipse', 'line', 'arrow', 'stickyNote', 'highlight'].includes(element.kind) ||
          ![element.x, element.y, element.width, element.height].every(Number.isFinite) || element.x < 0 || element.y < 0 ||
          element.width <= 0 || element.height <= 0 || element.width > 20000 || element.height > 20000 ||
          element.x+element.width > (page.width ?? 794)+.01 || element.y+element.height > (page.height ?? 1123)+.01 ||
          (element.kind === 'image' && !Object.hasOwn(archive.resources, element.resource))) throw new Error('Invalid page element');
      for (const key of ['rotation','zIndex','textFontSize','strokeWidth']) if (element[key] != null && !Number.isFinite(element[key])) throw new Error('Invalid element style');
      if (typeof element.text !== 'string' || element.text.length > 100000) throw new Error('Invalid element text');
      if (element.textFontSize != null && (element.textFontSize < 8 || element.textFontSize > 96) || element.strokeWidth != null && (element.strokeWidth < .5 || element.strokeWidth > 32)) throw new Error('Invalid element style');
      for (const key of ['isLocked','collapsed']) if (element[key] != null && typeof element[key] !== 'boolean') throw new Error('Invalid element flag');
      for (const key of ['textColorHex','strokeColorHex','fillColorHex']) if (element[key] != null && !/^#[0-9a-f]{6}$/i.test(element[key])) throw new Error('Invalid color');
      if (element.richTextRTF != null && (typeof element.richTextRTF !== 'string' || Buffer.byteLength(element.richTextRTF, 'base64') > 2*1024*1024)) throw new Error('Invalid rich text');
      if (element.parentID != null) {
        const seen = new Set([element.id.toLowerCase()]); let parentID = element.parentID;
        while (parentID != null) {
          const parent = elements.find(e => e.id.toLowerCase() === parentID.toLowerCase());
          if (!parent || parent.kind !== 'stickyNote' || seen.has(parent.id.toLowerCase())) throw new Error('Invalid element parent');
          seen.add(parent.id.toLowerCase()); parentID = parent.parentID;
        }
      }
    }
    validateInk(archive.resources[page.drawingResourceID], elements);
  }
  return archive;
}

function validateInk(encoded, elements) {
  let ink;
  try { ink = JSON.parse(Buffer.from(encoded, 'base64')); } catch { throw new Error('Invalid ink document'); }
  if (![1,2].includes(ink.inkSchemaVersion) || !Array.isArray(ink.strokes) || ink.strokes.length > 100000) throw new Error('Invalid ink document');
  const pair = value => Array.isArray(value) && value.length === 2 && value.every(n => Number.isFinite(n) && Math.abs(n) <= 1000000);
  const strokeIDs = new Set(); let sampleCount = 0;
  for (const stroke of ink.strokes) {
    if (!id(stroke.id) || strokeIDs.has(stroke.id.toLowerCase())) throw new Error('Invalid stroke ID');
    strokeIDs.add(stroke.id.toLowerCase());
    if (!['pen','fountainPen','marker','pencil','monoline'].includes(stroke.ink?.inkType) ||
        !Array.isArray(stroke.ink?.rgbaSRGB) || stroke.ink.rgbaSRGB.length !== 4 || !stroke.ink.rgbaSRGB.every(n => Number.isFinite(n) && n >= 0 && n <= 1) ||
        !Array.isArray(stroke.path?.controlPoints) || stroke.path.controlPoints.length > 1000000 || !Number.isFinite(stroke.path.creationDate) ||
        !Array.isArray(stroke.rawSamples) || stroke.rawSamples.length > 1000000 ||
        !Number.isInteger(stroke.randomSeed) || stroke.randomSeed < 0 || stroke.randomSeed > 4294967295 ||
        !Array.isArray(stroke.transform) || stroke.transform.length !== 6 || !stroke.transform.every(n => Number.isFinite(n) && Math.abs(n) <= 1000000) ||
        Math.abs(stroke.transform[0]*stroke.transform[3]-stroke.transform[1]*stroke.transform[2]) <= 1e-12) throw new Error('Invalid stroke');
    sampleCount += stroke.path.controlPoints.length+stroke.rawSamples.length;
    if (sampleCount > 4000000) throw new Error('Ink sample limit exceeded');
    for (const samples of [stroke.path.controlPoints,stroke.rawSamples]) {
      let previous = -1;
      for (const sample of samples) {
        if (!pair(sample.location) || !pair(sample.size) || sample.size.some(n => n < 0 || n > 4096) ||
            ![sample.timeOffset,sample.opacity,sample.force,sample.azimuth,sample.altitude].every(Number.isFinite) || sample.timeOffset < 0 ||
            sample.opacity < 0 || sample.opacity > 1 || sample.force < 0 || sample.force > 1 || (samples === stroke.rawSamples && sample.timeOffset < previous)) throw new Error('Invalid ink point');
        previous = sample.timeOffset;
      }
    }
    if (stroke.parentID != null && !elements.some(e => e.kind === 'stickyNote' && e.id.toLowerCase() === stroke.parentID.toLowerCase())) throw new Error('Invalid stroke parent');
    if (stroke.style != null && (!['solid','dashed','dotted'].includes(stroke.style.pattern ?? 'solid') || !Number.isFinite(stroke.style.width) || stroke.style.width <= 0 || stroke.style.width > 4096 || !Number.isFinite(stroke.style.sharpness ?? 0) || (stroke.style.sharpness ?? 0) < 0 || (stroke.style.sharpness ?? 0) > 1)) throw new Error('Invalid stroke style');
    if (stroke.vectorOutline != null) {
      if (!Array.isArray(stroke.vectorOutline.elements) || stroke.vectorOutline.elements.length > 100000) throw new Error('Invalid ink outline');
      sampleCount += stroke.vectorOutline.elements.length;
      for (const e of stroke.vectorOutline.elements) if (![0,1,2,3,4].includes(e.kind) || !Array.isArray(e.points) || e.points.length !== [1,1,2,3,0][e.kind] || !e.points.every(pair)) throw new Error('Invalid ink outline');
    }
  }
}

export function editNotebook(archive, changes) {
  validateArchive(archive);
  const copy = structuredClone(archive);
  for (const key of Object.keys(changes)) if (!['title', 'favorite', 'folderID', 'deletedAt'].includes(key)) throw new Error(`Unsupported notebook field: ${key}`);
  if ('title' in changes && (typeof changes.title !== 'string' || !changes.title.trim() || changes.title.length > 1000)) throw new Error('Invalid title');
  if ('favorite' in changes && typeof changes.favorite !== 'boolean') throw new Error('Invalid favorite');
  if ('folderID' in changes && !id(changes.folderID)) throw new Error('Invalid folder ID');
  if ('deletedAt' in changes && changes.deletedAt !== null && !Number.isFinite(changes.deletedAt)) throw new Error('Invalid deletedAt');
  Object.assign(copy.note, changes, { updatedAt: swiftNow() });
  return copy;
}

export function newBlankPage(noteID, index) {
  if (!id(noteID) || !Number.isInteger(index) || index < 0) throw new Error('Invalid page');
  const pageID = randomUUID();
  return { page: { id: pageID, noteID, index, format: 'a4Portrait', template: 'blank', drawingResourceID: `${pageID}.drawing` },
    drawing: Buffer.from(JSON.stringify({ inkSchemaVersion: 2, strokes: [] })).toString('base64') };
}

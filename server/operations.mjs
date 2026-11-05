import { randomUUID } from 'node:crypto';
import { editNotebook, newBlankPage, swiftNow, validateArchive } from './archive.mjs';

export function createNotebook(title, folderID) {
  const id = randomUUID(), time = swiftNow();
  const { page, drawing } = newBlankPage(id, 0);
  return editNotebook({ version: 2, note: { id, folderID, title, pageIDs: [page.id], createdAt: time, updatedAt: time }, pages: [page], resources: { [page.drawingResourceID]: drawing } }, { title });
}
export function addBlankPage(archive) {
  const next = structuredClone(validateArchive(archive));
  const { page, drawing } = newBlankPage(next.note.id, next.pages.length);
  next.pages.push(page); next.note.pageIDs.push(page.id); next.resources[page.drawingResourceID] = drawing; next.note.updatedAt = swiftNow();
  return validateArchive(next);
}
export function addElement(archive, pageID, element) {
  const next = structuredClone(validateArchive(archive));
  const page = next.pages.find(page => page.id.toLowerCase() === pageID.toLowerCase());
  if (!page) throw new Error('Page not found');
  const item = { id: randomUUID(), text: '', ...element };
  if (!['text', 'rectangle', 'ellipse', 'line', 'arrow', 'stickyNote', 'highlight'].includes(item.kind)) throw new Error('Unsupported element');
  page.elements = [...(page.elements ?? []), item]; page.modifiedAt = next.note.updatedAt = swiftNow();
  page.revision = (page.revision ?? 0) + 1;
  return validateArchive(next);
}
export function searchArchive(archive, query) {
  validateArchive(archive);
  const term = query.trim().toLocaleLowerCase();
  if (!term) throw new Error('Empty search');
  return archive.pages.flatMap(page => {
    const text = [page.text, page.recognizedText, page.pdfText?.text, page.ocrText?.text, ...(page.elements ?? []).map(item => item.text)].filter(x => typeof x === 'string').join('\n');
    const offset = text.toLocaleLowerCase().indexOf(term);
    return offset < 0 ? [] : [{ pageID: page.id, excerpt: text.slice(Math.max(0, offset - 60), offset + term.length + 100) }];
  });
}

// Historical archives remain immutable, so removed pages/elements can be restored from history.
export function editPage(archive, pageID, changes) {
  const next = structuredClone(validateArchive(archive));
  const page = next.pages.find(p => p.id.toLowerCase() === pageID.toLowerCase());
  if (!page) throw new Error('Page not found');
  for (const key of Object.keys(changes)) if (!['text', 'bookmark', 'template'].includes(key)) throw new Error('Unsupported page field');
  Object.assign(page, changes); page.modifiedAt = next.note.updatedAt = swiftNow(); page.revision = (page.revision ?? 0) + 1;
  return validateArchive(next);
}
export function reorderPages(archive, pageIDs) {
  const next = structuredClone(validateArchive(archive));
  const ids = pageIDs.map(id => id.toLowerCase());
  if (!ids.length || new Set(ids).size !== ids.length || ids.some(id => !next.pages.some(p => p.id.toLowerCase() === id))) throw new Error('Invalid page order');
  next.pages = ids.map((id, index) => ({ ...next.pages.find(p => p.id.toLowerCase() === id), index }));
  next.note.pageIDs = next.pages.map(p => p.id); next.note.updatedAt = swiftNow();
  return validateArchive(next);
}
export function updateElement(archive, pageID, elementID, changes) {
  const next = structuredClone(validateArchive(archive));
  const page = next.pages.find(p => p.id.toLowerCase() === pageID.toLowerCase());
  const element = page?.elements?.find(e => e.id.toLowerCase() === elementID.toLowerCase());
  if (!element) throw new Error('Element not found');
  if (changes === null) {
    const removed = new Set([elementID.toLowerCase()]);
    for (let count = -1; count !== removed.size;) { count = removed.size; for (const e of page.elements) if (e.parentID && removed.has(e.parentID.toLowerCase())) removed.add(e.id.toLowerCase()); }
    page.elements = page.elements.filter(e => !removed.has(e.id.toLowerCase()));
    const ink = JSON.parse(Buffer.from(next.resources[page.drawingResourceID], 'base64'));
    ink.strokes = ink.strokes.filter(s => !s.parentID || !removed.has(s.parentID.toLowerCase()));
    next.resources[page.drawingResourceID] = Buffer.from(JSON.stringify(ink)).toString('base64');
    page.drawingRevision = (page.drawingRevision ?? 0) + 1;
  } else {
    const allowed = ['text','x','y','width','height','rotation','isLocked','parentID','zIndex','collapsed','textFontSize','textColorHex','strokeWidth','strokeColorHex','fillColorHex'];
    for (const key of Object.keys(changes)) if (!allowed.includes(key)) throw new Error('Unsupported element field');
    const before = { ...element };
    if ('text' in changes) delete element.richTextRTF;
    Object.assign(element, changes);
    if (element.kind === 'stickyNote' && ['x','y','rotation'].some(key => key in changes)) {
      const angle = (element.rotation ?? 0) - (before.rotation ?? 0), c = Math.cos(angle), s = Math.sin(angle);
      const ox = before.x + before.width/2, oy = before.y + before.height/2;
      const nx = element.x + before.width/2, ny = element.y + before.height/2;
      const tx = nx-c*ox+s*oy, ty = ny-s*ox-c*oy;
      const children = new Set([element.id.toLowerCase()]);
      for (let count = -1; count !== children.size;) { count = children.size; for (const e of page.elements) if (e.parentID && children.has(e.parentID.toLowerCase())) children.add(e.id.toLowerCase()); }
      for (const e of page.elements) if (e.id !== element.id && children.has(e.id.toLowerCase())) {
        const x=e.x+e.width/2, y=e.y+e.height/2;
        e.x=c*x-s*y+tx-e.width/2; e.y=s*x+c*y+ty-e.height/2; e.rotation=(e.rotation ?? 0)+angle;
      }
      const ink = JSON.parse(Buffer.from(next.resources[page.drawingResourceID], 'base64'));
      for (const stroke of ink.strokes) if (stroke.parentID && children.has(stroke.parentID.toLowerCase())) {
        const [a,b,d,e,x,y] = stroke.transform ?? [1,0,0,1,0,0];
        stroke.transform=[c*a-s*b,s*a+c*b,c*d-s*e,s*d+c*e,c*x-s*y+tx,s*x+c*y+ty];
      }
      next.resources[page.drawingResourceID] = Buffer.from(JSON.stringify(ink)).toString('base64');
      page.drawingRevision = (page.drawingRevision ?? 0)+1;
    }
  }
  page.modifiedAt = next.note.updatedAt = swiftNow(); page.revision = (page.revision ?? 0) + 1;
  return validateArchive(next);
}
export function removeInk(archive, pageID, strokeIDs) {
  const next = structuredClone(validateArchive(archive)), ids = new Set(strokeIDs.map(id => id.toLowerCase()));
  const page = next.pages.find(p => p.id.toLowerCase() === pageID.toLowerCase());
  if (!page) throw new Error('Page not found');
  const ink = JSON.parse(Buffer.from(next.resources[page.drawingResourceID], 'base64'));
  if ([...ids].some(id => !ink.strokes.some(s => s.id.toLowerCase() === id))) throw new Error('Stroke not found');
  ink.strokes = ink.strokes.filter(s => !ids.has(s.id.toLowerCase()));
  next.resources[page.drawingResourceID] = Buffer.from(JSON.stringify(ink)).toString('base64');
  page.modifiedAt = next.note.updatedAt = swiftNow(); page.revision = (page.revision ?? 0) + 1; page.drawingRevision = (page.drawingRevision ?? 0) + 1;
  return validateArchive(next);
}

export async function importPDF(archive, data) {
  const { PDFDocument } = await import('pdf-lib');
  if (!Buffer.isBuffer(data) || data.length === 0 || data.length > 50 * 1024 * 1024) throw new Error('Invalid PDF size');
  const pdf = await PDFDocument.load(data, { ignoreEncryption: false });
  const next = structuredClone(validateArchive(archive));
  if (!pdf.getPageCount() || next.pages.length + pdf.getPageCount() > 10000) throw new Error('Invalid PDF page count');
  const resource = `${randomUUID()}.pdf`;
  next.resources[resource] = data.toString('base64');
  for (const [pdfIndex, source] of pdf.getPages().entries()) {
    const { page, drawing } = newBlankPage(next.note.id, next.pages.length);
    const crop = source.getCropBox(), angle = ((source.getRotation().angle % 360) + 360) % 360;
    if (![0,90,180,270].includes(angle)) throw new Error('Unsupported PDF rotation');
    page.width = angle % 180 ? crop.height : crop.width; page.height = angle % 180 ? crop.width : crop.height;
    page.backgroundID = resource; page.pdfIndex = pdfIndex;
    next.pages.push(page); next.note.pageIDs.push(page.id); next.resources[page.drawingResourceID] = drawing;
  }
  next.note.updatedAt = swiftNow();
  return validateArchive(next);
}

export async function addImage(archive, pageID, data, rect) {
  const { PDFDocument } = await import('pdf-lib');
  if (!Buffer.isBuffer(data) || data.length === 0 || data.length > 20 * 1024 * 1024) throw new Error('Invalid image size');
  const pdf = await PDFDocument.create();
  const png = data.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  const jpeg = data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff;
  if (png) await pdf.embedPng(data); else if (jpeg) await pdf.embedJpg(data); else throw new Error('Expected PNG or JPEG');
  const next = structuredClone(validateArchive(archive));
  const page = next.pages.find(page => page.id.toLowerCase() === pageID.toLowerCase());
  if (!page) throw new Error('Page not found');
  const resource = `${randomUUID()}.${png ? 'png' : 'jpg'}`;
  next.resources[resource] = data.toString('base64');
  page.elements = [...(page.elements ?? []), { id: randomUUID(), kind: 'image', text: '', resource, ...rect }];
  page.modifiedAt = next.note.updatedAt = swiftNow(); page.revision = (page.revision ?? 0) + 1;
  return validateArchive(next);
}

export function addInk(archive, pageID, points, width, rgba, inkType = 'pen') {
  const next = structuredClone(validateArchive(archive));
  const page = next.pages.find(page => page.id.toLowerCase() === pageID.toLowerCase());
  if (!page) throw new Error('Page not found');
  if (!Array.isArray(points) || points.length === 0 || points.length > 10000 || !Number.isFinite(width) || width < .1 || width > 128 ||
      !Array.isArray(rgba) || rgba.length !== 4 || !rgba.every(x => Number.isFinite(x) && x >= 0 && x <= 1) || !['pen','monoline','fountainPen','marker','pencil'].includes(inkType) ||
      !points.every(p => Array.isArray(p) && p.length === 2 && p.every(Number.isFinite) && p[0] >= 0 && p[1] >= 0 && p[0] <= (page.width ?? 794) && p[1] <= (page.height ?? 1123))) throw new Error('Invalid ink');
  const ink = JSON.parse(Buffer.from(next.resources[page.drawingResourceID], 'base64').toString());
  if (![1,2].includes(ink.inkSchemaVersion) || !Array.isArray(ink.strokes) || ink.strokes.length >= 100000) throw new Error('Invalid ink document');
  const samples = points.map(([x,y], i) => ({ location:[x,y], timeOffset:i/60, size:[width,width], opacity:1, force:.5, azimuth:0, altitude:Math.PI/2 }));
  ink.strokes.push({ id:randomUUID(), ink:{inkType,rgbaSRGB:rgba}, path:{controlPoints:samples, creationDate:swiftNow()}, rawSamples:samples, transform:[1,0,0,1,0,0], randomSeed:0 });
  ink.inkSchemaVersion = 2;
  next.resources[page.drawingResourceID] = Buffer.from(JSON.stringify(ink)).toString('base64');
  page.modifiedAt = next.note.updatedAt = swiftNow(); page.revision = (page.revision ?? 0) + 1; page.drawingRevision = (page.drawingRevision ?? 0) + 1;
  return validateArchive(next);
}

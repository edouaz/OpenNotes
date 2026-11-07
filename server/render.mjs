import { PDFDocument, StandardFonts, BlendMode, rgb, degrees, pushGraphicsState, popGraphicsState, translate, rotateRadians, rectangle, moveTo, lineTo, closePath, clip, clipEvenOdd, endPath } from 'pdf-lib';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { validateArchive } from './archive.mjs';
import rtfParser from 'rtf-parser';
import fontkit from '@pdf-lib/fontkit';
const exec = promisify(execFile);
const color = (hex, fallback = '#000000') => {
  const value = /^#[0-9a-f]{6}$/i.test(hex ?? '') ? hex : fallback;
  return rgb(parseInt(value.slice(1, 3), 16) / 255, parseInt(value.slice(3, 5), 16) / 255, parseInt(value.slice(5, 7), 16) / 255);
};
const sameID = (a,b) => typeof a === 'string' && typeof b === 'string' && a.toLowerCase() === b.toLowerCase();
const point = p => Array.isArray(p) ? p : [p.x, p.y];
function svgOutline(stroke) {
  const t = stroke.transform ?? [1, 0, 0, 1, 0, 0];
  const transform = p => { const [x, y] = point(p); return `${t[0] * x + t[2] * y + t[4]} ${t[1] * x + t[3] * y + t[5]}`; };
  if (stroke.vectorOutline) return stroke.vectorOutline.elements.map(e => ['M', 'L', 'Q', 'C', 'Z'][e.kind] + e.points.map(transform).join(' ')).join(' ');
  const paths = paintedPaths(stroke);
  const commands = [];
  for (const points of paths) {
  for (const p of points) {
    const [x, y] = point(p.location), size = point(p.size), r = Math.max(.025, Math.max(...size) / 2);
    const a = transform([x-r,y]), b = transform([x+r,y]);
    // Cubic approximation respects an arbitrary stroke transform.
    const k = .55228475 * r;
    commands.push(`M ${a} C ${transform([x-r,y-k])} ${transform([x-k,y-r])} ${transform([x,y-r])} C ${transform([x+k,y-r])} ${transform([x+r,y-k])} ${b} C ${transform([x+r,y+k])} ${transform([x+k,y+r])} ${transform([x,y+r])} C ${transform([x-k,y+r])} ${transform([x-r,y+k])} ${a} Z`);
  }
  for (let i = 1; i < points.length; i++) {
    const a = points[i-1], b = points[i], [ax, ay] = point(a.location), [bx, by] = point(b.location), d = Math.hypot(bx-ax, by-ay);
    if (!d) continue;
    const ar = point(a.size)[0] / 2, br = point(b.size)[0] / 2, nx = -(by-ay)/d, ny = (bx-ax)/d;
    commands.push(`M ${transform([ax+nx*ar,ay+ny*ar])} L ${transform([ax-nx*ar,ay-ny*ar])} L ${transform([bx-nx*br,by-ny*br])} L ${transform([bx+nx*br,by+ny*br])} Z`);
  }
  }
  return commands.join(' ');
}
function paintedPaths(stroke) {
  const samples = stroke.path?.controlPoints ?? [];
  if (samples.length < 2) return [samples];
  const lengths = [0];
  for (let i=1;i<samples.length;i++) { const a=point(samples[i-1].location),b=point(samples[i].location); lengths.push(lengths.at(-1)+Math.hypot(b[0]-a[0],b[1]-a[1])); }
  const total=lengths.at(-1), style=stroke.style ?? {}, width=style.width ?? point(samples[0].size)[0], taper=style.sharpness ?? 0;
  if (total <= .001) return [[samples[0]]];
  let cursor=0;
  function sample(distance) {
    while (cursor+1 < lengths.length-1 && lengths[cursor+1] < distance) cursor++;
    const a=samples[cursor], b=samples[cursor+1], span=lengths[cursor+1]-lengths[cursor], f=span>0 ? (distance-lengths[cursor])/span : 0;
    const ap=point(a.location),bp=point(b.location),as=point(a.size),bs=point(b.size);
    const cap=Math.min(total/2,Math.max(.1,width*1.5)), edge=Math.min(1,Math.max(0,Math.min(distance,total-distance)/cap));
    const factor=Math.max(.08,1-taper+taper*edge*edge*(3-2*edge));
    return {location:[ap[0]+(bp[0]-ap[0])*f,ap[1]+(bp[1]-ap[1])*f],size:[(as[0]+(bs[0]-as[0])*f)*factor,(as[1]+(bs[1]-as[1])*f)*factor]};
  }
  if ((style.pattern ?? 'solid') === 'solid') {
    if (!taper) return [samples];
    const cap=Math.min(total/2,Math.max(.1,width*1.5)), distances=[...lengths];
    for(let i=0;i<=4;i++){distances.push(cap*i/4,total-cap*i/4)}
    return [[...new Set(distances)].sort((a,b)=>a-b).map(sample)];
  }
  const unit=Math.max(.1,width), result=[];
  if (style.pattern === 'dotted') { for(let d=0;d<=total && result.length<1000000;d+=unit*2.2) result.push([sample(d)]); return result; }
  let index=1;
  for(let start=0;start<total && result.length<1000000;start+=unit*5) {
    const end=Math.min(total,start+unit*3), distances=[start];
    while(index<lengths.length && lengths[index]<=start) index++;
    while(index<lengths.length && lengths[index]<end) distances.push(lengths[index++]);
    distances.push(end); result.push(distances.map(sample));
  }
  return result;
}
async function drawRichText(page,item,x,y,width,height,fonts) {
  const bytes=Buffer.from(item.richTextRTF,'base64');
  if (bytes.length>2*1024*1024) throw new Error('Rich text exceeds size limit');
  const doc=await new Promise((resolve,reject)=>rtfParser.string(bytes.toString('latin1'),(error,value)=>error ? reject(error) : resolve(value)));
  const paragraphs=[]; let pending=[];
  for (const node of doc.content) {
    if (node.content) { if(pending.length) paragraphs.push(pending); pending=[]; paragraphs.push(node.content); }
    else pending.push(node);
  }
  if(pending.length) paragraphs.push(pending);
  const plain=paragraphs.map(p=>p.map(span=>span.value ?? '').join('')).join('\n');
  if (plain.replace(/\n$/,'') !== item.text.replace(/\n$/,'')) throw new Error('Rich text could not be rendered without losing content');
  let cursorY=y+height-24;
  page.pushOperators(pushGraphicsState(),rectangle(x,y,width,height),clip(),endPath());
  for(const spans of paragraphs) {
    let cursorX=x+8, lineHeight=20;
    for(const span of spans) {
      const style=span.style ?? {}, size=Math.max(8,Math.min(96,(style.fontSize ?? 32)/2));
      const font=style.bold ? (style.italic ? fonts.boldItalic : fonts.bold) : (style.italic ? fonts.italic : fonts.font);
      const fg=style.foreground, ink=fg ? rgb(fg.red/255,fg.green/255,fg.blue/255) : color(item.textColorHex);
      lineHeight=Math.max(lineHeight,size*1.2);
      for(const word of (span.value ?? '').split(/(?<=\s)/)) {
        const length=font.widthOfTextAtSize(word,size);
        if (cursorX+length>x+width-8 && cursorX>x+8) {cursorX=x+8; cursorY-=lineHeight;}
        page.drawText(word,{x:cursorX,y:cursorY,size,font,color:ink});
        if(style.underline) page.drawLine({start:{x:cursorX,y:cursorY-2},end:{x:cursorX+length,y:cursorY-2},thickness:.8,color:ink});
        if(style.strikethrough) page.drawLine({start:{x:cursorX,y:cursorY+size*.3},end:{x:cursorX+length,y:cursorY+size*.3},thickness:.8,color:ink});
        cursorX+=length;
      }
    }
    cursorY-=lineHeight;
  }
  page.pushOperators(popGraphicsState());
}
function addNotePath(page,note,height) {
  const w=note.collapsed ? 44 : note.width, h=note.collapsed ? 44 : note.height;
  const cx=note.x+w/2, cy=note.y+h/2, angle=note.rotation ?? 0, c=Math.cos(angle), si=Math.sin(angle);
  const points=[[note.x,note.y],[note.x+w,note.y],[note.x+w,note.y+h],[note.x,note.y+h]].map(([x,y])=>[cx+(x-cx)*c-(y-cy)*si,height-(cy+(x-cx)*si+(y-cy)*c)]);
  page.pushOperators(moveTo(...points[0]), ...points.slice(1).map(p=>lineTo(...p)), closePath());
}
export async function exportPDF(archive, selectedPageID = null) {
  validateArchive(archive);
  const pages = selectedPageID ? archive.pages.filter(p => p.id.toLowerCase() === selectedPageID.toLowerCase()) : archive.pages;
  if (!pages.length) throw new Error('Page not found');
  const result = await PDFDocument.create(); result.registerFontkit(fontkit);
  async function fontFor(path, fallback) {
    if (path) { try { return await result.embedFont(await readFile(path), { subset: true }); } catch { throw new Error('Could not load configured export font'); } }
    return result.embedFont(fallback);
  }
  const font = await fontFor(process.env.NOTES_FONT_REGULAR, StandardFonts.Helvetica);
  const bold = await fontFor(process.env.NOTES_FONT_BOLD, StandardFonts.HelveticaBold);
  const italic = await fontFor(process.env.NOTES_FONT_ITALIC, StandardFonts.HelveticaOblique);
  const boldItalic = await fontFor(process.env.NOTES_FONT_BOLD_ITALIC, StandardFonts.HelveticaBoldOblique);
  for (const source of pages) {
    const width = source.width ?? 794, height = source.height ?? 1123, page = result.addPage([width, height]);
    page.drawRectangle({ x: 0, y: 0, width, height, color: rgb(1,1,1) });
    if (source.backgroundID && source.pdfIndex != null) {
      const original = await PDFDocument.load(Buffer.from(archive.resources[source.backgroundID], 'base64'));
      const originalPage = original.getPage(source.pdfIndex);
      if (originalPage.node.Contents()) {
        const crop = originalPage.getCropBox(), angle = ((originalPage.getRotation().angle % 360) + 360) % 360;
        if (![0,90,180,270].includes(angle)) throw new Error('Unsupported PDF rotation');
        const background = await result.embedPage(originalPage, {left:crop.x,bottom:crop.y,right:crop.x+crop.width,top:crop.y+crop.height});
        const rw = angle % 180 ? crop.height : crop.width, rh = angle % 180 ? crop.width : crop.height;
        const scale = Math.min(width/rw,height/rh), left=(width-rw*scale)/2, bottom=(height-rh*scale)/2;
        const offsets={0:[0,0],90:[0,crop.width*scale],180:[crop.width*scale,crop.height*scale],270:[crop.height*scale,0]};
        page.drawPage(background, {x:left+offsets[angle][0],y:bottom+offsets[angle][1],width:crop.width*scale,height:crop.height*scale,rotate:degrees(-angle)});
      }
    } else if (source.backgroundID) {
      const data = Buffer.from(archive.resources[source.backgroundID], 'base64');
      const image = data[0] === 137 ? await result.embedPng(data) : await result.embedJpg(data);
      page.drawImage(image, { x: 0, y: 0, width, height });
    } else if (source.template === 'ruled' || source.template === 'grid') {
      const step=source.template === 'ruled' ? 32 : 24, opacity=source.template === 'ruled' ? .28 : .24;
      for(let y=step;y<height;y+=step) page.drawLine({start:{x:0,y:height-y},end:{x:width,y:height-y},thickness:1,color:rgb(.12,.4,.65),opacity});
      if(source.template === 'grid') for(let x=step;x<width;x+=step) page.drawLine({start:{x,y:0},end:{x,y:height},thickness:1,color:rgb(.12,.4,.65),opacity});
    } else if (source.template === 'dotted') {
      for(let x=24;x<width;x+=24) for(let y=24;y<height;y+=24) page.drawCircle({x,y:height-y,size:1.2,color:rgb(.12,.4,.65),opacity:.28});
    } else if (source.template !== 'blank') throw new Error('Unsupported paper template');
    for (const item of (source.elements ?? []).slice().sort((a,b) => (a.zIndex ?? 0) - (b.zIndex ?? 0))) {
      if (item.parentID && source.elements.some(e => sameID(e.id,item.parentID) && e.collapsed)) continue;
      if (item.rotation) {
        const cx=item.x+(item.collapsed ? 22 : item.width/2), cy=height-item.y-(item.collapsed ? 22 : item.height/2);
        page.pushOperators(pushGraphicsState(),translate(cx,cy),rotateRadians(-item.rotation),translate(-cx,-cy));
      }

      const x=item.x, y=height-item.y-item.height, w=item.width, h=item.height;
      if (item.kind === 'image') {
        const data = Buffer.from(archive.resources[item.resource], 'base64');
        const image = data[0] === 137 ? await result.embedPng(data) : await result.embedJpg(data);
        page.drawImage(image, {x,y,width:w,height:h});
      } else if (item.kind === 'rectangle' || item.kind === 'stickyNote' || item.kind === 'highlight') {
        page.drawRectangle({ x,y:item.collapsed ? height-item.y-44 : y,width:item.collapsed ? 44 : w,height:item.collapsed ? 44 : h,
          ...(item.fillColorHex || item.kind !== 'rectangle' ? { color: color(item.fillColorHex, item.kind === 'highlight' ? '#FFFF00' : '#FFEB80') } : {}),
          ...(item.kind === 'rectangle' ? { borderColor: color(item.strokeColorHex), borderWidth: item.strokeWidth ?? 2 } : {}),
          ...(item.kind === 'highlight' ? { opacity: 0.3, blendMode:BlendMode.Multiply } : {}) });
      } else if (item.kind === 'ellipse') {
        page.drawEllipse({ x:x+w/2, y:y+h/2, xScale:w/2, yScale:h/2, borderColor:color(item.strokeColorHex), borderWidth:item.strokeWidth ?? 2, ...(item.fillColorHex ? {color:color(item.fillColorHex)} : {}) });
      } else if (item.kind === 'line' || item.kind === 'arrow') {
        page.drawLine({start:{x,y:y+h},end:{x:x+w,y},thickness:item.strokeWidth ?? 2,color:color(item.strokeColorHex)});
        if (item.kind === 'arrow') { const angle=Math.atan2(h,w); for (const offset of [-.5,.5]) page.drawLine({start:{x:x+w,y},end:{x:x+w-20*Math.cos(angle+offset),y:y+20*Math.sin(angle+offset)},thickness:item.strokeWidth ?? 2,color:color(item.strokeColorHex)}); }
      }
      if ((item.kind === 'text' || item.kind === 'stickyNote' && !item.collapsed) && item.text) {
        if (item.richTextRTF) await drawRichText(page,item,x,y,w,h,{font,bold,italic,boldItalic});
        else page.drawText(item.text, { x:x+8,y:y+h-24,size:item.textFontSize ?? 20,font,color:color(item.textColorHex),maxWidth:Math.max(1,w-16) });
      }
      if (item.rotation) page.pushOperators(popGraphicsState());
    }
    if (source.text) page.drawText(source.text, {x:32,y:height-52,size:20,font,maxWidth:width-64});
    const ink = JSON.parse(Buffer.from(archive.resources[source.drawingResourceID], 'base64').toString());
    if (![1,2].includes(ink.inkSchemaVersion) || !Array.isArray(ink.strokes)) throw new Error('Invalid ink');
    const notes=(source.elements ?? []).filter(e=>e.kind==='stickyNote').sort((a,b)=>(a.zIndex ?? 0)-(b.zIndex ?? 0));
    for (const stroke of ink.strokes) {
      if (stroke.parentID && source.elements?.some(e => sameID(e.id,stroke.parentID) && e.collapsed)) continue;
      const rgba = stroke.ink.rgbaSRGB, path = svgOutline(stroke);
      const parentIndex=notes.findIndex(note=>sameID(note.id,stroke.parentID)), parent=notes[parentIndex];
      page.pushOperators(pushGraphicsState());
      if (parent) { addNotePath(page,parent,height); page.pushOperators(clip(),endPath()); }
      for(const note of notes.slice(parentIndex+1)) {
        page.pushOperators(rectangle(0,0,width,height)); addNotePath(page,note,height); page.pushOperators(clipEvenOdd(),endPath());
      }
      if (path) page.drawSvgPath(path, {x:0,y:height,color:rgb(rgba[0],rgba[1],rgba[2]),opacity:rgba[3]*(stroke.ink.inkType === 'marker' ? .3 : 1),...(stroke.ink.inkType === 'marker' ? {blendMode:BlendMode.Multiply} : {})});
      page.pushOperators(popGraphicsState());
    }
  }
  return Buffer.from(await result.save());
}
export async function renderPage(archive, pageID) {
  const pdf = await exportPDF(archive, pageID), dir = await mkdtemp(join(tmpdir(), 'opennotes-render-'));
  try {
    await writeFile(join(dir, 'page.pdf'), pdf);
    for (const scale of [2048, 1536, 1024]) {
      await exec('pdftoppm', ['-f','1','-l','1','-scale-to',String(scale),'-singlefile','-png',join(dir,'page.pdf'),join(dir,'page')], { timeout: 30000, maxBuffer: 1024 * 1024 });
      const png = await readFile(join(dir, 'page.png'));
      if (png.length <= 3 * 1024 * 1024) return png;
    }
    throw new Error('Rendered page exceeds response size limit');
  } finally { await rm(dir, { recursive:true, force:true }); }
}

// Word boxes of one page in document coordinates (top-left origin), via Poppler on the exported page.
export async function pageWords(archive, pageID) {
  const pdf = await exportPDF(archive, pageID), dir = await mkdtemp(join(tmpdir(), 'opennotes-words-'));
  try {
    await writeFile(join(dir, 'page.pdf'), pdf);
    const { stdout } = await exec('pdftotext', ['-bbox', '-f', '1', '-l', '1', join(dir, 'page.pdf'), '-'], { timeout: 30000, maxBuffer: 16 * 1024 * 1024 });
    const unescape = s => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&apos;/g, "'").replace(/&amp;/g, '&');
    return [...stdout.matchAll(/<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">([^<]*)<\/word>/g)]
      .map(m => ({ x0: +m[1], y0: +m[2], x1: +m[3], y1: +m[4], text: unescape(m[5]) }));
  } finally { await rm(dir, { recursive: true, force: true }); }
}

// One rectangle per line for every occurrence of `query` (case/accents/punctuation-insensitive word match).
export function matchRects(words, query, maxMatches = 50) {
  const norm = s => s.normalize('NFD').replace(/\p{M}/gu, '').toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
  const terms = query.split(/\s+/).map(norm).filter(Boolean), keys = words.map(w => norm(w.text));
  if (!terms.length) throw new Error('Empty query');
  const matches = [];
  for (let i = 0; i + terms.length <= words.length && matches.length < maxMatches; i++) {
    // Phrase edges may be glued to punctuation or split words ("…light," / "high-"); inner words must match exactly.
    const last = terms.length - 1;
    const hit = (t, k) => last === 0 ? keys[i].includes(t) : k === 0 ? keys[i].endsWith(t) : k === last ? keys[i + k].startsWith(t) : keys[i + k] === t;
    if (!terms.every(hit)) continue;
    const lines = [];
    for (const w of words.slice(i, i + terms.length)) {
      const line = lines.find(l => Math.abs(l.y0 - w.y0) < (w.y1 - w.y0) / 2);
      if (line) Object.assign(line, { x0: Math.min(line.x0, w.x0), x1: Math.max(line.x1, w.x1), y0: Math.min(line.y0, w.y0), y1: Math.max(line.y1, w.y1) });
      else lines.push({ ...w });
    }
    matches.push(lines.map(({ x0, y0, x1, y1 }) => ({ x: x0, y: y0, width: x1 - x0, height: y1 - y0 })));
    i += terms.length - 1;
  }
  return matches;
}

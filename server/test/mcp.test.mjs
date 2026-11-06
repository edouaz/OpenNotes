import { test } from 'node:test';
import { strict as assert } from 'node:assert';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';
import { createServer } from '../mcp.mjs';
import { memoryClient } from './helpers.mjs';
import { PDFDocument } from 'pdf-lib';
const ALL = { allowWrite: true, allowDestructive: true };

test('official MCP client can discover and execute registered tools', async () => {
  const fake = { from() { return { select() { return this; }, order() { return this; }, async range() { return { data: [{ notebook_id: 'owned', revision_id: 'revision' }] }; } }; } };
  const server = createServer(fake, 'a1dfd123-1234-4abc-8def-0123456789ab');
  const client = new Client({ name: 'test', version: '1.0.0' });
  const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
  await Promise.all([server.connect(serverTransport), client.connect(clientTransport)]);
  const tools = await client.listTools(); assert.ok(tools.tools.some(tool => tool.name === 'list_notebooks'));
  const result = await client.callTool({ name: 'list_notebooks', arguments: {} });
  assert.deepEqual(JSON.parse(result.content[0].text), [{ notebook_id: 'owned', revision_id: 'revision' }]);
  await client.close(); await server.close();
});

test('SDK edits, conflicts, trash, image reads and history restoration publish real native archives', async () => {
  const server=createServer(memoryClient(),'a1dfd123-1234-4abc-8def-0123456789ab',ALL), client=new Client({name:'test',version:'1.0.0'});
  const [a,b]=InMemoryTransport.createLinkedPair(); await Promise.all([server.connect(b),client.connect(a)]);
  const call=async(name,args)=>{
    const result=await client.callTool({name,arguments:args});
    assert.ok(!result.isError,JSON.stringify(result)); return JSON.parse(result.content[0].text);
  };
  try {
    const created=await call('create_notebook',{title:'Exercise',folderID:'c1dfd123-1234-4abc-8def-0123456789ab'});
    const {notebookID}=created, initial=await call('get_notebook',{notebookID}), pageID=initial.archive.pages[0].id;
    const added=await call('add_element',{notebookID,pageID,expectedRevision:created.revisionID,kind:'text',x:10,y:10,width:100,height:50,text:'Question'});
    const {archive}=await call('get_notebook',{notebookID}), elementID=archive.pages[0].elements[0].id;
    const updated=await call('update_element',{notebookID,pageID,elementID,expectedRevision:added.revisionID,changes:{text:'Answer'}});
    assert.equal((await call('search_notebook',{notebookID,query:'Answer'})).length,1);
    const stale=await client.callTool({name:'update_notebook',arguments:{notebookID,expectedRevision:created.revisionID,title:'Stale'}});
    assert.equal(stale.isError,true);
    const rendered=await client.callTool({name:'render_page',arguments:{notebookID,pageID}});
    assert.equal(rendered.content[0].type,'image'); assert.equal(rendered.content[0].mimeType,'image/png');
    const trashed=await call('update_notebook',{notebookID,expectedRevision:updated.revisionID,trashed:true});
    assert.equal(typeof (await call('get_notebook',{notebookID})).archive.note.deletedAt,'number');
    await call('restore_revision',{notebookID,revisionID:created.revisionID,expectedRevision:trashed.revisionID});
    const restored=await call('get_notebook',{notebookID});
    assert.equal(restored.archive.note.deletedAt,undefined); assert.equal(restored.archive.pages[0].elements,undefined);
  } finally {await client.close();await server.close();}
});

test('folder tool requires current timestamp and does not overwrite a stale change', async () => {
  const folderID='c1dfd123-1234-4abc-8def-0123456789ab', stamp='2026-10-31T10:00:00Z';
  let row={id:folderID,name:'Before',updated_at:stamp};
  const fake={from(){let changes, filters={}; return {
    update(value){changes=value;return this;},eq(key,value){filters[key]=value;return this;},select(){return this;},
    async single(){if(filters.id!==row.id||filters.updated_at!==row.updated_at)return {error:new Error('Folder revision conflict')}; row={...row,...changes};return {data:row};}
  };}};
  const server=createServer(fake,'a1dfd123-1234-4abc-8def-0123456789ab',ALL), client=new Client({name:'test',version:'1.0.0'});
  const [a,b]=InMemoryTransport.createLinkedPair(); await Promise.all([server.connect(b),client.connect(a)]);
  try {
    const stale=await client.callTool({name:'update_folder',arguments:{folderID,name:'Wrong',expectedUpdatedAt:'2026-10-30T10:00:00Z'}});
    assert.equal(stale.isError,true); assert.equal(row.name,'Before');
    const current=await client.callTool({name:'update_folder',arguments:{folderID,name:'After',expectedUpdatedAt:stamp}});
    assert.equal(current.isError,undefined); assert.equal(row.name,'After');
    const names=(await client.listTools()).tools.map(tool=>tool.name);
    for(const name of ['update_element','restore_revision','get_folder_history','render_page']) assert.ok(names.includes(name));
  } finally {await client.close();await server.close();}
});


test('large-file transfers stay within the notebook owner path and reject stale imports', async () => {
  const fake=memoryClient(), server=createServer(fake,'a1dfd123-1234-4abc-8def-0123456789ab',ALL), client=new Client({name:'test',version:'1.0.0'});
  const [a,b]=InMemoryTransport.createLinkedPair(); await Promise.all([server.connect(b),client.connect(a)]);
  const call=async(name,args)=>client.callTool({name,arguments:args});
  try {
    const created=JSON.parse((await call('create_notebook',{title:'Transfer',folderID:'c1dfd123-1234-4abc-8def-0123456789ab'})).content[0].text);
    const upload=JSON.parse((await call('create_upload',{notebookID:created.notebookID})).content[0].text);
    assert.match(upload.path,new RegExp(`^a1dfd123-1234-4abc-8def-0123456789ab/${created.notebookID}/`));
    assert.equal((await call('import_uploaded_pdf',{notebookID:created.notebookID,expectedRevision:created.revisionID,path:'other/path'})).isError,true);
    const pdf=await PDFDocument.create(); pdf.addPage(); fake.objects.set(upload.path,await pdf.save());
    const imported=JSON.parse((await call('import_uploaded_pdf',{notebookID:created.notebookID,expectedRevision:created.revisionID,path:upload.path})).content[0].text);
    assert.equal(imported.addedPages,1); assert.equal(fake.objects.has(upload.path),false);
    const saved=JSON.parse((await call('download_notebook',{notebookID:created.notebookID})).content[0].text);
    assert.match(saved.url,/^https:\/\/storage\.example\/download\//); assert.equal(saved.revisionID,imported.revisionID);
    await call('remove_transfer',{notebookID:created.notebookID,path:saved.path}); assert.equal(fake.objects.has(saved.path),false);
    assert.equal((await call('import_uploaded_pdf',{notebookID:created.notebookID,expectedRevision:'a1dfd123-1234-4abc-8def-0123456789ab',path:upload.path})).isError,true);
  } finally {await client.close();await server.close();}
});

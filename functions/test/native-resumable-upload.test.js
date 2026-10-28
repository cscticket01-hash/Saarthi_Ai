'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs'),crypto=require('node:crypto');
const source=fs.readFileSync('../school-backend/managed/SaarthiResumableUpload.gs','utf8');
const school='vs-'+ 'a'.repeat(32),hash=b=>crypto.createHash('sha256').update(b).digest('hex');
function fixture(){
 const props=new Map([['VS_MANAGED_SCHOOL_ID',school],['VS_NATIVE_RESUMABLE_UPLOAD','1']]),sessions=new Map(),files=new Map();let allocated=0,creates=0,puts=0,lost=false,corrupt=false,evil=false;
 const response=(code,data={},headers={})=>({getResponseCode:()=>code,getContentText:()=>JSON.stringify(data),getAllHeaders:()=>headers});
 const folder={getId:()=> 'root',getFilesByName:name=>{const matches=[...files.values()].filter(f=>f.name===name);let i=0;return {hasNext:()=>i<matches.length,next:()=>{const f=matches[i++];return {getId:()=>f.id,getDescription:()=>f.description};}};}};
 const fetch=(url,opt)=>{
  assert.equal(opt.followRedirects,false);assert.equal(opt.headers.Authorization,'Bearer PRIVATE_TOKEN');
  if(url.includes('generateIds'))return response(200,{ids:['allocated_'+(++allocated)]});
  if(url.includes('uploadType=resumable')){creates++;const meta=JSON.parse(opt.payload);sessions.set(meta.id,{meta,bytes:Buffer.alloc(0),total:Number(opt.headers['X-Upload-Content-Length'])});return response(200,{}, {Location:evil?'https://evil.example/session':'https://www.googleapis.com/upload/drive/v3/files?upload_id='+meta.id});}
  if(url.includes('upload_id=')){
   const id=url.split('upload_id=')[1],s=sessions.get(id);if(!s)return response(404);
   if(opt.headers['Content-Range'].startsWith('bytes */'))return files.has(id)?response(200):response(308,{},s.bytes.length?{Range:'bytes=0-'+(s.bytes.length-1)}:{});
   puts++;const start=Number(opt.headers['Content-Range'].match(/^bytes (\d+)-/)[1]);assert.equal(start,s.bytes.length);s.bytes=Buffer.concat([s.bytes,Buffer.from(opt.payload)]);
   if(s.bytes.length===s.total)files.set(id,{...s.meta,size:String(s.total),sha256Checksum:corrupt?'0'.repeat(64):hash(s.bytes),trashed:false});
   if(lost){lost=false;throw Error('lost response PRIVATE_SESSION');}
   return files.has(id)?response(200):response(308,{}, {Range:'bytes=0-'+(s.bytes.length-1)});
  }
  const id=url.split('/files/')[1]?.split('?')[0];return files.has(id)?response(200,files.get(id)):response(404);
 };
 function context(){const c=vm.createContext({JSON,Number,String,Object,Array,Error,PropertiesService:{getScriptProperties:()=>({getProperty:k=>props.get(k)||null,setProperty:(k,v)=>props.set(k,v),deleteProperty:k=>props.delete(k),getProperties:()=>Object.fromEntries(props)})},LockService:{getScriptLock:()=>({waitLock(){},releaseLock(){}})},Utilities:{DigestAlgorithm:{SHA_256:'sha256'},computeDigest:(_,b)=>[...crypto.createHash('sha256').update(typeof b==='string'?b:Buffer.from(b)).digest()],base64Decode:b=>[...Buffer.from(b,'base64')]},ScriptApp:{getOAuthToken:()=> 'PRIVATE_TOKEN'},UrlFetchApp:{fetch},VS_managedRoot:()=>folder,VS_managedFolder:()=>folder,VS_layoutUploadFolders:()=>[folder],VS_managedFile:id=>({getParents:()=>({next:()=>folder}),getBlob:()=>({getBytes:()=>[...sessions.get(id).bytes]})})});vm.runInContext(source,c);return c;}
 let c=context();return {call:b=>c.VS_managedResumableUpload(b),restart:()=>{c=context();},props,sessions,files,get allocated(){return allocated;},get creates(){return creates;},get puts(){return puts;},set lost(v){lost=v;},set corrupt(v){corrupt=v;},set evil(v){evil=v;}};
}
const bytes=Buffer.alloc(700000,65),base={uploadKey:'durable-original-key',name:'original.pdf',mime:'application/pdf',sha256:hash(bytes),sizeBytes:bytes.length};
function part(offset,end=bytes.length,input=bytes){const b=input.subarray(offset,end);return {...base,operation:'part',offset,base64:b.toString('base64'),chunkSha256:hash(b)};}
test('lost chunk and final ACK resume across Script restart with one file identity',()=>{
 const f=fixture();assert.equal(f.call({...base,operation:'begin'}).offset,0);
 f.lost=true;assert.throws(()=>f.call(part(0,524288)));f.restart();assert.equal(f.call({...base,operation:'begin'}).offset,524288);assert.equal(f.puts,1);
 f.lost=true;assert.throws(()=>f.call(part(524288)));f.restart();const out=f.call({...base,operation:'begin'});assert.equal(out.committed,true);assert.equal(out.sha256,base.sha256);assert.equal(f.allocated,1);assert.equal(f.puts,2);
 assert(!JSON.stringify(out).includes('PRIVATE'));assert(!JSON.stringify(out).includes('upload_id'));assert.equal(f.call({...base,operation:'begin'}).fileId,out.fileId);assert.equal(f.allocated,1);
});
test('expired provider session restarts with the same allocated file ID',()=>{const f=fixture();f.call({...base,operation:'begin'});f.sessions.clear();assert.equal(f.call({...base,operation:'status'}).offset,0);assert.equal(f.allocated,1);assert.equal(f.creates,2);});
test('key collision, invalid chunk hash and stale offset never append bytes',()=>{const f=fixture();f.call({...base,operation:'begin'});assert.throws(()=>f.call({...base,operation:'begin',sha256:'0'.repeat(64)}));assert.throws(()=>f.call({...part(0,524288),chunkSha256:'0'.repeat(64)}));const stale=f.call(part(524288));assert.equal(stale.offset,0);assert.equal(f.puts,0);});
test('final metadata and full-content hash are required before a committed receipt',()=>{const f=fixture();f.call({...base,operation:'begin'});f.call(part(0,524288));f.corrupt=true;assert.throws(()=>f.call(part(524288)),/content verification/);assert([...f.props.keys()].some(k=>k.startsWith('VS_UPLOAD_SESSION_')));});
test('provider session URL cannot redirect a school token to another host',()=>{const f=fixture();f.evil=true;assert.throws(()=>f.call({...base,operation:'begin'}),/Invalid private upload session/);assert.equal(f.puts,0);});
test('school binding changes cannot reuse a previous school session',()=>{const f=fixture();f.call({...base,operation:'begin'});const key=[...f.props.keys()].find(k=>k.startsWith('VS_UPLOAD_SESSION_'));const s=JSON.parse(f.props.get(key));s.schoolId='foreign';f.props.set(key,JSON.stringify(s));assert.throws(()=>f.call({...base,operation:'status'}),/collision/);assert.equal(f.puts,0);});

test('native upload stays disabled until the school owner opts in',()=>{const f=fixture();f.props.delete('VS_NATIVE_RESUMABLE_UPLOAD');assert.throws(()=>f.call({...base,operation:'begin'}),/owner opt-in/);assert.equal(f.allocated,0);});

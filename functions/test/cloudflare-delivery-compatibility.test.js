'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),{createHash}=require('node:crypto');
const {fixture,A}=require('./helpers/managed-school-broker');
function setup({native=false,enabled=true}={}){
 const actions=[],commands=[];let manifest;
 const edge={enabled:()=>true,rpc:async(school,lane,body)=>{
  assert.equal(school,A);commands.push(body.command);
  if(body.command==='putSmall'){manifest={...body.manifest,received:Buffer.from(body.base64,'base64').length};return {id:body.id,state:'pending',manifest};}
  if(body.command==='begin'){manifest??={...body.manifest,received:0};return {state:'receiving',manifest};}
  if(body.command==='part'){manifest.received+=Buffer.from(body.base64,'base64').length;return {state:'pending',manifest};}
  if(body.command==='status')return {state:'pending',manifest,due:Date.now(),response:null};
  throw Error('Unexpected edge command');
 }};
 const f=fixture(async(_,options)=>{
  const outer=JSON.parse(options.body),body=JSON.parse(outer.payload);actions.push(body.action);
  return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:outer.schoolId,
   ...(body.action==='managed_health'?{storageReady:true,uploadResumableVersion:native?1:0}:
    {fileId:'real-legacy-drive-file',fileUrl:'https://drive.google.com/file/d/real-legacy-drive-file/view'})})};
 },{cloudflareSync:edge,cloudflareAllDataEnabled:enabled});
 return {...f,actions,commands};
}
const upload={action:'managed/file/upload',name:'Synthetic.pdf',mime:'application/pdf',base64:'YWJj',uploadKey:'stable-owner-upload-00001',edgeDeliveryVersion:1};
test('older full-upload-only Script keeps its real verified path and never stages an undrainable file',async()=>{
 const f=setup();for(let i=0;i<2;i++){
  const result=await f.call(upload);assert.equal(result.fileId,'real-legacy-drive-file');assert.equal(result.delivery,undefined);
 }
 assert.deepEqual(f.commands,[]);assert.deepEqual(f.actions,['managed_health','managed_upload','managed_upload']);
});
test('verified native-capable Script stages file bytes before any permanent upload',async()=>{
 const f=setup({native:true});const result=await f.call(upload);
 assert.equal(result.driveState,'pending');assert.equal(result.fileId,undefined);assert.equal(result.cloudflareAccepted,true);
 assert.deepEqual(f.actions,['managed_health']);assert.deepEqual(f.commands,['begin','part','status']);
});
test('legacy caller preserves original full upload without a new capability dependency',async()=>{
 const f=setup({native:true});const {edgeDeliveryVersion,...legacy}=upload;
 assert.equal((await f.call(legacy)).fileId,'real-legacy-drive-file');
 assert.deepEqual(f.actions,['managed_upload']);assert.deepEqual(f.commands,[]);
});
test('admission rollback preserves verified full uploads without a new health probe',async()=>{
 const f=setup({native:true,enabled:false});assert.equal((await f.call(upload)).fileId,'real-legacy-drive-file');
 assert.deepEqual(f.actions,['managed_upload']);assert.deepEqual(f.commands,[]);
});

const chunk=Buffer.from('synthetic TEST school image bytes'),sha=createHash('sha256').update(chunk).digest('hex');
const resumable={action:'managed/file/upload/resumable',operation:'begin',uploadKey:'stable-image-session-00001',
 name:'test_portrait.jpg',mime:'image/jpeg',sha256:sha,sizeBytes:chunk.length,edgeDeliveryVersion:1};
test('Cloudflare-capable school starts portrait manifest and bytes on the same edge owner, never Script',async()=>{
 const f=setup({native:true});
 const begin=await f.call(resumable);
 assert.equal(begin.cloudflareAccepted,true);
 assert.equal(begin.driveState,'receiving');
 assert.equal(begin.offset,0);
 const part=await f.call({...resumable,operation:'part',offset:0,base64:chunk.toString('base64'),chunkSha256:sha});
 assert.equal(part.cloudflareAccepted,true);
 assert.equal(part.driveState,'pending');
 assert.equal(part.fileId,undefined,'A Cloudflare ACK is not a Google Drive file ID');
 assert.deepEqual(f.actions,['managed_health'],'verified health is cached across begin and part');
 assert.deepEqual(f.commands,['begin','begin','part','status']);
});
test('older school Script cannot split a Cloudflare-opted resumable portrait between Script and edge',async()=>{
 const f=setup({native:false});
 await assert.rejects(f.call(resumable),e=>e.status===503&&e.code==='EDGE_UPLOAD_PROVIDER_UNVERIFIED');
 await assert.rejects(f.call({...resumable,operation:'part',offset:0,base64:chunk.toString('base64'),chunkSha256:sha}),e=>e.code==='EDGE_UPLOAD_PROVIDER_UNVERIFIED');
 assert.deepEqual(f.actions,['managed_health'],'no direct Script upload session was started');
 assert.deepEqual(f.commands,[],'no edge chunks accepted without a drainable provider');
});

test('feature-gated small portrait uses one atomic Durable Object RPC without forged Drive success',async()=>{
 const f=setup({native:true});
 const {createCloudflareDelivery}=require('../cloudflare-delivery');
 const body={action:'managed_upload',uploadKey:'atomic-photo-owner-00001',name:'portrait.jpg',mime:'image/jpeg',base64:Buffer.from('small-image').toString('base64')};
 const upload=createCloudflareDelivery({edge:{rpc:async(_school,_lane,b)=>{
  assert.equal(b.command,'putSmall');const bytes=Buffer.from(b.base64,'base64');
  return {id:b.id,state:'pending',manifest:{...b.manifest,received:bytes.length}};
 }},atomicSmallFilesEnabled:true});
 const pending=await upload.wholeFile(A,body);
 assert.equal(pending.cloudflareAccepted,true);
 assert.equal(pending.driveState,'pending');
 assert.equal(pending.fileId,undefined);
 assert.equal(pending.delivery.lane,'file-'+pending.delivery.id);
});
test('small-file optimization remains disabled until the exact Worker version is enabled',async()=>{
 const {createCloudflareDelivery}=require('../cloudflare-delivery');
 const commands=[],bytes=Buffer.from('test photo'),key='school-photo-owner-test-1';let manifest;
 const edge={rpc:async(school,lane,b)=>{
  commands.push(b.command);
  if(b.command==='begin'){manifest={...b.manifest,received:0};return {state:'receiving',manifest};}
  if(b.command==='part')return {state:'pending',manifest:{...manifest,received:bytes.length}};
  if(b.command==='status')return {state:'pending',manifest:{...manifest,received:bytes.length},due:Date.now()};
  throw Error('Unexpected command');
 }};
 manifest={uploadKey:key,sha256:createHash('sha256').update(bytes).digest('hex'),sizeBytes:bytes.length,name:'pic.jpg',mime:'image/jpeg'};
 const adapter=createCloudflareDelivery({edge,atomicSmallFilesEnabled:false});
 await adapter.wholeFile(A,{...manifest,base64:bytes.toString('base64')});
 assert.deepEqual(commands,['begin','part','status']);
});

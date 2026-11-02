'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),{createHash}=require('node:crypto');
const {fixture,A}=require('./helpers/managed-school-broker');
function setup({native=false,enabled=true}={}){
 const actions=[],commands=[];let manifest;
 const edge={enabled:()=>true,rpc:async(school,lane,body)=>{
  assert.equal(school,A);commands.push(body.command);
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

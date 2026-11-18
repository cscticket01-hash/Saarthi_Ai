'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {createHash}=require('node:crypto');
const {createCloudflareDelivery}=require('../cloudflare-delivery');
const hash=x=>createHash('sha256').update(x).digest('hex');
const school='vs-'+'a'.repeat(32),bytes=Buffer.from('%PDF-1.7\nReplacement\n%%EOF');
const sha=hash(bytes),id='DOC-replacement-original-1';
const operationId='document-replacement-operation-00001';
const uploadKey=hash(id+':'+operationId);
const fileId=hash(JSON.stringify([school,uploadKey])),lane='file-'+fileId;
const document={version:1,schoolId:school,id,operationId,
 expectedRevision:'document-original-generation-001',
 expectedRecordRevision:'google-original-revision-001',expectedUploadedAt:1690000000000,
 data:{schoolId:school,documentId:id,documentRevision:operationId,
  studentId:'same-student',fileName:'replacement.pdf',mimeType:'application/pdf',
  contentHash:sha,uploadedAt:1700000000000}};
const request={uploadKey,name:'replacement.pdf',mime:'application/pdf',
 base64:bytes.toString('base64'),document};
function fake(){
 const manifest={uploadKey,sha256:sha,sizeBytes:bytes.length,
  name:request.name,mime:request.mime,document};
 const row={id:fileId,state:'pending',created:1000,payload:JSON.stringify({...manifest,received:bytes.length}),
 response:null,manifest:{...manifest,received:bytes.length}};
 const edge={rpc:async(s,l,b)=>{
  assert.equal(s,school);assert.equal(l,lane);
  if(b.command==='begin')return{id:fileId,state:'receiving',manifest:{...manifest,received:0}};
  if(b.command==='part')return{id:fileId,state:'pending',manifest:row.manifest};
  if(b.command==='status')return row;
  if(b.command==='pending')return ['pending','retry'].includes(row.state)?[{...row,response:row.response?JSON.stringify(row.response):null}]:[];
  if(b.command==='claim')return true;
  if(b.command==='readPart')return {offset:0,sizeBytes:bytes.length,base64:request.base64,sha256:sha};
  if(b.command==='finish'){row.state=b.values.state;row.response=b.values;return true;}
  throw Error('unexpected edge command '+b.command);
 }};
 return{edge,row};
}
const drive={success:true,schoolId:school,uploadResumableVersion:1,
 uploadKey,sha256:sha,sizeBytes:bytes.length,offset:bytes.length,
 committed:true,fileId:'real_replacement_drive_file'};
const old={schoolId:school,id,documentRevision:document.expectedRevision,
 studentId:'same-student',uploadedAt:document.expectedUploadedAt,
 _syncRevision:document.expectedRecordRevision};
const newRecord={...document.data,id,fileId:drive.fileId,
 fileUrl:'https://drive.google.com/file/d/'+drive.fileId+'/view',
 _syncRevision:'real-new-record-revision',_syncOperationId:operationId};
test('document replacement performs owner CAS after Cloudflare staging',async()=>{
 const {edge,row}=fake(),delivery=createCloudflareDelivery({edge,now:()=>2000});
 const accepted=await delivery.wholeFile(school,request);
 assert.equal(accepted.cloudflareAccepted,true);
 assert.equal(accepted.driveState,'pending');
 const actions=[];
 const done=await delivery.drain(school,lane,async r=>{
  actions.push(r.action+':'+r.operation);
  if(r.action==='managed_upload_resumable')
   return r.operation==='begin'?{...drive,offset:0,committed:false,fileId:undefined}:drive;
  if(r.operation==='read')return{success:true,schoolId:school,
   syncProtocol:2,pointRead:true,records:{[id]:old}};
  assert.equal(r.action,'managed_records');
  assert.equal(r.operationId,operationId);
  assert.equal(r.expectedRecordRevision,document.expectedRecordRevision);
  assert.equal(r.expectedRevision,document.expectedRevision);
  assert.equal(r.expectedUploadedAt,document.expectedUploadedAt);
  assert.equal(r.data.fileId,drive.fileId);
  return{success:true,schoolId:school,syncProtocol:2,
   recordRevision:'real-new-record-revision',record:newRecord};
 });
 assert.equal(done.processed,1);
 assert.deepEqual(actions,['managed_upload_resumable:begin','managed_upload_resumable:part',
   'managed_records:read','managed_records:write']);
 assert.equal(row.state,'completed');
});
test('changed original owner blocks replacement without erasing staged bytes',async()=>{
 const {edge,row}=fake(),delivery=createCloudflareDelivery({edge,now:()=>2000});
 await delivery.wholeFile(school,request);
 let writes=0;
 await delivery.drain(school,lane,async r=>{
  if(r.action==='managed_upload_resumable')
   return r.operation==='begin'?{...drive,offset:0,committed:false,fileId:undefined}:drive;
  if(r.operation==='read')return{success:true,schoolId:school,
   syncProtocol:2,pointRead:true,records:{[id]:{...old,studentId:'other-student'}}};
  writes++;throw Error('must not publish altered owner');
 });
 assert.equal(writes,0);
 assert.equal(row.state,'needsAttention');
});
test('provider read outage retains the original operation for retry',async()=>{
 const {edge,row}=fake(),delivery=createCloudflareDelivery({edge,now:()=>2000});
 await delivery.wholeFile(school,request);
 await delivery.drain(school,lane,async r=>{
  if(r.action==='managed_upload_resumable')
   return r.operation==='begin'?{...drive,offset:0,committed:false,fileId:undefined}:drive;
  throw Object.assign(Error('Drive temporarily unavailable'),{status:503,code:'SCRIPT_TIMEOUT'});
 });
 assert.equal(row.state,'retry');
});
test('lost Google ACK is recovered from the exact signed record proof',async()=>{
 const {edge,row}=fake(),delivery=createCloudflareDelivery({edge,now:()=>2000});
 await delivery.wholeFile(school,request);
 let writes=0,reads=0;
 const done=await delivery.drain(school,lane,async r=>{
  if(r.action==='managed_upload_resumable')
   return r.operation==='begin'?{...drive,offset:0,committed:false,fileId:undefined}:drive;
  if(r.operation==='read'){
   reads++;
   return{success:true,schoolId:school,syncProtocol:2,pointRead:true,
    records:{[id]:newRecord}};
  }
  writes++;throw Error('must not duplicate already committed Google write');
 });
 assert.equal(done.processed,1);
 assert.equal(reads,1);
 assert.equal(writes,0);
 assert.equal(row.state,'completed');
});
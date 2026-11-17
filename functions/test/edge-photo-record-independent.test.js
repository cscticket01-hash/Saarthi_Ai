'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createHash}=require('node:crypto');
const {createCloudflareDelivery}=require('../cloudflare-delivery');
const hash=b=>createHash('sha256').update(b).digest('hex');
const school='vs-'+'a'.repeat(32),foreign='vs-'+'b'.repeat(32);
const bytes=Buffer.from([0xff,0xd8,0xff,0x00,0xff,0xd9]);
const sha=hash(bytes),sourceHash=hash('unchanged original portrait');
const id='student-portrait-cas-1',operationId='original-person-photo-operation-12345';
const key=hash(JSON.stringify([school,'students_directory',id,operationId,sha]));
const laneId=hash(JSON.stringify([school,key])),lane='file-'+laneId;
const record={version:1,schoolId:school,collection:'students_directory',id,
 operation:'write',operationId,expectedRecordRevision:'',
 mediaPrefix:'photo',sourceHash,
 data:{schoolId:school,studentId:id,name:'Original student',photoSourceHash:sourceHash}};
const request={operation:'part',uploadKey:key,sha256:sha,
 sizeBytes:bytes.length,name:'photo.jpg',mime:'image/jpeg',
 record,offset:0,base64:bytes.toString('base64'),chunkSha256:sha};
function fake(){
 const calls=[],manifest={uploadKey:key,sha256:sha,sizeBytes:bytes.length,
  name:request.name,mime:request.mime,record};
 const row={id:laneId,state:'pending',due:0,created:1000,response:null,
  payload:JSON.stringify({...manifest,received:bytes.length}),
  manifest:{...manifest,received:bytes.length}};
 return {calls,row,edge:{rpc:async(s,l,b)=>{
   assert.equal(s,school);assert.equal(l,lane);calls.push(b.command);
   switch(b.command){
    case 'begin':return{id:laneId,state:'receiving',manifest:{...manifest,received:0}};
    case 'part':assert.equal(b.offset,0);assert.equal(b.chunkSha256,sha);
     return{id:laneId,state:'pending',manifest:row.manifest};
    case 'status':return row;
    case 'pending':return row.state==='pending'||row.state==='retry'?
      [{...row,response:row.response?JSON.stringify(row.response):null}]:[];
    case 'claim':return true;
    case 'readPart':return{offset:0,sizeBytes:bytes.length,base64:request.base64,sha256:sha};
    case 'finish':row.state=b.values.state;row.response=b.values;return true;
    default:throw Error('Unexpected edge RPC '+b.command);
   }
 }}};
}
const fileAck={success:true,schoolId:school,uploadResumableVersion:1,
 uploadKey:key,sha256:sha,sizeBytes:bytes.length,offset:bytes.length,
 committed:true,fileId:'verified_Original_Portrait'};
const photoRecord={...record.data,id,photoFileId:fileAck.fileId,
 photoUrl:'https://drive.google.com/file/d/'+fileAck.fileId+'/view',
 _syncOperationId:operationId,_syncRevision:'real-school-record-revision-01'};
const recordAck={success:true,schoolId:school,syncProtocol:2,
 recordRevision:'real-school-record-revision-01',record:photoRecord};
test('original photo+record gets one durable Cloudflare ACK and later server-only Drive proof',async()=>{
 const {edge,row,calls}=fake(),delivery=createCloudflareDelivery({edge,now:()=>2000});
 const accepted=await delivery.file(school,request);
 assert.equal(accepted.success,true);
 assert.equal(accepted.driveState,'pending');
 assert.equal(accepted.fileId,undefined);
 assert.equal(accepted.delivery.id,laneId);
 assert.deepEqual(calls,['begin','part','status']);
 let mediaWritten=false;
 const drained=await delivery.drain(school,lane,async body=>{
  if(body.action==='managed_upload_resumable')
   return body.operation==='begin'?{...fileAck,offset:0,committed:false,fileId:undefined}:fileAck;
  assert.equal(body.action,'managed_records');
  assert.equal(body.collection,record.collection);
  assert.equal(body.id,id);
  assert.equal(body.operationId,operationId);
  assert.equal(body.expectedRecordRevision,'');
  assert.equal(body.data.photoFileId,fileAck.fileId);
  assert.equal(body.data.photoSourceHash,sourceHash);
  assert.equal(body.data.photoUrl,photoRecord.photoUrl);
  mediaWritten=true;return recordAck;
 });
 assert.equal(drained.processed,1);
 assert.equal(mediaWritten,true);
 assert.equal(row.state,'completed');
 assert.deepEqual(row.response.result.mediaRecord,{
  collection:record.collection,id,operationId,
  recordRevision:recordAck.recordRevision,fileId:fileAck.fileId,
  sourceHash,fileSha256:sha});
 const verified=await delivery.status(school,lane,laneId);
 assert.equal(verified.driveState,'verified');
 assert.equal(verified.mediaRecord.fileId,fileAck.fileId);
});
test('Google record write failure keeps original staged portrait for background retry',async()=>{
 const {edge,row}=fake(),delivery=createCloudflareDelivery({edge,now:()=>2000});
 await delivery.file(school,request);
 await delivery.drain(school,lane,async body=>{
  if(body.action==='managed_upload_resumable')
   return body.operation==='begin'?{...fileAck,offset:0,committed:false,fileId:undefined}:fileAck;
  throw Object.assign(Error('provider unavailable'),{status:503,code:'SCRIPT_TIMEOUT'});
 });
 assert.equal(row.state,'retry');
 assert.equal((await delivery.status(school,lane,laneId)).driveState,'pending');
 const done=await delivery.drain(school,lane,async body=>
  body.action==='managed_upload_resumable'?fileAck:recordAck);
 assert.equal(done.processed,1);
 assert.equal(row.state,'completed');
});
test('wrong school and fabricated original portrait file identity fail closed',async()=>{
 const {edge,calls}=fake(),delivery=createCloudflareDelivery({edge});
 await assert.rejects(delivery.file(school,{...request,record:{...record,schoolId:foreign}}),/Cloud delivery pending/);
 await assert.rejects(delivery.file(school,{...request,record:{...record,data:{...record.data,photoFileId:'fake'}}}),/Cloud delivery pending/);
 await assert.rejects(delivery.file(school,{...request,record:{...record,data:{...record.data,photoSourceHash:'0'.repeat(64)}}}),/Cloud delivery pending/);
 assert.deepEqual(calls,[]);
});

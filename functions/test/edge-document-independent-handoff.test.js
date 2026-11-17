'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createHash}=require('node:crypto');
const {createCloudflareDelivery}=require('../cloudflare-delivery');

const school='vs-'+'a'.repeat(32),other='vs-'+'b'.repeat(32);
const bytes=Buffer.from('%PDF-1.7\nCloudflare-backed school document\n%%EOF\n');
const sha=createHash('sha256').update(bytes).digest('hex');
const documentId='DOC-independent-backup-001';
const operationId='document-generation-00000001';
const uploadKey=createHash('sha256').update(documentId+':'+operationId).digest('hex');
const document={version:1,schoolId:school,id:documentId,operationId,
 expectedRecordRevision:'',data:{schoolId:school,documentId,documentRevision:operationId,
 studentId:'student-1',documentKind:'marksheet',fileName:'sample.pdf',mimeType:'application/pdf',
 contentHash:sha,uploadedAt:1700000000000}};
const request={uploadKey,name:'sample.pdf',mime:'application/pdf',
 base64:bytes.toString('base64'),document};
const digest=value=>createHash('sha256').update(value).digest('hex');
const id=digest(JSON.stringify([school,uploadKey])),lane='file-'+id;

function mockEdge(){
 const calls=[];
 const manifest={uploadKey,sha256:sha,sizeBytes:bytes.length,
  name:request.name,mime:request.mime,document};
 const row={id,state:'pending',created:1000,payload:JSON.stringify({...manifest,received:bytes.length}),response:null,
  manifest:{...manifest,received:bytes.length}};
 const edge={rpc:async(s,l,b)=>{
  assert.equal(s,school);assert.equal(l,lane);calls.push(b.command);
  switch(b.command){
   case 'begin':return {id,state:'receiving',manifest:{...manifest,received:0}};
   case 'part':
    assert.equal(b.offset,0);assert.equal(b.base64,request.base64);
    return {id,state:'pending',manifest:{...manifest,received:bytes.length}};
   case 'status':return row;
   case 'pending':return ['pending','retry'].includes(row.state)?[{...row,response:row.response?JSON.stringify(row.response):null}]:[];
   case 'claim':return true;
   case 'readPart':return {offset:b.offset,sizeBytes:bytes.length,
    base64:request.base64,sha256:sha};
   case 'finish':row.state=b.values.state;row.response=b.values;return true;
   default:throw Error('Unexpected Cloudflare command '+b.command);
  }
 }};
 return {edge,row,calls};
}
const driveResult={success:true,schoolId:school,uploadResumableVersion:1,
 uploadKey,sha256:sha,sizeBytes:bytes.length,offset:bytes.length,
 committed:true,fileId:'realDriveFileId_1'};
const recordAck={success:true,schoolId:school,syncProtocol:2,
 recordRevision:'google-record-revision-1',
 record:{...document.data,id:documentId,schoolId:school,
  fileId:driveResult.fileId,fileUrl:'https://drive.google.com/file/d/'+driveResult.fileId+'/view',
  _syncOperationId:operationId,_syncRevision:'google-record-revision-1'}};

test('document submission ACK is durable Cloudflare only; Drive runs later without app',async()=>{
 const {edge,row,calls}=mockEdge(),delivery=createCloudflareDelivery({edge,now:()=>2000});
 const accepted=await delivery.wholeFile(school,request);
 assert.equal(accepted.cloudflareAccepted,true);
 assert.equal(accepted.driveState,'pending');
 assert.equal(accepted.fileId,undefined);
 assert.equal(accepted.delivery.lane,lane);
 assert.deepEqual(calls,['begin','part','status']);
 let written=false;
 const result=await delivery.drain(school,lane,async outgoing=>{
  if(outgoing.action==='managed_upload_resumable'){
   if(outgoing.operation==='begin')return {...driveResult,offset:0,committed:false,fileId:undefined};
   assert.equal(outgoing.operation,'part');return driveResult;
  }
  assert.equal(outgoing.action,'managed_records');
  assert.equal(outgoing.collection,'documents');
  assert.equal(outgoing.operationId,operationId);
  assert.equal(outgoing.expectedRecordRevision,'');
  assert.equal(outgoing.data.contentHash,sha);
  assert.equal(outgoing.data.fileId,driveResult.fileId);
  written=true;return recordAck;
 });
 assert.equal(result.processed,1);
 assert.equal(written,true);
 assert.equal(row.state,'completed');
 assert.equal(row.response.result.documentRecord.recordRevision,'google-record-revision-1');
 const verified=await delivery.status(school,lane,id);
 assert.equal(verified.driveState,'verified');
 assert.equal(verified.documentRecord.fileId,driveResult.fileId);
});

test('provider document write failure never completes file job or discards original',async()=>{
 const {edge,row}=mockEdge(),delivery=createCloudflareDelivery({edge,now:()=>100000});
 let attempt=0;
 await delivery.drain(school,lane,async outgoing=>{
  if(outgoing.action==='managed_upload_resumable'){
   if(outgoing.operation==='begin')return {...driveResult,offset:0,committed:false,fileId:undefined};
   return driveResult;
  }
  attempt++;throw Object.assign(Error('Google unavailable'),{status:503,code:'SCRIPT_TIMEOUT'});
 });
 assert.equal(attempt,1);
 assert.equal(row.state,'retry');
 assert.equal(row.response.result,undefined);
 assert.equal((await delivery.status(school,lane,id)).driveState,'pending');
 row.state='retry';row.payload=JSON.stringify({...JSON.parse(row.payload)});
 const retried=await delivery.drain(school,lane,async outgoing=>{
  if(outgoing.action==='managed_upload_resumable')return driveResult;
  return recordAck;
 });
 assert.equal(retried.processed,1);
 assert.equal(row.state,'completed');
 assert.equal((await delivery.status(school,lane,id)).driveState,'verified');
});

test('sidecar identity and content are fail-closed before any Cloudflare write',async()=>{
 const {edge,calls}=mockEdge(),delivery=createCloudflareDelivery({edge});
 await assert.rejects(delivery.wholeFile(school,{
  ...request,document:{...document,schoolId:other}}),/Cloud delivery pending/);
 await assert.rejects(delivery.wholeFile(school,{
  ...request,document:{...document,data:{...document.data,contentHash:'0'.repeat(64)}}}),/Cloud delivery pending/);
 await assert.rejects(delivery.wholeFile(school,{
  ...request,document:{...document,data:{...document.data,fileId:'forged-id'}}}),/Cloud delivery pending/);
 assert.deepEqual(calls,[]);
});

test('a forged metadata ACK does not count as completed Drive backup',async()=>{
 const {edge,row}=mockEdge(),delivery=createCloudflareDelivery({edge,now:()=>100000});
 await delivery.drain(school,lane,async outgoing=>{
  if(outgoing.action==='managed_upload_resumable'){
   return outgoing.operation==='begin'?{...driveResult,offset:0,committed:false,fileId:undefined}:driveResult;
  }
  if(outgoing.operation==='read')return {success:true,schoolId:school,syncProtocol:2,
   records:{[documentId]:{...recordAck.record,fileId:'wrong-file'}}};
  return {...recordAck,record:{...recordAck.record,fileId:'wrong-file'}};
 });
 assert.equal(row.state,'retry');
 assert.equal((await delivery.status(school,lane,id)).driveState,'pending');
});

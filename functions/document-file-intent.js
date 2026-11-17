'use strict';
const {createHash}=require('node:crypto');
const SCHOOL=/^vs-[a-f0-9]{32}$/;
const OP=/^[A-Za-z0-9_-]{16,100}$/;
const FILE=/^[A-Za-z0-9_-]{1,200}$/;
function fail(code){throw Object.assign(Error('Cloud document owner needs immutable proof.'),{status:409,code,publicMessage:true});}
function validateIntent(school,request){
 const intent=request?.documentIntent;
 if(intent===undefined)return null;
 const data=intent?.data,raw=JSON.stringify(intent);
 if(!SCHOOL.test(school)||!intent||typeof intent!=='object'||Array.isArray(intent)||
    intent.version!==1||intent.schoolId!==school||intent.collection!=='documents'||
    intent.operation!=='write'||intent.syncProtocol!==2||
    !FILE.test(intent.id||'')||!OP.test(intent.operationId||'')||
    typeof intent.expectedRecordRevision!=='string'||
    intent.expectedRecordRevision.length>100||
    typeof intent.expectedDocumentRevision!=='string'||
    intent.expectedDocumentRevision.length>100||
    raw.length>16000||!data||typeof data!=='object'||Array.isArray(data)||
    data.schoolId!==school||data.documentId!==intent.id||
    data.documentRevision!==intent.operationId||
    data.contentHash!==request.sha256||
    (typeof data.fileName!=='string'||!data.fileName||data.fileName.length>200)||data.mimeType!==request.mime||
    data.fileId!==undefined||data.fileUrl!==undefined||
    Object.keys(data).some(k=>k.startsWith('_sync')||
      /base64|localpath|password/i.test(k))||
    data.studentId==null||typeof data.studentId!=='string'||!data.studentId||
    typeof data.uploadedAt!=='number'||!Number.isSafeInteger(data.uploadedAt)||
    data.uploadedAt<=0||
    (intent.expectedUploadedAt!==undefined&&
      (!Number.isSafeInteger(intent.expectedUploadedAt)||intent.expectedUploadedAt<0)))
   fail('EDGE_DOCUMENT_INTENT_INVALID');
 return {
  version:1,schoolId:school,collection:'documents',operation:'write',
  syncProtocol:2,id:intent.id,operationId:intent.operationId,
  expectedRecordRevision:intent.expectedRecordRevision,
  expectedDocumentRevision:intent.expectedDocumentRevision,
  ...(intent.expectedUploadedAt===undefined?{}:{expectedUploadedAt:intent.expectedUploadedAt}),
  data:Object.fromEntries(Object.entries(data).sort(([a],[b])=>a.localeCompare(b))),
 };
}
function recordRequest(school,manifest,file){
 const intent=validateIntent(school,{...manifest,documentIntent:manifest.documentIntent});
 if(!intent||!file||!/^[A-Za-z0-9_-]{1,200}$/.test(file.fileId||'')||
    file.sha256!==manifest.sha256||file.uploadKey!==manifest.uploadKey||
    file.sizeBytes!==manifest.sizeBytes||file.committed!==true)
    fail('EDGE_DOCUMENT_FILE_UNVERIFIED');
 const url='https://drive.google.com/file/d/'+file.fileId+'/view';
 return {
  action:'managed_records',operation:'write',collection:'documents',
  id:intent.id,operationId:intent.operationId,syncProtocol:2,
  expectedRecordRevision:intent.expectedRecordRevision,
  expectedRevision:intent.expectedDocumentRevision,
  ...(intent.expectedUploadedAt===undefined?{}:{expectedUploadedAt:intent.expectedUploadedAt}),
  data:{...intent.data,fileId:file.fileId,fileUrl:url},
 };
}
function verifyDocumentAck(school,manifest,file,request,ack){
 const intent=manifest.documentIntent,row=ack?.record;
 if(!intent||request?.collection!=='documents'||request.operation!=='write'||
    request.id!==intent.id||request.operationId!==intent.operationId||
    request.data?.fileId!==file.fileId||
    ack?.success!==true||ack.schoolId!==school||ack.syncProtocol!==2||
    typeof ack.recordRevision!=='string'||!ack.recordRevision||
    /^(live-|cf-)/.test(ack.recordRevision)||
    !row||row.schoolId!==school||
    row._syncRevision!==ack.recordRevision||
    row._syncOperationId!==intent.operationId||
    (row.id!==undefined&&row.id!==intent.id)||
    row.documentRevision!==intent.operationId||
    row.fileId!==file.fileId||
    row.fileUrl!==request.data.fileUrl||
    row.contentHash!==manifest.sha256)
   fail('EDGE_DOCUMENT_DRIVE_ACK_UNVERIFIED');
 return {
  version:1,schoolId:school,id:intent.id,
  documentRevision:intent.operationId,
  operationId:intent.operationId,
  recordRevision:ack.recordRevision,
  record:{...row,id:intent.id},
 };
}
module.exports={validateIntent,recordRequest,verifyDocumentAck};

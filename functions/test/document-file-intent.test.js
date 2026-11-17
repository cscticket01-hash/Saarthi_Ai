'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const crypto=require('node:crypto');
const {validateIntent,recordRequest,verifyDocumentAck}=require('../document-file-intent');
const school='vs-'+'a'.repeat(32),other='vs-'+'b'.repeat(32);
const bytes=Buffer.from('%PDF- test document\n%%EOF');
const sha=crypto.createHash('sha256').update(bytes).digest('hex');
const manifest={name:'Document.pdf',mime:'application/pdf',uploadKey:'immutable-document-upload-000001',
 sizeBytes:bytes.length,sha256:sha};
const intent={version:1,schoolId:school,collection:'documents',
 operation:'write',id:'DOC-1',operationId:'document-revision-00001',syncProtocol:2,
 expectedRecordRevision:'',expectedDocumentRevision:'',
 data:{schoolId:school,documentId:'DOC-1',documentRevision:'document-revision-00001',
  contentHash:sha,studentId:'student-1',fileName:'Document.pdf',
  mimeType:'application/pdf',uploadedAt:1700000000000,documentName:'Test document'}};
const file={uploadKey:manifest.uploadKey,sizeBytes:manifest.sizeBytes,sha256:sha,
 committed:true,fileId:'real-drive-file'};
test('same-school document immutable intent survives stage and Drive file ID later',()=>{
 const normalized=validateIntent(school,{...manifest,documentIntent:intent});
 assert.equal(normalized.operationId,intent.operationId);
 const request=recordRequest(school,{...manifest,documentIntent:normalized},file);
 assert.equal(request.data.fileId,file.fileId);
 assert.equal(request.data.fileUrl,'https://drive.google.com/file/d/real-drive-file/view');
 assert.equal(request.operationId,intent.operationId);
 const ack={success:true,schoolId:school,syncProtocol:2,recordRevision:'gs-revision-001',
  record:{...request.data,_syncRevision:'gs-revision-001',
   _syncOperationId:intent.operationId,id:intent.id}};
 const verified=verifyDocumentAck(school,{...manifest,documentIntent:normalized},file,request,ack);
 assert.equal(verified.recordRevision,'gs-revision-001');
 assert.equal(verified.record.contentHash,sha);
});
test('wrong school, different original, spoofed file URL or missing provider proof fails closed',()=>{
 for(const broken of [
  {...intent,schoolId:other},
  {...intent,operationId:'forged-revision-123456'},
  {...intent,data:{...intent.data,contentHash:'0'.repeat(64)}},
  {...intent,data:{...intent.data,fileId:'fake-file'}},
  {...intent,data:{...intent.data,localPath:'C:\\private'}},
  {...intent,data:{...intent.data,studentId:null}},
 ]){
  assert.throws(()=>validateIntent(school,{...manifest,documentIntent:broken}),/immutable proof/);
 }
 const request=recordRequest(school,{...manifest,documentIntent:intent},file);
 const good={success:true,schoolId:school,syncProtocol:2,recordRevision:'gs-revision-001',
  record:{...request.data,_syncRevision:'gs-revision-001',
   _syncOperationId:intent.operationId}};
 for(const bad of [
  {...good,record:null},
  {...good,record:{...good.record,fileId:'other'}},
  {...good,record:{...good.record,_syncOperationId:'foreign-revision'}},
  {...good,record:{...good.record,schoolId:other}},
  {...good,recordRevision:'cf-fake'},
 ]){
  assert.throws(()=>verifyDocumentAck(school,{...manifest,documentIntent:intent},file,request,bad),/immutable proof/);
 }
});
test('regular file uploads remain version-compatible without metadata',()=>{
 assert.equal(validateIntent(school,manifest),null);
});

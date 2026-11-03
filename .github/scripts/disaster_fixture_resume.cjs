'use strict';
const assert = require('node:assert/strict');
async function prepareDisasterFixture(call, identity, schoolId, pdf, report) {
 const id=identity.id,op=id+'-create';
 if(identity.resumed) {
  const snapshot=await call({action:'managed/records',operation:'read',collection:'school_notices',id,syncProtocol:2});
  assert.equal(snapshot.success,true);assert.equal(snapshot.schoolId,schoolId);
  assert.equal(snapshot.syncProtocol,2);assert.equal(snapshot.pointRead,true);
  const row=snapshot.records?.[id];
  report.fixtureResumeProof={exists:!!row,schoolMatches:row?.schoolId===schoolId,
   originalOperationMatches:row?._syncOperationId===op,synthetic:row?.syntheticTest===true};
  assert.ok(row && row.schoolId===schoolId && row.syntheticTest===true && row._syncDeleted!==true);
  assert.equal(row.title,'Disposable disaster recovery fixture');assert.equal(row.capturedAt,12345);
  assert.equal(row._syncOperationId,op);
  assert.ok(typeof row._syncRevision==='string' && row._syncRevision.length>0);
  assert.ok(typeof row.fileId==='string' && row.fileId.length>0);
  assert.ok(row.id===undefined || row.id===id);
  assert.ok(Object.keys(row).every(key=>key.startsWith('_sync') ||
   ['id','schoolId','syntheticTest','title','fileId','capturedAt'].includes(key)));
  const binary=await call({action:'managed/file/read',fileId:row.fileId});
  assert.equal(binary.success,true);assert.equal(binary.schoolId,schoolId);
  assert.equal(typeof binary.base64,'string');
  assert.deepEqual(Buffer.from(binary.base64,'base64'),pdf);
  report.fixtureAckMode='verified_existing_original';
  report.fixtureOriginalDriveBytesVerified=true;
  return {id,op,upload:{fileId:row.fileId},original:{recordRevision:row._syncRevision}};
 }
 const uploadKey=require('node:crypto').createHash('sha256').update(id).digest('hex');
 const upload=await call({action:'managed/file/upload',name:id+'.pdf',mime:'application/pdf',base64:pdf.toString('base64'),uploadKey});
 assert.ok(typeof upload.fileId==='string' && upload.fileId);
 const original=await call({action:'managed/records',operation:'write',collection:'school_notices',id,syncProtocol:2,operationId:op,expectedRecordRevision:'',data:{schoolId,syntheticTest:true,title:'Disposable disaster recovery fixture',fileId:upload.fileId,capturedAt:12345}});
 assert.ok(original.recordRevision);report.fixtureAckMode='fresh_durable_ack';
 return {id,op,upload,original};
}
module.exports={prepareDisasterFixture};

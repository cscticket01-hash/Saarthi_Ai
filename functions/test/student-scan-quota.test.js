'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {storage,A}=require('./helpers/managed-storage');

for(const bundle of [false,true]){
 test('independent PC scan writes share one canonical page and byte limit (bundle='+bundle+')',()=>{
  const f=storage({bundle});
  let serial=0;
  const request=(id,studentId,pages,bytes,old=null,kind='studentDocument')=>{
   const operationId='scan-quota-operation-'+(++serial).toString().padStart(4,'0');
   return {action:'managed_records',collection:'documents',operation:'write',
    id,syncProtocol:2,operationId,expectedRecordRevision:old?.recordRevision||'',
    expectedRevision:old?.record?.documentRevision||'',
    data:{schoolId:A,studentId,documentKind:kind,documentId:id,documentRevision:operationId,
     scanQuotaVersion:1,pageCount:pages,sizeBytes:bytes,mimeType:'application/pdf'}};
  };
  const first=request('pc-a','student-one',4,250*1024),a=f.call(first);
  assert.equal(a.success,true,JSON.stringify(a));
  const second=request('pc-b','student-one',4,250*1024),b=f.call(second);
  assert.equal(b.success,true,JSON.stringify(b));
  assert.equal(f.call(first).success,true,'lost ACK replay must not spend quota twice');
  const refused=f.call(request('pc-c','student-one',1,1));
  assert.equal(refused.success,false);
  assert.equal(refused.code,'SCRIPT_STUDENT_SCAN_LIMIT');
  assert.equal(f.call(request('other-pupil','student-two',8,500*1024)).success,true);
  const reduced=f.call(request('pc-a','student-one',2,100*1024,
    {...a,record:{documentRevision:first.operationId}}));
  assert.equal(reduced.success,true,JSON.stringify(reduced));
  assert.equal(f.call(request('pc-c','student-one',2,150*1024)).success,true);
  const oversized=f.call(request('too-large','student-one',1,1));
  assert.equal(oversized.success,false);
  const records=f.call({action:'managed_records',collection:'documents',operation:'read'}).records;
  assert.equal(records['too-large'],undefined);
  assert.equal(records['pc-a'].pageCount,2);
  assert.equal(records['pc-b'].pageCount,4);
  assert.equal(records['pc-c'].pageCount,2);
 });
 test('legacy PDF page count cannot be guessed (bundle='+bundle+')',()=>{
  const f=storage({bundle});
  const legacy=f.call({action:'managed_records',collection:'documents',operation:'write',
   id:'legacy',expectedRevision:'',data:{schoolId:A,studentId:'student',mimeType:'application/pdf',
    sizeBytes:10000,documentRevision:'legacy'}});
  assert.equal(legacy.success,true);
  const incoming=f.call({action:'managed_records',collection:'documents',operation:'write',
   id:'new-scan',expectedRevision:'',data:{schoolId:A,studentId:'student',mimeType:'image/jpeg',
    sizeBytes:100,pageCount:1,scanQuotaVersion:1,documentRevision:'new'}});
  assert.equal(incoming.success,false);
  assert.equal(incoming.code,'SCRIPT_STUDENT_SCAN_REVIEW');
 });
}

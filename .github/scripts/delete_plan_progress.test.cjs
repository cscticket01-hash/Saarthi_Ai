'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {observeDeletePlan}=require('./delete_plan_progress.cjs');
const {retryExactDelete}=require('./native_person_receipt.cjs');
const school='vs-'+'a'.repeat(32),request={collection:'students_directory',id:'synthetic',
 operation:'delete',syncProtocol:2,deleteEverywhereVersion:1,operationId:'original-delete-operation',
 expectedRecordRevision:'before',deletedStudentGeneration:'p-'+'b'.repeat(64)};
function snapshot(){return {success:true,schoolId:school,syncProtocol:2,pointRead:true,records:{synthetic:{schoolId:school,
 _syncDeleted:true,_syncDeletedOwner:request.deletedStudentGeneration,_syncOperationId:request.operationId,_syncRevision:'deleted',
 _syncErasePlan:{version:1,targets:[{collection:request.collection,id:request.id,sourceRevision:'before',revision:'deleted',generation:request.deletedStudentGeneration}],
 files:['original-file'],cursor:1,fileCursor:1,archiveScan:{root:'school-root',ids:[],stack:[{id:'folder',phase:'files',token:'private-token'}]},archivesComplete:false,complete:false}}}};}
test('large original archive scan continues beyond twelve calls only with observed durable progress',async()=>{
 const reply=snapshot(),progress=[];let n=0;
 const observe=observeDeletePlan(async(collection,id)=>{assert.equal(collection,request.collection);assert.equal(id,request.id);
  reply.records.synthetic._syncErasePlan.archiveScan.stack[0].token='private-token-'+n;return reply;},school,p=>progress.push(p));
 const result=await retryExactDelete(request,async body=>{assert.deepEqual(body,request);
  if(++n<18)throw Object.assign(Error('pending'),{code:'SCRIPT_DELETE_EVERYWHERE_PENDING'});return 'final';
 },{attempts:48,observeProgress:observe,delay:async()=>{}});
 assert.equal(result,'final');assert.equal(n,18);assert.equal(progress.length,17);
 assert(!JSON.stringify(progress).includes('private-token'));assert(!JSON.stringify(progress).includes('original-file'));
});
test('stalled original scan stops without a fabricated ACK or a replacement operation',async()=>{
 let calls=0;const observe=observeDeletePlan(async()=>snapshot(),school);
 await assert.rejects(retryExactDelete(request,async()=>{calls++;throw Object.assign(Error('pending'),{code:'SCRIPT_DELETE_EVERYWHERE_PENDING'});},
  {attempts:48,observeProgress:observe,delay:async()=>{}}),e=>e.code==='SCRIPT_DELETE_NO_PROGRESS');
 assert.equal(calls,4);
});
test('elapsed budget bounds continuation even when every scan cursor changes',async()=>{
 let t=0,calls=0;
 await assert.rejects(retryExactDelete(request,async()=>{calls++;throw Object.assign(Error('pending'),{code:'SCRIPT_TIMEOUT'});},
  {attempts:48,observeProgress:async()=>String(calls),now:()=>t,maxElapsedMs:6000,delay:async ms=>{t+=ms;}}),e=>e.code==='SCRIPT_DELETE_BUDGET_EXHAUSTED');
 assert.equal(calls,2);assert.equal(t,6000);
});
test('extended retries require a signed progress observer and finite budget',async()=>{
 for(const options of [{attempts:48},{attempts:49,observeProgress:async()=>''},{maxElapsedMs:Infinity}])
  await assert.rejects(retryExactDelete(request,async()=>assert.fail('must not submit'),options));
});
test('foreign, replaced, changed, incomplete or regressed original deletion proof stops continuation',async()=>{
 for(const change of [r=>r.schoolId='foreign',r=>r.pointRead=false,r=>r.records.synthetic._syncDeletedOwner='replacement',
  r=>r.records.synthetic._syncOperationId='new-op',r=>r.records.synthetic._syncErasePlan.targets[0].sourceRevision='new-revision',
  r=>r.records.synthetic._syncErasePlan.cursor=2]){
  const r=snapshot();change(r);await assert.rejects(observeDeletePlan(async()=>r,school)(request,1));
 }
 const r=snapshot(),observe=observeDeletePlan(async()=>r,school);await observe(request,1);
 r.records.synthetic._syncErasePlan.files.push('new-file');await assert.rejects(observe(request,2),/inventory changed/);
});

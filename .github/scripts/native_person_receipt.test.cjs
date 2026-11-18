'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {verifiedNativeReceipt,retryExactDelete}=require('./native_person_receipt.cjs');
const school='vs-'+'a'.repeat(32),request={id:'synthetic',operation:'write',operationId:'original-immutable-operation'};
const reply={success:true,schoolId:school,syncProtocol:2,personLifecycleVersion:1,
 operationId:request.operationId,recordRevision:'signed-owner-revision',
 record:{id:request.id,schoolId:school,_syncRevision:'signed-owner-revision',_syncOperationId:request.operationId}};
test('signed native save needs exact readback, not a fabricated Cloudflare enqueue flag',()=>{
 assert.equal(verifiedNativeReceipt(reply,request,school),true);
 for(const patch of [{success:false},{schoolId:'foreign'},{syncProtocol:1},{personLifecycleVersion:0},
  {operationId:'different'},{reconcileRequired:true},{delivery:{}},{recordRevision:'cf-pending'},
  {recordRevision:'live-other'},{record:null},{record:{...reply.record,id:'other'}},
  {record:{...reply.record,schoolId:'foreign'}},{record:{...reply.record,_syncRevision:'newer'}},
  {record:{...reply.record,_syncOperationId:'other'}},{record:{...reply.record,_syncDeleted:true}}])
  assert.equal(verifiedNativeReceipt({...reply,...patch},request,school),false,JSON.stringify(patch));
});
test('bounded deletion continuation replays only the immutable original generation and operation',async()=>{
 const body={...request,collection:'students_directory',operation:'delete',syncProtocol:2,
  deleteEverywhereVersion:1,expectedRecordRevision:'original',deletedStudentGeneration:'p-'+'b'.repeat(64)};
 const seen=[];let waits=0;
 const result=await retryExactDelete(body,async value=>{
  seen.push(structuredClone(value));value.operationId='callback-mutation';
  if(seen.length===1)throw Object.assign(Error('pending'),{code:'SCRIPT_DELETE_EVERYWHERE_PENDING'});
  return 'verified';
 },{delay:async ms=>{assert.equal(ms,5000);waits++;}});
 assert.equal(result,'verified');assert.deepEqual(seen,[body,body]);assert.equal(waits,1);
 let calls=0;
 await assert.rejects(retryExactDelete(body,async()=>{calls++;throw Object.assign(Error('conflict'),{code:'RECORD_REVISION_CONFLICT'});},{delay:async()=>{}}),/conflict/);
 assert.equal(calls,1);
 calls=0;
 await assert.rejects(retryExactDelete(body,async()=>{calls++;throw Object.assign(Error('pending'),{code:'SCRIPT_TIMEOUT'});},{attempts:2,delay:async()=>{}}),/pending/);
 assert.equal(calls,2);
 calls=0;
 assert.equal(await retryExactDelete(body,async value=>{
  assert.deepEqual(value,body);if(++calls===1)throw Object.assign(Error('timeout'),{name:'TimeoutError'});return 'verified';
 },{delay:async()=>{}}),'verified');
 assert.equal(calls,2);
 await assert.rejects(retryExactDelete({...body,deletedStudentGeneration:'other'},async()=>{throw Error('must not send');}),/generation-bound/);
});
test('native deletion requires both actual Drive and Firebase final completion',()=>{
 const del={...request,operation:'delete'},ack={...reply,deleteEverywhereVersion:1,
  driveDeletionComplete:true,firebaseDeletionComplete:true,record:{...reply.record,_syncDeleted:true}};
 assert.equal(verifiedNativeReceipt(ack,del,school),true);
 for(const patch of [{deleteEverywhereVersion:0},{driveDeletionComplete:false},
  {firebaseDeletionComplete:false},{record:reply.record}])
  assert.equal(verifiedNativeReceipt({...ack,...patch},del,school),false);
});

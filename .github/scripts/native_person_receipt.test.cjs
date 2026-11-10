'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {verifiedNativeReceipt}=require('./native_person_receipt.cjs');
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
test('native deletion requires both actual Drive and Firebase final completion',()=>{
 const del={...request,operation:'delete'},ack={...reply,deleteEverywhereVersion:1,
  driveDeletionComplete:true,firebaseDeletionComplete:true,record:{...reply.record,_syncDeleted:true}};
 assert.equal(verifiedNativeReceipt(ack,del,school),true);
 for(const patch of [{deleteEverywhereVersion:0},{driveDeletionComplete:false},
  {firebaseDeletionComplete:false},{record:reply.record}])
  assert.equal(verifiedNativeReceipt({...ack,...patch},del,school),false);
});

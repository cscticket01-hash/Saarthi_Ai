'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createCloudflareDelivery}=require('../cloudflare-delivery');
const school='vs-'+'a'.repeat(32);
const operation={collection:'fee_payments',id:'synthetic-1',operationId:'synthetic-operation-0001',
 operation:'write',syncProtocol:2,expectedRecordRevision:'',data:{schoolId:school}};
function fixture(){
 const calls=[];
 const row={id:'b'.repeat(64),state:'pending',response:null,
  payload:JSON.stringify({action:'managed_records_batch',operations:[operation]})};
 const edge={rpc:async(s,l,b)=>{
  assert.equal(s,school);assert.equal(l,'records');calls.push(b.command);
  if(b.command==='pending')return row.state==='pending'?[row]:[];
  if(b.command==='claim')return true;
  if(b.command==='finish'){row.state=b.values.state;row.response=b.values;return true;}
  if(b.command==='status')return row;
  throw Error('Unexpected command '+b.command);
 }};
 return {calls,row,delivery:createCloudflareDelivery({edge,now:()=>10000,diagnostics:()=>{}})};
}
for(const [code,status] of [
 ['SCRIPT_TIMEOUT',504],
 ['SCRIPT_OPERATION_FAILED',502],
 ['SCRIPT_TRANSPORT_ERROR',503],
 ['SCRIPT_STORAGE_NOT_PREPARED',502],
 ['SCRIPT_STUDENT_PARENT_PENDING',503],
 ['NOT_ALLOWLISTED',503],
]){
 test('retained batch reports typed provider failure '+code,async()=>{
  const {calls,row,delivery}=fixture();
  const result=await delivery.drain(school,'records',async request=>{
   assert.equal(request.operations.length,1);
   return {success:true,schoolId:school,syncProtocol:2,recordWriteBatchVersion:1,
    acknowledgements:[{operationId:operation.operationId,success:false,code}]};
  });
  assert.equal(result.processed,0);
  assert.equal(row.state,'retry');
  assert.equal(row.response.failureStatus,status);
  assert.equal(row.response.failureCode,code==='NOT_ALLOWLISTED'?'EDGE_DELIVERY_PENDING':code);
  assert.equal(row.response.partial[operation.operationId],undefined,'Unverified operation must never be acknowledged');
  assert.equal(row.response.nextAttemptAt>10000,true);
  assert.deepEqual(calls.slice(0,2),['pending','claim']);
  const receipt=await delivery.status(school,'records',row.id);
  assert.equal(receipt.cloudflareAccepted,true);
  assert.equal(receipt.driveState,'pending');
  assert.equal(receipt.deliveryStatus.failureCode,row.response.failureCode);
  assert.equal(receipt.recordRevision,undefined);
 });
}
test('partial acknowledgement never replays the already-confirmed operation',async()=>{
 const {row,delivery}=fixture();
 const second={...operation,id:'synthetic-2',operationId:'synthetic-operation-0002'};
 row.payload=JSON.stringify({action:'managed_records_batch',operations:[operation,second]});
 const seen=[];
 await delivery.drain(school,'records',async request=>{
  seen.push(request.operations.map(x=>x.operationId));
  return {success:true,schoolId:school,syncProtocol:2,recordWriteBatchVersion:1,acknowledgements:[
   {operationId:operation.operationId,success:true,recordRevision:'drive-revision-1',
    record:{schoolId:school,id:operation.id,_syncRevision:'drive-revision-1',
     _syncOperationId:operation.operationId}},
   {operationId:second.operationId,success:false,code:'SCRIPT_TIMEOUT'}]};
 });
 assert.equal(row.state,'retry');
 assert.equal(row.response.partial[operation.operationId].success,true);
 assert.equal(row.response.failureCode,'SCRIPT_TIMEOUT');
 // Simulate the next Cloudflare claim using the same immutable record payload.
 row.state='pending';
 row.response=JSON.stringify({partial:row.response.partial});
 await delivery.drain(school,'records',async request=>{
  seen.push(request.operations.map(x=>x.operationId));
  return {success:true,schoolId:school,syncProtocol:2,recordWriteBatchVersion:1,acknowledgements:[
   {operationId:second.operationId,success:true,recordRevision:'drive-revision-2',
    record:{schoolId:school,id:second.id,_syncRevision:'drive-revision-2',
     _syncOperationId:second.operationId}}]};
 });
 assert.deepEqual(seen,[[operation.operationId,second.operationId],[second.operationId]]);
 assert.equal(row.state,'completed');
});

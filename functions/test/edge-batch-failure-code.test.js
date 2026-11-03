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
test('bounded delete archive continuation keeps five-second spacing and the original durable request',async()=>{
 const {row,delivery}=fixture();
 const request={action:'managed_records',collection:'students_directory',id:'owned-student',
  operation:'delete',operationId:'original-delete-operation-0001',syncProtocol:2,
  expectedRecordRevision:'original-revision',deleteEverywhereVersion:1};
 row.payload=JSON.stringify(request);
 for(let i=0;i<12;i++){
  row.state='pending';row.response=row.response===null?null:JSON.stringify(row.response);
  await delivery.drain(school,'records',async body=>{
   assert.deepEqual(body,request);
   throw Object.assign(Error('private provider detail'),{status:503,code:'SCRIPT_DELETE_EVERYWHERE_PENDING'});
  });
  assert.equal(row.response.nextAttemptAt,15000);
  assert.equal(row.response.retryCount,0);
  assert.equal(row.state,'retry');
  assert.equal(row.payload,JSON.stringify(request));
 }
 const receipt=await delivery.status(school,'records',row.id);
 assert.equal(receipt.driveState,'pending');
 assert.equal(receipt.recordRevision,undefined);
 assert.equal(receipt.deliveryStatus.failureCode,'SCRIPT_DELETE_EVERYWHERE_PENDING');
});
test('cleanup continuation never bypasses a provider retry-after window',async()=>{
 const {row,delivery}=fixture();
 row.payload=JSON.stringify({action:'managed_records',collection:'documents',id:'owned',operation:'delete',syncProtocol:2,deleteEverywhereVersion:1});
 await delivery.drain(school,'records',async()=>{throw Object.assign(Error('pending'),{
  status:503,code:'SCRIPT_DELETE_EVERYWHERE_PENDING',retryAfterMs:90000});});
 assert.equal(row.response.nextAttemptAt,100000);
});
test('unresolved cleanup returns to exponential backoff after its durable bounded continuation budget',async()=>{
 const {row,delivery}=fixture();
 row.payload=JSON.stringify({action:'managed_records',collection:'documents',id:'owned',operation:'delete',syncProtocol:2,deleteEverywhereVersion:1});
 const delays=[];
 for(let i=0;i<36;i++){
  row.state='pending';row.response=row.response===null?null:JSON.stringify(row.response);
  await delivery.drain(school,'records',async()=>{throw Object.assign(Error('pending'),{status:503,code:'SCRIPT_DELETE_EVERYWHERE_PENDING'});});
  delays.push(row.response.nextAttemptAt-10000);
 }
 assert.deepEqual(delays.slice(0,32),Array(32).fill(5000));
 assert.deepEqual(delays.slice(32),[5000,10000,20000,40000]);
 assert.equal(row.response.cleanupContinuationCount,32);
 assert.equal(row.state,'retry');
});
for(const request of [
 {action:'managed_records',operation:'write',syncProtocol:2,deleteEverywhereVersion:1},
 {action:'managed_records',operation:'delete',syncProtocol:2},
 {action:'managed_records_batch',operations:[operation]},
])test('non-delete/legacy/batch cannot borrow bounded cleanup retry admission '+JSON.stringify(request),async()=>{
 const {row,delivery}=fixture();row.payload=JSON.stringify(request);
 for(let i=1;i<=3;i++){
  row.state='pending';row.response=row.response===null?null:JSON.stringify(row.response);
  await delivery.drain(school,'records',async()=>{throw Object.assign(Error('pending'),{status:503,code:'SCRIPT_DELETE_EVERYWHERE_PENDING'});});
  assert.equal(row.response.retryCount,i);
  assert.equal(row.response.nextAttemptAt,10000+5000*2**(i-1));
 }
});
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

test('repeated Script timeouts grow bounded durable retry delays without dropping queued work',async()=>{
 const {row,delivery}=fixture();
 const observed=[];
 for(let i=1;i<=9;i++){
  // Worker would reclaim this row once its due time is reached.
  row.state='pending';
  row.response=row.response===null?null:JSON.stringify(row.response);
  await delivery.drain(school,'records',async()=>({
   success:true,schoolId:school,syncProtocol:2,recordWriteBatchVersion:1,
   acknowledgements:[{operationId:operation.operationId,success:false,code:'SCRIPT_TIMEOUT'}],
  }));
  assert.equal(row.state,'retry');
  assert.equal(row.response.retryCount,Math.min(i,10));
  assert.equal(row.response.partial[operation.operationId],undefined);
  observed.push(row.response.nextAttemptAt-10000);
 }
 assert.deepEqual(observed,[5000,10000,20000,40000,80000,160000,300000,300000,300000]);
 const receipt=await delivery.status(school,'records',row.id);
 assert.equal(receipt.driveState,'pending');
 assert.equal(receipt.deliveryStatus.failureCode,'SCRIPT_TIMEOUT');
});
test('provider retry-after longer than exponential delay is respected and remains resumable',async()=>{
 const {row,delivery}=fixture();
 await delivery.drain(school,'records',async()=>{
  throw Object.assign(Error('no private request detail'),{
   status:429,code:'SCRIPT_QUOTA_EXCEEDED',retryAfterMs:900000,
  });
 });
 assert.equal(row.state,'retry');
 assert.equal(row.response.nextAttemptAt,910000);
 assert.equal(row.response.retryCount,1);
 assert.equal(row.response.failureCode,'SCRIPT_QUOTA_EXCEEDED');
 assert.equal(row.payload.includes('synthetic-operation-0001'),true);
});
test('permission refusal stays needsAttention instead of appearing Drive-verified',async()=>{
 const {row,delivery}=fixture();
 await delivery.drain(school,'records',async()=>({
  success:true,schoolId:school,syncProtocol:2,recordWriteBatchVersion:1,
  acknowledgements:[{operationId:operation.operationId,success:false,code:'SCRIPT_PERMISSION_DENIED'}],
 }));
 assert.equal(row.state,'needsAttention');
 assert.equal(row.response.failureCode,'SCRIPT_PERMISSION_DENIED');
 assert.equal(row.response.partial[operation.operationId].success,false);
 assert.equal(row.response.cleanup?.payloadPurged,undefined);
 await assert.rejects(delivery.status(school,'records',row.id),e=>
  e.status===409&&e.code==='SCRIPT_PERMISSION_DENIED');
});
test('legacy completed batch with rejected ACK never gives false green Drive verification',async()=>{
 const {row,delivery}=fixture();
 row.state='completed';
 row.response={result:{success:true,schoolId:school,syncProtocol:2,
  recordWriteBatchVersion:1,
  acknowledgements:[{operationId:operation.operationId,success:false,code:'SCRIPT_PERMISSION_DENIED'}]}};
 await assert.rejects(delivery.status(school,'records',row.id),e=>
  e.status===409&&e.code==='SCRIPT_PERMISSION_DENIED');
});
test('mixed successful and permission-denied batch preserves both receipts for review',async()=>{
 const {row,delivery}=fixture();
 const second={...operation,id:'synthetic-2',operationId:'synthetic-operation-0002'};
 row.payload=JSON.stringify({action:'managed_records_batch',operations:[operation,second]});
 await delivery.drain(school,'records',async()=>({
  success:true,schoolId:school,syncProtocol:2,recordWriteBatchVersion:1,
  acknowledgements:[
   {operationId:operation.operationId,success:true,recordRevision:'drive-verified-1',
    record:{id:operation.id,schoolId:school,_syncRevision:'drive-verified-1',
     _syncOperationId:operation.operationId}},
   {operationId:second.operationId,success:false,code:'SCRIPT_PERMISSION_DENIED'},
  ],
 }));
 assert.equal(row.state,'needsAttention');
 assert.equal(row.response.partial[operation.operationId].success,true);
 assert.equal(row.response.partial[second.operationId].success,false);
 assert.equal(row.response.failureCode,'SCRIPT_PERMISSION_DENIED');
 assert.equal(row.payload.includes('synthetic-operation-0002'),true);
 await assert.rejects(delivery.status(school,'records',row.id),e=>
  e.status===409&&e.code==='SCRIPT_PERMISSION_DENIED');
});

test('malformed historical empty batch cannot produce a verified Google ACK',async()=>{
 const {row,delivery}=fixture();
 row.state='completed';
 row.response={result:{success:true,schoolId:school,syncProtocol:2,
  recordWriteBatchVersion:1,acknowledgements:[]}};
 await assert.rejects(delivery.status(school,'records',row.id),e=>
  e.status===502&&e.code==='ACK_UNVERIFIED');
});

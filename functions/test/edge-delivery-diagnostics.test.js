'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createCloudflareDelivery}=require('../cloudflare-delivery');
const school='vs-'+'a'.repeat(32);
async function run(deliver,diagnostics){
 let finished;
 const edge={rpc:async(s,l,b)=>{
  if(b.command==='pending')return [{id:'a'.repeat(64),payload:JSON.stringify({action:'managed_records',collection:'students_directory',id:'private-student',operationId:'original-operation-00001',data:{schoolId:school}})}];
  if(b.command==='claim')return true;
  if(b.command==='finish'){finished=b.values;return true;}
  throw Error('unexpected command');
 }};
 const result=await createCloudflareDelivery({edge,diagnostics}).drain(school,'records',deliver);
 return {result,finished};
}
test('delivery logs fixed Script reason without private payload or exception',async()=>{
 const logs=[];
 const {finished}=await run(async()=>{throw Object.assign(Error('private-secret'),{status:502,code:'SCRIPT_TYPE_ERROR'});},e=>logs.push(e));
 assert.deepEqual(logs,[{event:'edge_delivery_failure',lane:'records',phase:'deliver',code:'SCRIPT_TYPE_ERROR',status:502}]);
 assert.equal(finished.state,'retry');assert.equal(finished.failureCode,'SCRIPT_TYPE_ERROR');
 assert.ok(!JSON.stringify(logs).includes('private'));
});
test('bad acknowledgement remains retained and identifies verification phase',async()=>{
 const logs=[];const {finished}=await run(async()=>({success:true,schoolId:school,syncProtocol:2,recordRevision:'cf-unverified'}),e=>logs.push(e));
 assert.equal(logs[0].phase,'verify');assert.equal(logs[0].code,'ACK_UNVERIFIED');assert.equal(finished.state,'retry');
});
test('logging failure cannot change retained retry handling',async()=>{
 const {finished}=await run(async()=>{throw Object.assign(Error('secret'),{status:503,code:'SCRIPT_TIMEOUT'});},()=>{throw Error('logger unavailable');});
 assert.equal(finished.state,'retry');assert.equal(finished.failureCode,'SCRIPT_TIMEOUT');
});

test('explicit Delete Everywhere never reports Drive verified until Firebase AND Drive complete',async()=>{
 const id='student-1',operationId='original-delete-edge-operation-1';
 const request={action:'managed_records',collection:'students_directory',id,
   operation:'delete',syncProtocol:2,operationId,expectedRecordRevision:'old-revision',
   deleteEverywhereVersion:1};
 const valid={success:true,schoolId:school,syncProtocol:2,recordRevision:'drive-deleted',
   deleteEverywhereVersion:1,driveDeletionComplete:true,firebaseDeletionComplete:true,
   record:{id,schoolId:school,_syncDeleted:true,_syncRevision:'drive-deleted',
     _syncOperationId:operationId,_syncErasePlan:{complete:true}}};
 async function drain(reply){
  let values;
  const edge={rpc:async(_school,lane,body)=>{
   if(body.command==='pending')return [{id:'a'.repeat(64),payload:JSON.stringify(request)}];
   if(body.command==='claim')return true;
   if(body.command==='finish'){values=body.values;return true;}
   throw Error('unexpected command');
  }};
  const result=await createCloudflareDelivery({edge,diagnostics:()=>{}})
    .drain(school,'records',async()=>reply);
  return {values,result};
 }
 for(const variant of [
  {...valid,driveDeletionComplete:false},
  {...valid,firebaseDeletionComplete:false},
  {...valid,deleteEverywhereVersion:0},
  {...valid,record:{...valid.record,_syncErasePlan:{complete:false}}},
  {...valid,record:undefined}
 ]){
  const {values,result}=await drain(variant);
  assert.equal(result.processed,0);
  assert.equal(values.state,'retry','No false completed Cloudflare ticket');
  assert.equal(values.failureCode,'ACK_UNVERIFIED');
 }
 const {values,result}=await drain(valid);
 assert.equal(result.processed,1);
 assert.equal(values.state,'completed');
 assert.equal(values.result.driveDeletionComplete,true);
 assert.equal(values.result.firebaseDeletionComplete,true);
});

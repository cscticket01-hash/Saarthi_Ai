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

'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {fixture,A,B,time}=require('./helpers/managed-school-broker');
const TEST='vs-db8afb01a3be46a983c8284714d06e5d',operationId='e'.repeat(64);
const proof={readbackVersion:1,operationId,complete:true,verified:true,verifiedAt:time,startedAt:time-1000,observedAt:time,
 phase:'verified',recordCount:348,rowCount:348,checkedRows:348,binaryCount:19,checkedBinaries:19,readOnly:true,
 activeStorageChanged:false,scope:'completed_rehearsal_rows_and_bytes'};
function setup(data=proof){
 const f=fixture(async(_,options)=>({ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:JSON.parse(options.body).schoolId,...data})}));
 f.docs.get('school_memberships/A').schoolId=TEST;
 for(const collection of ['school_entitlements','platform_schools','school_storage_private'])f.docs.set(collection+'/'+TEST,{...f.docs.get(collection+'/'+A)});
 return f;
}
const request={action:'managed/disaster/readback',schoolId:TEST,operationId,fileId:'immutable_rehearsal_checkpoint'};
test('fresh readback is signed, TEST-scoped and separate from a durable upload ACK',async()=>{
 const f=setup(),result=await f.call(request);assert.equal(result.checkedRows,348);assert.equal(result.checkedBinaries,19);
 const body=JSON.parse(JSON.parse(f.sent[0].opt.body).payload);assert.equal(body.action,'managed_disaster_readback');assert.equal(body.fileId,request.fileId);
 assert.equal(f.docs.get('platform_schools/'+TEST).syncServerEvidence,undefined);
 await assert.rejects(f.call({...request,schoolId:B}),e=>e.status===403);
 const original=fixture();await assert.rejects(original.call({...request,schoolId:A}),e=>e.status===403);assert.equal(original.sent.length,0);
});
test('incomplete and metadata-only readback cannot claim full verification',async()=>{
 const pending={...proof,complete:false,verified:false,verifiedAt:0,phase:'records',checkedRows:25,checkedBinaries:0};
 assert.equal((await setup(pending).call(request)).complete,false);
 await assert.rejects(setup({...pending,phase:'verified'}).call(request),e=>e.status===502&&e.code==='SCRIPT_RESPONSE_INVALID');
 for(const changed of [{readbackVersion:undefined},{checkedRows:347},{checkedBinaries:18},{verifiedAt:0},{verified:false},
  {readOnly:false},{activeStorageChanged:true},{operationId:'f'.repeat(64)},{observedAt:time+300001},{binaryCount:1001},{rowCount:347}])
  await assert.rejects(setup({...proof,...changed}).call(request),e=>e.status===502&&e.code==='SCRIPT_RESPONSE_INVALID');
});
test('invalid readback identities are rejected before invoking Apps Script',async()=>{
 const f=setup();for(const changed of [{operationId:'short'},{fileId:'../foreign'},{fileId:''}])
  await assert.rejects(f.call({...request,...changed}),e=>e.status===400);
 assert.equal(f.sent.length,0);
});

const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createCloudflareDelivery}=require('../cloudflare-delivery');
const school='vs-'+'a'.repeat(32);
function mock(capability){
 const calls=[],request={action:'managed_records',collection:'school_expenses',id:'one',operationId:'operation-original-00001',data:{schoolId:school}};
 const row={id:'a'.repeat(64),payload:JSON.stringify(request),response:null,state:'pending'};
 return {calls,row,edge:{rpc:async(s,l,b)=>{
  assert.equal(s,school);assert.equal(l,'records');calls.push(b);
  if(b.command==='capabilities')return capability;
  if(b.command==='pending')return row.state==='pending'?[row]:[];
  if(b.command==='claim')return true;
  if(b.command==='finish'){row.state=b.values.state;row.response=b.values;return true;}
  if(b.command==='status')return row;
  throw Error('Unexpected command');
 }}};
}
test('old Workers remain on one-job admission even with broker parallel canary enabled',async()=>{
 const m=mock({edgeDeliveryVersion:1});
 const delivery=createCloudflareDelivery({edge:m.edge,recordParallelism:2});
 await delivery.drain(school,'records',async r=>({success:true,schoolId:school,syncProtocol:2,recordRevision:'real-drive',record:{...r.data,id:r.id,_syncOperationId:r.operationId}}));
 assert.equal(m.calls.find(c=>c.command==='pending').limit,1);
 const result=await delivery.status(school,'records',m.row.id);
 assert.equal(result.driveState,'verified');assert.equal(result.deliveryTiming.queueWaitMillis,undefined,'Legacy creation time must not be fabricated');
});
test('default serial mode needs no capability request and preserves retry with measured attempt timing',async()=>{
 const m=mock({recordSchedulingVersion:1});let at=10000;
 const delivery=createCloudflareDelivery({edge:m.edge,now:()=>at});
 await delivery.drain(school,'records',async()=>{at+=250;throw Object.assign(Error('private raw error'),{status:503,code:'SCRIPT_TIMEOUT'});});
 assert.equal(m.calls.some(c=>c.command==='capabilities'),false);
 assert.equal(m.row.state,'retry');assert.equal(m.row.response.timing.deliveryMillis,250);
 assert.ok(m.row.response.nextAttemptAt>at);assert.equal(JSON.stringify(m.row).includes('private raw error'),false);
 const result=await delivery.status(school,'records',m.row.id);
 assert.equal(result.driveState,'pending');assert.equal(result.recordRevision,undefined);
});
test('an oversized scheduler response is rejected before any claim or delivery',async()=>{
 let claims=0,sends=0;
 const delivery=createCloudflareDelivery({recordParallelism:2,edge:{rpc:async(s,l,b)=>{
  if(b.command==='capabilities')return {recordSchedulingVersion:1};
  if(b.command==='pending')return [{},{},{}];
  claims++;throw Error('Must not claim');
 }}});
 await assert.rejects(delivery.drain(school,'records',async()=>{sends++;}),e=>e.code==='EDGE_SCHEDULER_UNVERIFIED');
 assert.equal(claims,0);assert.equal(sends,0);
});

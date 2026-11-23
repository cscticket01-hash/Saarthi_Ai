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

test('three-way rollout drains only the exact scheduler-admitted independent records',async()=>{
 const jobs=['a','b','c'].map((letter,index)=>{
  const recordId='expense-'+letter;
  const request={action:'managed_records',collection:'school_expenses',
   id:recordId,operation:'write',operationId:'original-expense-operation-'+letter,
   expectedRecordRevision:'',syncProtocol:2,
   data:{schoolId:school,amount:index+1}};
  return {id:letter.repeat(64),payload:JSON.stringify(request),
   response:null,state:'pending'};
 });
 const calls=[];let inflight=0,peak=0;
 const edge={rpc:async(s,l,b)=>{
  assert.equal(s,school);assert.equal(l,'records');calls.push(b);
  if(b.command==='capabilities')return {recordSchedulingVersion:1};
  if(b.command==='pending')return jobs.slice(0,b.limit);
  if(b.command==='claim')return true;
  if(b.command==='finish'){
   const row=jobs.find(r=>r.id===b.id);
   row.state=b.values.state;
   row.response=b.values;
   return true;
  }
  throw Error('Unexpected Cloudflare scheduler command');
 }};
 const delivery=createCloudflareDelivery({edge,recordParallelism:3});
 const result=await delivery.drain(school,'records',async request=>{
  inflight++;peak=Math.max(peak,inflight);
  await Promise.resolve();
  inflight--;
  return {success:true,schoolId:school,syncProtocol:2,
   recordRevision:'drive-revision-'+request.id,
   record:{...request.data,id:request.id,_syncOperationId:request.operationId}};
 });
 assert.equal(calls.find(c=>c.command==='pending').limit,3);
 assert.equal(peak,3,'three independent provider jobs can proceed simultaneously');
 assert.equal(result.processed,3);
 assert(jobs.every(r=>r.state==='completed'&&r.response.result.recordRevision.startsWith('drive-')));
});
test('three-way canary falls back to serial on an older Worker and caps forged scheduler rows',async()=>{
 let limit,claims=0;
 const delivery=createCloudflareDelivery({recordParallelism:3,edge:{rpc:async(_,lane,body)=>{
  assert.equal(lane,'records');
  if(body.command==='capabilities')return {recordSchedulingVersion:0};
  if(body.command==='pending'){limit=body.limit;return [];}
  claims++;throw Error('Unexpected claim');
 }}});
 assert.deepEqual(await delivery.drain(school,'records',async()=>assert.fail()),{processed:0});
 assert.equal(limit,1);
 assert.equal(claims,0);
 let sends=0;
 const invalid=createCloudflareDelivery({recordParallelism:3,edge:{rpc:async(_,__,body)=>{
  if(body.command==='capabilities')return {recordSchedulingVersion:1};
  if(body.command==='pending')return [{},{},{},{}];
  claims++;throw Error('Untrusted scheduler rows');
 }}});
 await assert.rejects(invalid.drain(school,'records',async()=>{sends++;}),
  e=>e.code==='EDGE_SCHEDULER_UNVERIFIED');
 assert.equal(sends,0);
 assert.equal(claims,0);
});

test('three-way option is school scoped and never becomes a wildcard rollout',async()=>{
 const limits=[],first=school,other='vs-'+'b'.repeat(32);
 const edge={rpc:async(s,l,b)=>{
  assert.equal(l,'records');
  if(b.command==='capabilities')return {recordSchedulingVersion:1};
  if(b.command==='pending'){limits.push([s,b.limit]);return [];}
  throw Error('Unexpected provider command');
 }};
 const delivery=createCloudflareDelivery({edge,
  recordParallelism:s=>s===first?3:1});
 await delivery.drain(first,'records',async()=>assert.fail('No work admitted'));
 await delivery.drain(other,'records',async()=>assert.fail('No work admitted'));
 assert.deepEqual(limits,[[first,3],[other,1]]);
});

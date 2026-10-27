'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {createAttendanceQueue,firestoreAttendanceStore,createAttendanceWorker}=require('../attendance-queue');
test('isolated attendance store filters reads and refuses foreign create, claim and finish',async()=>{
 const own='vs-'+ 'a'.repeat(32),foreign='vs-'+ 'b'.repeat(32),calls=[];let writes=0;
 const query={where:(...a)=>{calls.push(a);return query;},orderBy:()=>query,limit:()=>query,
   get:async()=>({docs:[{id:'foreign',data:()=>({schoolId:foreign})},{id:'own',data:()=>({schoolId:own})}]})};
 const db={collection:name=>{assert.equal(name,'attendance_test_outbox');return query;},doc:path=>{assert(path.startsWith('attendance_test_outbox/'));return {create:async()=>{writes++;}};},
   runTransaction:async fn=>fn({get:async()=>({exists:true,data:()=>({schoolId:foreign,claim:'lease',state:'pending',nextAttemptAt:0})}),set:()=>{writes++;}})};
 const s=firestoreAttendanceStore(db,{schoolId:own,collectionName:'attendance_test_outbox'});
 assert.deepEqual((await s.pending(25)).map(r=>r.operationId),['own']);
 assert.equal(calls[0][0],'nextAttemptAt');assert.equal(calls[0][1],'<=');
 assert.equal(Number.isFinite(calls[0][2]),true);
 assert.equal(calls.some(c=>c[0]==='schoolId'),false,'TEST-only queue must not depend on a composite index');
 await assert.rejects(s.create('foreign',{schoolId:foreign}));
 assert.equal(await s.claim('foreign','lease',1,2),false);await s.finish('foreign','lease',{state:'completed'});
 assert.equal(writes,0);assert.throws(()=>firestoreAttendanceStore(db,{schoolId:'invalid'}));
 assert.throws(()=>firestoreAttendanceStore(db,{collectionName:'school_records'}));
});
test('non-TEST scoped Firestore queue retains schoolId filtering',async()=>{
 const school='vs-'+'a'.repeat(32),calls=[];
 const query={where:(...args)=>{calls.push(args);return query;},orderBy:()=>query,limit:()=>query,get:async()=>({docs:[]})};
 const db={collection:name=>{assert.equal(name,'attendance_outbox');return query;},doc:()=>({})};
 await firestoreAttendanceStore(db,{schoolId:school,collectionName:'attendance_outbox'}).pending(25);
 assert.deepEqual(calls[0],['schoolId','==',school]);
 assert.equal(calls[1][0],'nextAttemptAt');
});
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32);
function store(rows=new Map()) {return {rows,create:async(id,r)=>{if(rows.has(id))return false;rows.set(id,{...r});return true;},pending:async n=>[...rows.values()].filter(r=>r.state!=='completed'&&r.state!=='needsAttention').slice(0,n),claim:async(id,claim,now,expires)=>{const r=rows.get(id);if(!r||r.state==='processing'&&r.claimExpiresAt>now)return false;Object.assign(r,{state:'processing',claim,claimExpiresAt:expires});return true;},finish:async(id,claim,v)=>{if(rows.get(id).claim===claim)Object.assign(rows.get(id),v,{claim:'',claimExpiresAt:0});}};}
const event=(school=A,person='pupil')=>({schoolId:school,role:'student',personId:person,day:'2026-10-07',mode:'entry',payload:{encrypted:'test'}});
test('adaptive batches stay compatible, claim just in time and preserve original timestamps',async()=>{
 const s=store(),sizes=[];let time=1000;
 const q=createAttendanceQueue({store:s,now:()=>time,batchSize:100,deliver:async(school,items)=>{
  sizes.push(items.length);assert(items.length<=25);assert(items.every(i=>i.schoolId===school));
  assert.equal([...s.rows.values()].filter(i=>i.state==='processing').length,items.length);
  assert(items.every(i=>i.createdAt===1000&&i.payload.originalEventAt===900));time+=1000;
  return items.map(i=>({operationId:i.operationId,success:true}));
 }});
 for(let n=0;n<100;n++)await q.enqueue({...event(A,'p'+n),payload:{originalEventAt:900}});
 await q.drain();assert.deepEqual(sizes,[25,25,25,25]);assert.equal(q.metrics.completed,100);
 assert.equal(q.metrics.batchSize,50);assert.equal(q.metrics.lastBatchMillis,4000);
 assert([...s.rows.values()].every(i=>i.payload.originalEventAt===900&&i.createdAt===1000));
});
test('partial ACK reduces admission; jittered retry retains every unacknowledged operation',async()=>{
 const s=store(),q=createAttendanceQueue({store:s,now:()=>1000,random:()=>0,batchSize:50,deliver:async(_,items)=>items.slice(0,1).map(i=>({operationId:i.operationId,success:true}))});
 for(let n=0;n<50;n++)await q.enqueue(event(A,'p'+n));
 const result=await q.drain();assert.equal(q.metrics.completed,2);assert.equal(q.metrics.retried,48);
 assert.equal(q.metrics.batchSize,25);assert.equal(s.rows.size,50);assert.equal(result.nextRetryAt,6000);
 assert([...s.rows.values()].filter(i=>i.state==='retry').every(i=>i.nextAttemptAt===6000));
});
test('healthy full batch grows within configured bounds and oversized Script batches are rejected',async()=>{
 const s=store(),q=createAttendanceQueue({store:s,now:()=>1000,batchSize:50,maxBatchSize:75,deliver:async(_,items)=>items.map(i=>({operationId:i.operationId,success:true}))});
 for(let n=0;n<100;n++)await q.enqueue(event(A,'p'+n));
 await q.drain();assert.equal(q.metrics.batchSize,75);await q.drain();assert.equal(q.metrics.completed,100);
 assert.throws(()=>createAttendanceQueue({store:s,deliver:async()=>[],deliveryBatchSize:26}),/Invalid bounded/);
});
test('durable acknowledgement follows store commit; retries deduplicate stable intended event',async()=>{
 const s=store(),q=createAttendanceQueue({store:s,deliver:async()=>[]});
 const first=await q.enqueue(event()),retry=await q.enqueue(event());assert.equal(first.duplicate,false);assert.equal(retry.duplicate,true);assert.equal(s.rows.size,1);
 const broken=createAttendanceQueue({store:{create:async()=>{throw Error('disk/db unavailable');}},deliver:async()=>[]});await assert.rejects(broken.enqueue(event()));
});
test('restart and crash during upload retain durable operation; verified retry completes once',async()=>{
 const s=store();let time=1000,applied=new Set(),attempts=0;
 const deliver=async(school,items)=>{attempts++;items.forEach(i=>applied.add(i.operationId));if(attempts===1)throw Error('crash after remote commit');return items.map(i=>({operationId:i.operationId,success:true}));};
 const q=createAttendanceQueue({store:s,deliver,now:()=>time});await q.enqueue(event());await q.drain();assert.equal([...s.rows.values()][0].state,'retry');
 time+=20000;const restarted=createAttendanceQueue({store:s,deliver,now:()=>time});await restarted.drain();assert.equal([...s.rows.values()][0].state,'completed');assert.equal(applied.size,1);
});
test('batching preserves School A/B and missing acknowledgements never complete operations',async()=>{
 const s=store(),groups=[];const q=createAttendanceQueue({store:s,deliver:async(school,items)=>{groups.push({school,items});return school===A?items.map(i=>({operationId:i.operationId,success:true})):[];}});
 await q.enqueue(event(A));await q.enqueue(event(B));await q.drain();assert.equal(groups.length,2);for(const g of groups)assert(g.items.every(i=>i.schoolId===g.school));
 assert.equal([...s.rows.values()].find(i=>i.schoolId===B).state,'retry');
});
test('authoritative licence denial is retained for attention; temporary service error backs off',async()=>{
 const s=store(),q=createAttendanceQueue({store:s,deliver:async(_,items)=>items.map(i=>({operationId:i.operationId,success:false,authoritative:true}))});
 await q.enqueue(event());await q.drain();assert.equal([...s.rows.values()][0].state,'needsAttention');assert.equal(s.rows.size,1);
});
module.exports={store,event};

test('malformed or ambiguous cloud receipts never clear accepted attendance',async()=>{
 for(const mode of ['not-array','duplicate','null-and-foreign']){
  const s=store(),q=createAttendanceQueue({store:s,now:()=>1000,deliver:async(_,items)=>{
   const good={operationId:items[0].operationId,success:true};
   return mode==='not-array'?{}:mode==='duplicate'?[good,{...good,success:false}]:[null,{operationId:'foreign',success:true}];
  }});
  const accepted=await q.enqueue(event());await q.drain();
  assert.equal(s.rows.size,1);assert.equal(s.rows.get(accepted.operationId).state,'retry');assert.equal(q.metrics.completed,0);
 }
});

test('Firestore worker queries due operations only and defers claimed rows until lease expiry',async()=>{
 const calls=[];let claimed;
 const query={where:(field,op,value)=>{calls.push({field,op,value});return query;},orderBy:field=>{calls.push({orderBy:field});return query;},limit:()=>query,get:async()=>({docs:[]})};
 const db={collection:()=>query,doc:()=>({}),runTransaction:async callback=>callback({get:async()=>({exists:true,data:()=>({state:'pending',nextAttemptAt:0})}),set:(_,values)=>{claimed=values;}})};
 const s=firestoreAttendanceStore(db);await s.pending(25);assert.equal(calls[0].field,'nextAttemptAt');assert.equal(calls[0].op,'<=');assert.equal(calls[1].orderBy,'nextAttemptAt');
 await s.claim('op','claim',1000,121000);assert.equal(claimed.nextAttemptAt,121000);assert.equal(claimed.claimExpiresAt,121000);
});

test('idle attendance worker backs off; committed submissions wake it without duplicate loops',async()=>{
 let scheduled,delay,clears=0,calls=0;const worker=createAttendanceWorker({drain:async()=>{calls++;return {processed:0,nextRetryAt:null};},setTimer:(fn,ms)=>{scheduled=fn;delay=ms;return 1;},clearTimer:()=>{clears++;}});
 assert.equal(delay,0);await scheduled();assert.equal(calls,1);assert.equal(delay,240000);
 worker.wake();worker.wake();assert.equal(delay,0);await scheduled();assert.equal(calls,2);assert.equal(delay,240000);assert(clears>0);worker.stop();
});
test('early empty scan preserves known retry deadline instead of deferring four minutes',async()=>{
 let time=1000,scheduled,delay,calls=0;
 const worker=createAttendanceWorker({now:()=>time,drain:async()=>{
  calls++;return calls===1?{processed:1,nextRetryAt:11000}:{processed:0,nextRetryAt:null};
 },setTimer:(fn,ms)=>{scheduled=fn;delay=ms;return 1;},clearTimer:()=>{}});
 await scheduled();assert.equal(delay,2000);
 time=3000;await scheduled();assert.equal(delay,8000,'keep 10s retry after early empty scan');
 time=11000;await scheduled();assert.equal(delay,240000,'resume idle only after due deadline was scanned');
 assert.equal(calls,3);worker.stop();
});

test('unrelated wake and later retry cannot erase an earlier deadline',async()=>{
 let time=1000,scheduled,delay,calls=0;
 const worker=createAttendanceWorker({now:()=>time,drain:async()=>{
  calls++;return calls===1?{processed:1,nextRetryAt:15000}:calls===2?{processed:1,nextRetryAt:30000}:{processed:0,nextRetryAt:null};
 },setTimer:(fn,ms)=>{scheduled=fn;delay=ms;return 1;},clearTimer:()=>{}});
 await scheduled();assert.equal(delay,2000);
 time=3000;worker.wake();await scheduled();assert.equal(delay,2000);
 time=5000;await scheduled();assert.equal(delay,10000,'keep original earlier deadline');
 worker.stop();
});

test('active worker respects retry deadline and retains a wake arriving during upload',async()=>{
 let scheduled,delay,release,calls=0;const wait=new Promise(r=>release=r);
 const worker=createAttendanceWorker({now:()=>1000,drain:async()=>{calls++;if(calls===1)await wait;return {processed:1,nextRetryAt:9000};},setTimer:(fn,ms)=>{scheduled=fn;delay=ms;return 1;},clearTimer:()=>{}});
 const active=scheduled();worker.wake();release();await active;assert.equal(delay,0);await scheduled();assert.equal(delay,2000);worker.stop();
});


test('batch Firestore claim and finalize work is bounded to four and preserves Script order',async()=>{
 const s=store(),originalClaim=s.claim,originalFinish=s.finish;
 let activeClaims=0,maxClaims=0,activeFinishes=0,maxFinishes=0,deliveries=0;
 s.claim=async(...args)=>{
  activeClaims++;maxClaims=Math.max(maxClaims,activeClaims);
  try{await new Promise(resolve=>setImmediate(resolve));return await originalClaim(...args);}
  finally{activeClaims--;}
 };
 s.finish=async(...args)=>{
  activeFinishes++;maxFinishes=Math.max(maxFinishes,activeFinishes);
  try{await new Promise(resolve=>setImmediate(resolve));return await originalFinish(...args);}
  finally{activeFinishes--;}
 };
 const expected=[];
 const q=createAttendanceQueue({store:s,now:()=>1000,batchSize:25,minBatchSize:25,maxBatchSize:25,deliver:async(_,items)=>{
  deliveries++;assert.deepEqual(items.map(item=>item.operationId),expected);
  assert.equal(items.length,25);assert(items.every(x=>x.claim));
  return items.map(i=>({operationId:i.operationId,success:true}));
 }});
 for(let i=0;i<25;i++)expected.push((await q.enqueue(event(A,'concurrent-'+i))).operationId);
 await q.drain();
 assert.equal(deliveries,1);assert(maxClaims>1&&maxClaims<=4);
 assert(maxFinishes>1&&maxFinishes<=4);assert.equal(q.metrics.completed,25);
 assert([...s.rows.values()].every(x=>x.state==='completed'));
 const timings=q.metrics.lastPhaseTiming;
 for(const key of ['queueReadMs','claimMs','scriptMs','finishMs','totalMs','scriptBatches'])
  assert(Number.isFinite(timings[key])&&timings[key]>=0,key);
 assert.equal(timings.processed,25);assert.equal(timings.scriptBatches,1);
});
test('failed final transaction cannot ACK that record but successful peers finish and drain guard waits for all',async()=>{
 const s=store(),normalFinish=s.finish;let failedId,failOnce=true,time=1000,settled=0;
 const q=createAttendanceQueue({store:s,now:()=>time,batchSize:25,minBatchSize:25,maxBatchSize:25,deliver:async(_,items)=>items.map(i=>({operationId:i.operationId,success:true}))});
 for(let i=0;i<8;i++){const op=(await q.enqueue(event(A,'failure-'+i))).operationId;if(i===0)failedId=op;}
 s.finish=async(...args)=>{
  await new Promise(resolve=>setImmediate(resolve));
  if(args[0]===failedId&&failOnce){failOnce=false;settled++;throw Error('durable store failed');}
  await normalFinish(...args);settled++;
 };
 await assert.rejects(q.drain(),/durable store failed/);
 assert.equal(settled,8);assert.equal(s.rows.get(failedId).state,'processing');
 assert.equal([...s.rows.values()].filter(x=>x.state==='completed').length,7);
 assert.equal(q.metrics.completed,7);
 time+=120001;await q.drain();
 assert.equal(s.rows.get(failedId).state,'completed');
 assert.equal(s.rows.size,8);
});

test('adaptive concurrency caps independent schools at two and serializes each school',async()=>{
 const s=store();let active=0,peak=0,fail=false;const schools=new Set();
 const q=createAttendanceQueue({store:s,batchSize:25,maxBatchSize:25,minBatchSize:25,now:()=>1000,deliver:async(school,items)=>{
  assert(!schools.has(school));schools.add(school);active++;peak=Math.max(peak,active);
  await new Promise(resolve=>setImmediate(resolve));active--;schools.delete(school);
  return fail?[]:items.map(i=>({operationId:i.operationId,success:true}));
 }});
 for(let n=0;n<25;n++)await q.enqueue(event(A,'warm'+n));await q.drain();assert.equal(q.metrics.concurrency,2);
 for(let n=0;n<12;n++){await q.enqueue(event(A,'next'+n));await q.enqueue(event(B,'next'+n));}
 await q.drain();assert.equal(peak,2);assert.equal(q.metrics.completed,49);
 fail=true;await q.enqueue(event(B,'retry'));await q.drain();assert.equal(q.metrics.concurrency,1);assert.equal(q.metrics.retried,1);
 assert.throws(()=>createAttendanceQueue({store:s,deliver:async()=>[],maxConcurrency:3}),/Invalid bounded/);
});

test('a failed parallel store write cannot release the drain guard while another school is active',async()=>{
 const s=store();let phase=0,release,started;const running=new Promise(r=>started=r),hold=new Promise(r=>release=r);
 const finish=s.finish;s.finish=async(...args)=>{if(phase&&s.rows.get(args[0]).schoolId===A)throw Error('store unavailable');return finish(...args);};
 const q=createAttendanceQueue({store:s,batchSize:25,minBatchSize:25,maxBatchSize:25,deliver:async(school,items)=>{
  if(phase&&school===B){started();await hold;}
  return items.map(i=>({operationId:i.operationId,success:true}));
 }});
 for(let n=0;n<25;n++)await q.enqueue(event(A,'warm'+n));await q.drain();phase=1;
 await q.enqueue(event(A,'active'));await q.enqueue(event(B,'active'));
 const draining=q.drain();const rejected=assert.rejects(draining,/store unavailable/);
 await running;await new Promise(r=>setImmediate(r));assert.deepEqual(await q.drain(),{processed:0,nextRetryAt:null});
 release();await rejected;
 assert.equal([...s.rows.values()].find(r=>r.schoolId===B).state,'completed');
 assert.equal([...s.rows.values()].find(r=>r.schoolId===A&&r.state==='processing').state,'processing');
});

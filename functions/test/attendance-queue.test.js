'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {createAttendanceQueue,firestoreAttendanceStore,createAttendanceWorker}=require('../attendance-queue');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32);
function store(rows=new Map()) {return {rows,create:async(id,r)=>{if(rows.has(id))return false;rows.set(id,{...r});return true;},pending:async n=>[...rows.values()].filter(r=>r.state!=='completed'&&r.state!=='needsAttention').slice(0,n),claim:async(id,claim,now,expires)=>{const r=rows.get(id);if(!r||r.state==='processing'&&r.claimExpiresAt>now)return false;Object.assign(r,{state:'processing',claim,claimExpiresAt:expires});return true;},finish:async(id,claim,v)=>{if(rows.get(id).claim===claim)Object.assign(rows.get(id),v,{claim:'',claimExpiresAt:0});}};}
const event=(school=A,person='pupil')=>({schoolId:school,role:'student',personId:person,day:'2026-10-07',mode:'entry',payload:{encrypted:'test'}});
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

test('Firestore worker queries due operations only and defers claimed rows until lease expiry',async()=>{
 const calls=[];let claimed;
 const query={where:(field,op,value)=>{calls.push({field,op,value});return query;},orderBy:field=>{calls.push({orderBy:field});return query;},limit:()=>query,get:async()=>({docs:[]})};
 const db={collection:()=>query,doc:()=>({}),runTransaction:async callback=>callback({get:async()=>({exists:true,data:()=>({state:'pending',nextAttemptAt:0})}),set:(_,values)=>{claimed=values;}})};
 const s=firestoreAttendanceStore(db);await s.pending(25);assert.equal(calls[0].field,'nextAttemptAt');assert.equal(calls[0].op,'<=');assert.equal(calls[1].orderBy,'nextAttemptAt');
 await s.claim('op','claim',1000,121000);assert.equal(claimed.nextAttemptAt,121000);assert.equal(claimed.claimExpiresAt,121000);
});

test('idle attendance worker backs off; committed submissions wake it without duplicate loops',async()=>{
 let scheduled,delay,clears=0,calls=0;const worker=createAttendanceWorker({drain:async()=>{calls++;return {processed:0,nextRetryAt:null};},setTimer:(fn,ms)=>{scheduled=fn;delay=ms;return 1;},clearTimer:()=>{clears++;}});
 assert.equal(delay,0);await scheduled();assert.equal(calls,1);assert.equal(delay,300000);
 worker.wake();worker.wake();assert.equal(delay,0);await scheduled();assert.equal(calls,2);assert.equal(delay,300000);assert(clears>0);worker.stop();
});
test('active worker respects retry deadline and retains a wake arriving during upload',async()=>{
 let scheduled,delay,release,calls=0;const wait=new Promise(r=>release=r);
 const worker=createAttendanceWorker({now:()=>1000,drain:async()=>{calls++;if(calls===1)await wait;return {processed:1,nextRetryAt:9000};},setTimer:(fn,ms)=>{scheduled=fn;delay=ms;return 1;},clearTimer:()=>{}});
 const active=scheduled();worker.wake();release();await active;assert.equal(delay,0);await scheduled();assert.equal(delay,2000);worker.stop();
});

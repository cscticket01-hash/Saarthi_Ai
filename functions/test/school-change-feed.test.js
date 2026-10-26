'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {createSchoolChangeFeed}=require('../school-change-feed');
const {fixture,A,B,key,time}=require('./helpers/managed-school-broker');
const {createManagedSchools}=require('../managed-schools');
function sharedCloud(){
 const records=new Map(),listeners=new Map();let tail=Promise.resolve();
 const snapshot=p=>({exists:records.has(p),data:()=>structuredClone(records.get(p))});
 const db={doc:p=>({path:p,onSnapshot(next){const rows=listeners.get(p)||new Set();listeners.set(p,rows);rows.add(next);queueMicrotask(()=>{if(rows.has(next))next(snapshot(p));});return()=>{rows.delete(next);if(!rows.size)listeners.delete(p);};}}),
  runTransaction(fn){const run=tail.then(()=>fn({get:async r=>snapshot(r.path),set(r,v){records.set(r.path,structuredClone(v));for(const next of listeners.get(r.path)||[])queueMicrotask(()=>next(snapshot(r.path)));}}));tail=run.catch(()=>{});return run;}};
 return {db,records,listeners};
}
test('five independent PCs receive a committed hint immediately across broker instances; other school stays isolated',async()=>{
 const cloud=sharedCloud(),collections=['students_directory','fee_payments','school_config'];
 const feeds=Array.from({length:5},()=>createSchoolChangeFeed({db:cloud.db,collections,waitMillis:100}));
 await feeds[0].publish(A,'school_config');
 const initial=await Promise.all(feeds.map(f=>f.wait(A)));
 const started=performance.now();const waiting=feeds.map((f,i)=>f.wait(A,initial[i].cursor));
 await feeds[0].publish(A,'students_directory');
 const hints=await Promise.all(waiting);
 for(const h of hints){assert.deepEqual(h.collections,['students_directory']);assert.equal(h.recordRevision,undefined);assert.deepEqual(h.records,{});}
 const foreign=await feeds[0].wait(B);assert.equal(foreign.cursor,'empty:0');
 console.log('FIVE_PC_HINT_MEASUREMENTS',JSON.stringify({environment:'synthetic Firestore listener simulation',clients:5,milliseconds:performance.now()-started,liveNetwork:false}));
 assert.equal(cloud.listeners.size,0);
});
test('all business collections, concurrent commits, reconnect, eviction gaps and restart retain discoverability',async()=>{
 const cloud=sharedCloud(),collections=['students_directory','teachers_directory','fee_payments','school_expenses','exam_results','school_config','attendance_records','school_notices'];
 const feed=createSchoolChangeFeed({db:cloud.db,collections,waitMillis:5});
 const initial=await feed.wait(A);
 await Promise.all(collections.map(c=>feed.publish(A,c)));
 const changed=await feed.wait(A,initial.cursor);assert.deepEqual(new Set(changed.collections),new Set(collections));
 assert.equal([...cloud.records.values()][0].events.length,collections.length);
 const restarted=createSchoolChangeFeed({db:cloud.db,collections,waitMillis:5});
 assert.deepEqual((await restarted.wait(A,initial.cursor)).collections,changed.collections);
 for(let i=0;i<70;i++)await feed.publish(A,'fee_payments');
 const gap=await feed.wait(A,initial.cursor);assert.equal(gap.reset,true);assert.deepEqual(gap.collections,collections);
 assert.equal([...cloud.records.values()][0].events.length,64);
 const idle=await feed.wait(A,gap.cursor);assert.deepEqual(idle.collections,[]);assert.equal(idle.cursor,gap.cursor);
 assert.equal(cloud.listeners.size,0);
});
test('bounded waiters reject overload and bad cursors without leaking subscriptions',async()=>{
 const cloud=sharedCloud(),feed=createSchoolChangeFeed({db:cloud.db,collections:['fee_payments'],waitMillis:10,maxWaiters:1});
 const init=await feed.wait(A);const pending=feed.wait(A,init.cursor);
 await assert.rejects(feed.wait(A,init.cursor),e=>e.status===429);
 await pending;assert.equal(cloud.listeners.size,0);
 await assert.rejects(feed.wait(A,'forged'),e=>e.status===400);
 await assert.rejects(feed.wait('other'),/school/);
});
test('multi-collection hint uses one transaction; failed hint publication retains a durable recovery intent',async()=>{
 const cloud=sharedCloud();let writes=0;
 const original=cloud.db.runTransaction;
 cloud.db.runTransaction=(...args)=>{writes++;return original(...args);};
 const feed=createSchoolChangeFeed({db:cloud.db,collections:['attendance_records','attendance_logs']});
 await feed.publishMany(A,['attendance_records','attendance_logs','attendance_logs']);
 assert.equal(writes,1);assert.equal([...cloud.records.values()][0].events.length,2);
 const base=fixture(),db={...base.db,doc:p=>p.startsWith('school_sync_hints/')?cloud.db.doc(p):base.db.doc(p),
  runTransaction:fn=>cloud.db.runTransaction(tx=>fn({get:tx.get,set:(ref,value)=>{if(ref.path.startsWith('school_sync_hints/'))throw Error('Hint storage unavailable');tx.set(ref,value);}}))};
 const handle=createManagedSchools({auth:base.auth,db,projectId:'central',encryptionKey:key,now:()=>time,
  fetchImpl:async()=>({ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,syncProtocol:2,recordRevision:'committed'})})});
 const started=performance.now();
 const ack=await handle({method:'POST',headers:{authorization:'Bearer A'},body:{action:'managed/records',schoolId:A,
  collection:'fee_payments',operation:'write',id:'receipt',data:{amount:500},syncProtocol:2,
  operationId:'synthetic-operation-0002',expectedRecordRevision:''}});
 assert.equal(ack.recordRevision,'committed');assert(performance.now()-started<2500);
 assert.equal(Object.values(cloud.records.get('school_sync_delivery/'+A).entries)[0].state,'committed');
});
test('events are authenticated through existing school boundaries and unavailable feed fails visibly',async()=>{
 const f=fixture();
 await assert.rejects(f.call({action:'managed/events',schoolId:B}),e=>e.status===403);
 await assert.rejects(f.call({action:'managed/events',schoolId:A},'bad'),e=>e.status===401);
 await assert.rejects(f.call({action:'managed/events',schoolId:A}),e=>e.status===503);
});
test('delta after a remote-instance commit cannot reuse a stale five-second view',async()=>{
 let revision='one';
 const f=fixture(async()=>({ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,
  syncProtocol:2,changes:{fee_payments:{syncProtocol:2,collectionRevision:revision,
   records:{receipt:{schoolId:A,_syncRevision:revision,amount:500}}}}})}));
 const request={action:'managed/changes',schoolId:A,collections:['fee_payments'],knownRevisions:{}};
 assert.equal((await f.call(request)).changes.fee_payments.collectionRevision,'one');
 revision='two'; // Another broker committed; this process receives no local invalidation.
 assert.equal((await f.call(request)).changes.fee_payments.collectionRevision,'two');
 assert.equal(f.sent.length,2);
});
test('Android push/resume refresh bypasses cached dashboard content on any broker',async()=>{
 let revision='one';
 const f=fixture(async()=>({ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,
  revision,sessionExpiresAt:time+60000})}));
 const request={action:'managed/mobile',schoolId:A,request:{action:'mobile_dashboard',sessionToken:'verified'}};
 assert.equal((await f.call(request)).revision,'one');
 revision='two';
 const signalled={...request,request:{...request.request,afterSignal:true}};
 assert.equal((await f.call(signalled)).revision,'two');
 revision='three';
 assert.equal((await f.call(signalled)).revision,'three');
 assert.equal(f.sent.length,3);
});
test('broker publishes only signed committed writes and rechecks membership after waiting',async()=>{
 const base=fixture(),cloud=sharedCloud();let committed=true;
 const db={...base.db,doc:p=>p.startsWith('school_sync_hints/')?cloud.db.doc(p):base.db.doc(p),
  runTransaction:cloud.db.runTransaction};
 const handle=createManagedSchools({auth:base.auth,db,projectId:'central',encryptionKey:key,now:()=>time,
  fetchImpl:async(url,opt)=>({ok:true,status:200,text:async()=>JSON.stringify({
   success:committed,schoolId:JSON.parse(opt.body).schoolId,syncProtocol:2,
   recordRevision:committed?'verified-revision':undefined,message:committed?'':'Record revision conflict'})})});
 const call=body=>handle({method:'POST',headers:{authorization:'Bearer A'},body:{schoolId:A,...body}});
 const initial=await call({action:'managed/events'});
 const waiting=call({action:'managed/events',cursor:initial.cursor});
 const write={action:'managed/records',collection:'fee_payments',operation:'write',id:'receipt-1',
  data:{amount:500},syncProtocol:2,operationId:'synthetic-operation-0001',expectedRecordRevision:''};
 await call(write);const hint=await waiting;
 assert.equal(hint.reset,true);assert(hint.collections.includes('fee_payments'));
 const sequence=[...cloud.records.values()][0].sequence;
 committed=false;await assert.rejects(call(write),e=>e.code==='RECORD_REVISION_CONFLICT');
 assert.equal([...cloud.records.values()][0].sequence,sequence);
 const denied=call({action:'managed/events',cursor:hint.cursor});
 // Wake an established listener only after the initial identity check passed.
 await new Promise(resolve=>setImmediate(resolve));
 base.docs.get('school_memberships/A').active=false;
 await createSchoolChangeFeed({db:cloud.db,collections:['fee_payments']}).publish(A,'fee_payments');
 await assert.rejects(denied,e=>e.status===403);
 assert.equal(cloud.listeners.size,0);
});


test('interior gaps, malformed hints and missing tails force broad reconciliation, including an apparently current cursor',()=>{
 const cloud=sharedCloud(),feed=createSchoolChangeFeed({db:cloud.db,collections:['fee_payments','teachers_directory']});
 const epoch='00000000-0000-4000-8000-000000000000';
 const base={epoch,sequence:3,events:[1,2,3].map(sequence=>({sequence,collection:'fee_payments',id:'receipt-'+sequence}))};
 assert.deepEqual(feed.project(base,epoch+':0').records.fee_payments,['receipt-1','receipt-2','receipt-3']);
 for(const state of [
  {...base,events:[base.events[0],base.events[2]]},
  {...base,events:base.events.slice(0,2)},
  {...base,events:[...base.events.slice(0,2),{...base.events[2],collection:'foreign'}]},
  {...base,events:[...base.events.slice(0,2),{...base.events[2],id:''}]},
  {...base,events:[]},
 ])for(const cursor of [epoch+':0',epoch+':3']){
  const event=feed.project(state,cursor);
  assert.equal(event.reset,true);assert.deepEqual(event.collections,['fee_payments','teachers_directory']);assert.deepEqual(event.records,{});
 }
 for(const sequence of [-1,NaN,1.5,Number.MAX_SAFE_INTEGER])assert.throws(()=>feed.project({...base,sequence},epoch+':0'),e=>e.status===503);
});

test('corrupt durable snapshot rejects wait visibly and releases listener capacity',async()=>{
 const cloud=sharedCloud(),feed=createSchoolChangeFeed({db:cloud.db,collections:['fee_payments'],waitMillis:20,maxWaiters:1});
 cloud.records.set('school_sync_hints/'+A,{epoch:'bad',sequence:1,events:[]});
 await assert.rejects(feed.wait(A),e=>e.status===503);
 assert.equal(cloud.listeners.size,0);
 cloud.records.delete('school_sync_hints/'+A);
 assert.equal((await feed.wait(A)).reset,true);
});

test('15000 synthetic commits keep five reconnecting PCs discoverable with bounded hints and school isolation',async()=>{
 const cloud=sharedCloud(),collections=['students_directory','fee_payments','attendance_records'];
 const feed=createSchoolChangeFeed({db:cloud.db,collections,waitMillis:1});
 const initial=(await feed.wait(A)).cursor,cursors=Array(5).fill(initial);
 let exact=0,resets=0;const started=performance.now();
 for(let i=1;i<=15000;i++){
  await feed.publish(A,collections[i%3],'record-'+i);
  for(let pc=0;pc<5;pc++)if(i%[1,7,61,127,1000][pc]===0){
   const event=feed.project(cloud.records.get('school_sync_hints/'+A),cursors[pc]);
   assert(event);assert.notEqual(event.cursor,cursors[pc]);
   if(event.reset){resets++;assert.deepEqual(event.collections,collections);}
   else {exact++;assert(Object.values(event.records).every(ids=>ids.length<=64));}
   cursors[pc]=event.cursor;
  }
 }
 for(let pc=0;pc<5;pc++){
  const state=cloud.records.get('school_sync_hints/'+A),event=feed.project(state,cursors[pc]);
  if(event)cursors[pc]=event.cursor;
  assert.equal(cursors[pc],state.epoch+':15000');
 }
 assert.equal(cloud.records.size,1);assert.equal(cloud.records.get('school_sync_hints/'+A).events.length,64);
 assert.equal((await feed.wait(B)).cursor,'empty:0');assert.equal(cloud.listeners.size,0);
 console.log('SYNC3_HINT_LOAD',JSON.stringify({environment:'synthetic in-memory Firestore transactions; no provider throughput claim',commits:15000,pcs:5,exactCatchups:exact,gapReconciliations:resets,elapsedMillis:performance.now()-started}));
});

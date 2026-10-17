'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {createSchoolChangeFeed}=require('../school-change-feed');
const {fixture,A,B}=require('./helpers/managed-school-broker');
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
test('events are authenticated through existing school boundaries and unavailable feed fails visibly',async()=>{
 const f=fixture();
 await assert.rejects(f.call({action:'managed/events',schoolId:B}),e=>e.status===403);
 await assert.rejects(f.call({action:'managed/events',schoolId:A},'bad'),e=>e.status===401);
 await assert.rejects(f.call({action:'managed/events',schoolId:A}),e=>e.status===503);
});

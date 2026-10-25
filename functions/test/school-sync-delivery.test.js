'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {createSchoolSyncDelivery}=require('../school-sync-delivery');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32);
function setup(){const docs=new Map();let tail=Promise.resolve(),time=100000;
 const snapshot=p=>({exists:docs.has(p),data:()=>structuredClone(docs.get(p))});
 const db={doc:p=>({path:p,get:async()=>snapshot(p)}),runTransaction:fn=>{const run=tail.then(()=>fn({get:async r=>snapshot(r.path),set:(r,v)=>docs.set(r.path,structuredClone(v))}));tail=run.catch(()=>{});return run;}};
 const published=[],feed={enabled:true,collections:['students_directory','documents','fee_payments'],publishMany:async(...args)=>published.push(args)};
 return {db,docs,feed,published,create:()=>createSchoolSyncDelivery({db,feed,now:()=>time}),advance:()=>time+=3600001};}
const body={action:'managed_records',syncProtocol:2,operation:'write',collection:'fee_payments',id:'receipt',operationId:'original-operation-001'};
test('prepared intent survives crash and publishes only after authenticated same-operation proof',async()=>{
 const f=setup(),first=f.create();await first.prepare(A,body);
 const recovered=f.create();assert.equal((await recovered.recover(A,async()=>false)).repaired,0);assert.equal(f.published.length,0);
 f.advance();assert.equal((await recovered.recover(A,async ticket=>ticket.operationId===body.operationId)).repaired,1);
 assert.deepEqual(f.published[0],[A,['fee_payments'],'receipt']);assert.equal(Object.keys(f.docs.get('school_sync_delivery/'+A).entries).length,0);
});
test('verified commit survives notification failure and restart; retry never sends record writes',async()=>{
 const f=setup(),owner=f.create(),ticket=await owner.prepare(A,body);f.feed.publishMany=async()=>{throw Error('offline');};
 await assert.rejects(owner.committed(ticket,'cloud-revision'));
 assert.equal(Object.values(f.docs.get('school_sync_delivery/'+A).entries)[0].state,'committed');
 f.feed.publishMany=async(...args)=>f.published.push(args);
 assert.equal((await f.create().recover(A,async()=>{throw Error('No record probe needed for verified commit');})).repaired,1);
 assert.equal(f.published.length,1);
});
test('five receivers claim one pending notification, and other schools remain isolated',async()=>{
 const f=setup();await f.create().prepare(A,body);await f.create().prepare(B,{...body,id:'other'});
 let checks=0;await Promise.all(Array.from({length:5},()=>f.create().recover(A,async()=>{checks++;return true;})));
 assert.equal(checks,1);assert.equal(f.published.length,1);assert.equal(Object.keys(f.docs.get('school_sync_delivery/'+B).entries).length,1);
 assert.equal(JSON.stringify(f.docs.get('school_sync_delivery/'+A)).includes('amount'),false);
});
test('explicit rejection cancels only the matching intent; student deletion wakes child collections',async()=>{
 const f=setup(),owner=f.create(),ticket=await owner.prepare(A,body);await owner.remove(ticket);
 assert.equal((await owner.recover(A,async()=>true)).repaired,0);
 const deletion=await owner.prepare(A,{...body,operation:'delete',collection:'students_directory'});await owner.committed(deletion,'deleted');
 assert.deepEqual(f.published[0],[A,f.feed.collections]);
});

test('a rejected duplicate cannot cancel a previously committed notification',async()=>{
 const f=setup(),owner=f.create(),ticket=await owner.prepare(A,body);
 f.feed.publishMany=async()=>{throw Error('publish interrupted');};await assert.rejects(owner.committed(ticket,'real-revision'));
 await owner.rejected(ticket);
 assert.equal(Object.values(f.docs.get('school_sync_delivery/'+A).entries)[0].state,'committed');
 f.feed.publishMany=async(...args)=>f.published.push(args);
 assert.equal((await owner.recover(A,async()=>false)).repaired,1);
});

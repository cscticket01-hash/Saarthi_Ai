'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {createSchoolDeltaSingleflight}=require('../school-delta-singleflight');
const {fixture,A,B}=require('./helpers/managed-school-broker');
const body={action:'managed_delta',collections:['fee_payments'],knownRevisions:{fee_payments:'previous'}};
const tick=()=>new Promise(resolve=>setImmediate(resolve));

test('identical simultaneous original school deltas share one provider read, never a durable cache',async()=>{
 const single=createSchoolDeltaSingleflight();let calls=0,release;
 const read=()=>{calls++;return new Promise(resolve=>release=resolve)};
 const x=single(A,body,read),y=single(A,body,read);
 assert.strictEqual(x,y);
 await tick();assert.equal(calls,1);
 release({changes:{fee_payments:{records:{}}}});
 await Promise.all([x,y]);
 const z=await single(A,body,async()=>{calls++;return {fresh:true}});
 assert.equal(calls,2);assert.equal(z.fresh,true);
});

test('different school/checkpoint and failures never share provider receipts',async()=>{
 const single=createSchoolDeltaSingleflight();let count=0;
 const pending=[];
 const read=()=>{count++;return new Promise((resolve,reject)=>pending.push({resolve,reject}))};
 const a=single(A,body,read);
 const b=single(B,body,read);
 const c=single(A,{...body,knownRevisions:{fee_payments:'new'}},read);
 await tick();assert.equal(count,3);
 pending[0].reject(Error('Script timeout'));
 pending[1].resolve({schoolId:B});
 pending[2].resolve({schoolId:A});
 await assert.rejects(a,/Script timeout/);
 assert.equal((await b).schoolId,B);
 assert.equal((await c).schoolId,A);
 assert.deepEqual(await single(A,body,async()=>({freshAfterFailure:true})),
  {freshAfterFailure:true});
});

test('bounded singleflight pressure executes excess identities independently',async()=>{
 const run=createSchoolDeltaSingleflight(1);let count=0,release;
 const held=run(A,body,()=>{count++;return new Promise(resolve=>release=resolve)});
 const extra=run(A,{...body,knownRevisions:{}},async()=>{count++;return 'different'});
 await tick();assert.equal(count,2);assert.equal(await extra,'different');
 release('original');assert.equal(await held,'original');
 assert.throws(()=>run('foreign',body,async()=>{}),/School-bound/);
 assert.throws(()=>run(A,{action:'managed_upload'},async()=>{}),/read-only/);
});

test('broker collapses concurrent same-school full Script reads without losing next change',async()=>{
 let sends=0,finish;
 const data=rev=>({success:true,schoolId:A,syncProtocol:2,
  changes:{fee_payments:{syncProtocol:2,collectionRevision:rev,records:{}}}});
 const b=fixture(async(_url,_opt)=>{
  sends++;
  if(sends===1)return new Promise(resolve=>finish=()=>resolve({
   ok:true,status:200,text:async()=>JSON.stringify(data('first'))}));
  return {ok:true,status:200,text:async()=>JSON.stringify(data('second'))};
 });
 const request={action:'managed/changes',collections:['fee_payments'],
  knownRevisions:{fee_payments:'old'}};
 const first=b.call(request),second=b.call(request);
 for(let i=0;i<15&&sends===0;i++)await tick();
 assert.equal(sends,1,'duplicate requests cannot take two simultaneous Script locks');
 finish();
 const [a,c]=await Promise.all([first,second]);
 assert.equal(a.changes.fee_payments.collectionRevision,'first');
 assert.equal(c.changes.fee_payments.collectionRevision,'first');
 assert.equal((await b.call(request)).changes.fee_payments.collectionRevision,'second');
 assert.equal(sends,2,'a later read is never served from a stale snapshot');
});

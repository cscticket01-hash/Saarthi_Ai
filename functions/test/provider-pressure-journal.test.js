'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {createProviderPressureJournal}=require('../provider-pressure-journal');
const {createProviderPressure,quotaError}=require('../provider-pressure');
function shared(){
 let value,chain=Promise.resolve(),transactions=0;const listeners=new Set();
 const snapshot=()=>({exists:!!value,data:()=>structuredClone(value)});
 const ref={onSnapshot(next,error){listeners.add(next);next(snapshot());return ()=>listeners.delete(next);}};
 const db={doc:()=>ref,runTransaction(fn){transactions++;const task=chain.then(async()=>{
  let updated;
  const result=await fn({get:async()=>snapshot(),set:(_,v)=>{updated=structuredClone(v);}});
  if(updated){value=updated;for(const next of listeners)next(snapshot());}return result;
 });chain=task.catch(()=>{});return task;}};
 return {db,get transactions(){return transactions;},get value(){return value;},bad(v){value=v;for(const next of listeners)next(snapshot());}};
}
test('shared gate survives controller restart and only one cross-instance recovery probe runs',async()=>{
 const s=shared();let at=1000,calls=0,release;
 const j1=createProviderPressureJournal({db:s.db,projectId:'central',now:()=>at});
 const j2=createProviderPressureJournal({db:s.db,projectId:'central',now:()=>at});
 const p1=createProviderPressure({now:()=>at,journal:j1});
 const p2=createProviderPressure({now:()=>at,journal:j2});
 await assert.rejects(p1.run('owner','SCRIPT_QUOTA_EXCEEDED',()=>{throw quotaError('SCRIPT_QUOTA_EXCEEDED',120000);}));
 await assert.rejects(p2.run('owner','SCRIPT_QUOTA_EXCEEDED',()=>{calls++;}));assert.equal(calls,0);
 at+=120000;
 const probe=p1.run('owner','SCRIPT_QUOTA_EXCEEDED',()=>new Promise(r=>{release=r;calls++;}));
 while(!release)await new Promise(r=>setImmediate(r));
 await assert.rejects(p2.run('owner','SCRIPT_QUOTA_EXCEEDED',()=>{calls++;}));assert.equal(calls,1);
 release('verified');assert.equal(await probe,'verified');
 assert.equal(await p2.run('owner','SCRIPT_QUOTA_EXCEEDED',()=> 'next'), 'next');
 j1.close();j2.close();
});
test('healthy operations do not add a transaction per sync call and namespaces remain separate',async()=>{
 const s=shared();const j=createProviderPressureJournal({db:s.db,projectId:'central',now:()=>1000});
 const p=createProviderPressure({journal:j,now:()=>1000});
 for(let n=0;n<100;n++)assert.equal(await p.run('scope','SCRIPT_QUOTA_EXCEEDED',()=>n),n);
 assert.equal(s.transactions,0);
 await assert.rejects(p.run('scope','SCRIPT_QUOTA_EXCEEDED',()=>{throw quotaError('SCRIPT_QUOTA_EXCEEDED');}));
 assert.equal(await p.run('scope','CLOUDFLARE_QUOTA_EXCEEDED',()=>1),1);
 const before=s.transactions;await assert.rejects(p.run('scope','SCRIPT_QUOTA_EXCEEDED',()=>2));assert.equal(s.transactions,before);
 assert(!JSON.stringify(s.value).includes('scope'));j.close();
});
test('stale probe receipt cannot clear a new failure and malformed shared state fails closed',async()=>{
 const s=shared();let at=1000;const j=createProviderPressureJournal({db:s.db,projectId:'central',now:()=>at});
 await j.failedQuota('google','owner',60000);at+=60000;
 const ticket=await j.admit('google','owner');assert(ticket.claim);
 await j.failedQuota('google','owner',120000);await j.succeeded(ticket);
 assert((await j.admit('google','owner')).wait>=120000);
 s.bad({version:1,projectId:'foreign',gates:{}});
 await assert.rejects(j.admit('google','owner'),e=>e.code==='PROVIDER_PRESSURE_UNAVAILABLE');j.close();
});
test('probe crash lease expires without making a receipt or deleting queued work',async()=>{
 const s=shared();let at=1000;const j=createProviderPressureJournal({db:s.db,projectId:'central',now:()=>at});
 await j.failedQuota('google','owner',60000);at+=60000;
 const first=await j.admit('google','owner');assert(first.claim);
 assert((await j.admit('google','owner')).wait>0);at+=120000;
 const second=await j.admit('google','owner');assert(second.claim);assert.notEqual(first.claim,second.claim);j.close();
});

test('failed subscription retries after a bounded cooldown and explicit close stays closed',async()=>{
 let at=1000,subscriptions=0;
 const ref={onSnapshot(next,error){subscriptions++;if(subscriptions===1)error(Error('network'));else next({exists:false});return ()=>{};}};
 const j=createProviderPressureJournal({db:{doc:()=>ref},projectId:'central',now:()=>at});
 await assert.rejects(j.admit('google','owner'));await assert.rejects(j.admit('google','owner'));assert.equal(subscriptions,1);
 at+=30000;assert.equal(await j.admit('google','owner'),null);assert.equal(subscriptions,2);
 j.close();await assert.rejects(j.admit('google','owner'));assert.equal(subscriptions,2);
});

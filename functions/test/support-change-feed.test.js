'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {supportFeed}=require('../support-change-feed');
function fixture(){
 const observers=new Map();let subscriptions=0;
 const db={collection:()=>({where:(_,op,school)=>({limit:()=>({onSnapshot:(next,error)=>{
   subscriptions++;observers.set(school,{next,error});queueMicrotask(()=>next({docs:[]}));
   return ()=>observers.delete(school);
 }})})})};
 return {db,observers,get subscriptions(){return subscriptions;},publish(school,rows){observers.get(school).next({docs:rows.map(r=>({id:r.id,data:()=>r}))});}};
}
const row=(school,id,message='message')=>({schoolId:school,id,message,status:'open'});
test('support change feed returns delta, school-scoped removals and resets on listener loss',async()=>{
 const f=fixture(),feed=supportFeed(f.db,d=>d.data(),()=>Date.now());
 const start=await feed.changes('A');assert.equal(start.reset,true);assert.deepEqual(start.complaints,[]);
 f.publish('A',[row('A','1'),row('A','2')]);
 const delta=await feed.changes('A',start.cursor);assert.equal(delta.reset,false);assert.equal(delta.complaints.length,2);
 const idle=await feed.changes('A',delta.cursor);assert.equal(idle.cursor,delta.cursor);assert.deepEqual(idle.complaints,[]);assert.equal(f.subscriptions,1);
 f.publish('A',[row('A','1','reply')]);
 const changed=await feed.changes('A',delta.cursor);assert.deepEqual(changed.removed,['2']);assert.equal(changed.complaints[0].message,'reply');
 const other=await feed.changes('B',changed.cursor);assert.equal(other.reset,true);assert.deepEqual(other.complaints,[]);
 f.observers.get('A').error(Error('offline'));
 const reset=await feed.changes('A',changed.cursor);assert.equal(reset.reset,true);assert.notEqual(reset.cursor,changed.cursor);
});
test('oversized and unsupported listeners fall back rather than returning a partial history',async()=>{
 const f=fixture(),feed=supportFeed(f.db,d=>d.data(),()=>Date.now());
 const start=await feed.changes('A');
 f.publish('A',Array.from({length:501},(_,i)=>row('A',String(i))));
 assert.equal(f.observers.has('A'),false);
 const legacy={collection:()=>({where:()=>({limit:()=>({})})})};
 assert.deepEqual(await supportFeed(legacy,d=>d.data(),()=>0).changes('A',start.cursor),{fallback:true});
});

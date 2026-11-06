'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {createDeleteEverywhere}=require('../delete-everywhere');

const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32);
const root='schools/'+A+'/students_directory/one';
const child='schools/'+A+'/fee_payments/fee-1';
const op='original-delete-operation-0001',old='old-drive-revision',tombstone='drive-one';
const request={action:'managed_records',deleteEverywhereVersion:1,
  operation:'delete',collection:'students_directory',id:'one',
  operationId:op,expectedRecordRevision:old,syncProtocol:2};
function targets(){return [
  {collection:'students_directory',id:'one',sourceRevision:old,revision:tombstone,generation:'p-old'},
  {collection:'fee_payments',id:'fee-1',sourceRevision:'old-fee-revision',revision:'deleted-fee-revision',generation:'p-old'},
];}
function ack(list=targets()){
 return {success:true,schoolId:A,syncProtocol:2,recordRevision:tombstone,
   deleteEverywhereVersion:1,driveDeletionComplete:true,deletionTargets:list,
   record:{id:'one',schoolId:A,_syncDeleted:true,_syncRevision:tombstone,
     _syncOperationId:op,_syncErasePlan:{complete:true,targets:list}}};
}
function fixture(entries=[]){
 const data=new Map(entries),calls=[];
 const db={doc:path=>({path}),runTransaction:async fn=>{
   const writes=[];const value=await fn({
     get:async ref=>({exists:data.has(ref.path),data:()=>data.get(ref.path)}),
     delete:ref=>writes.push(ref.path)
   });
   for(const path of writes){calls.push(path);data.delete(path);}
   return value;
 }};
 return {data,calls,cleanup:createDeleteEverywhere({db})};
}
const source=()=>({schoolId:A,mobileStableId:'p-old',_syncRevision:old,name:'Original'});
const fee=()=>({schoolId:A,personId:'p-old',_syncRevision:'old-fee-revision',amount:100});

test('verified original Drive plan erases only exact tenant parent/fee and preserves other school',async()=>{
 const foreign='schools/'+B+'/students_directory/one',untouched='schools/'+A+'/students_directory/two';
 const licence='school_entitlements/'+A;
 const f=fixture([[root,source()],[child,fee()],
  [foreign,{schoolId:B,name:'Different school'}],
  [untouched,{schoolId:A,name:'Different pupil'}],
  [licence,{active:true}]]);
 const result=await f.cleanup.finish(A,request,ack());
 assert.equal(result.firebaseDeletionComplete,true);
 assert.equal(result.firebaseDeletedRecords,2);
 assert.deepEqual(f.calls,[root,child]);
 for(const path of [foreign,untouched,licence])assert(f.data.has(path));
 const retry=await f.cleanup.finish(A,request,ack());
 assert.equal(retry.firebaseDeletedRecords,0);
});

test('explicit generation-bound delete wins over a later SAME pupil edit',async()=>{
 const newer={...source(),name:'Edited offline from second PC',_syncRevision:'newer-revision'};
 const f=fixture([[root,newer]]);
 const result=await f.cleanup.finish(A,request,ack());
 assert.equal(result.firebaseDeletionComplete,true);
 assert.equal(result.firebaseDeletedRecords,1);
 assert(!f.data.has(root));
 assert.deepEqual(f.calls,[root]);
});

test('different generation, foreign ownership and newer tombstone all fail closed',async()=>{
 for(const row of [
  {...source(),mobileStableId:'p-new'},
  {...source(),schoolId:B},
  {...source(),mobileStableId:'p-new',_syncDeleted:true,
    _syncRevision:'unrelated-tombstone'}
 ]){
  const f=fixture([[root,row]]);
  await assert.rejects(f.cleanup.finish(A,request,ack()));
  assert(f.data.has(root));assert.equal(f.calls.length,0);
 }
});

test('matching immutable Firebase tombstone may be removed; partial failure retries same targets',async()=>{
 const f=fixture([[root,{...source(),_syncDeleted:true,_syncRevision:tombstone}],
   [child,{...fee(),personId:'p-new'}]]);
 await assert.rejects(f.cleanup.finish(A,request,ack()),e=>
   e.code==='DELETE_EVERYWHERE_GENERATION_CONFLICT');
 assert(!f.data.has(root));assert(f.data.has(child));
 f.data.set(child,fee());
 const recovered=await f.cleanup.finish(A,request,ack());
 assert.equal(recovered.firebaseDeletedRecords,1);
 assert.deepEqual(f.calls,[root,child]);
});

test('missing original Firebase rows are retry-safe, not invented as completed writes',async()=>{
 const f=fixture();
 const result=await f.cleanup.finish(A,request,ack());
 assert.equal(result.firebaseDeletionComplete,true);
 assert.equal(result.firebaseDeletedRecords,0);
 assert.deepEqual(f.calls,[]);
});

test('wrong school, fake Drive flags, wrong operation, incomplete plan or changed target identity never erase Firebase',async()=>{
 const variants=[
  p=>{p.schoolId=B;},
  p=>{p.driveDeletionComplete=false;},
  p=>{p.recordRevision='cf-temporary';},
  p=>{p.record._syncErasePlan.complete=false;},
  p=>{p.record._syncOperationId='another-delete';},
  p=>{p.record._syncDeleted=false;},
  p=>{p.record.id='other';},
  p=>{p.record._syncRevision='another-revision';},
  p=>{p.record=null;},
  p=>{p.deletionTargets=p.deletionTargets.map(t=>({...t}));p.deletionTargets[0].revision='other';},
  p=>{p.deletionTargets=p.deletionTargets.map(t=>({...t}));p.deletionTargets[1].id='other';},
  p=>{p.deletionTargets=p.deletionTargets.map(t=>({...t}));p.deletionTargets[1].collection='school_entitlements';},
  p=>{p.deletionTargets=p.deletionTargets.map(t=>({...t}));p.deletionTargets[1].id='../foreign';},
 ];
 for(const change of variants){
  const f=fixture([[root,source()]]);
  const proof=ack();change(proof);
  await assert.rejects(f.cleanup.finish(A,request,proof));
  assert(f.data.has(root),'Incomplete provider proof cannot remove pupil');
  assert.equal(f.calls.length,0);
 }
});


test('id-less Script tombstone proves its original operation and exact immutable plan, then deletes Firebase',async()=>{
 const proof=ack();delete proof.record.id;
 const f=fixture([[root,source()],[child,fee()]]);
 const out=await f.cleanup.finish(A,request,proof);
 assert.equal(out.firebaseDeletionComplete,true);
 assert.equal(out.firebaseDeletedRecords,2);
 assert.equal(f.data.has(root),false);
 assert.equal(f.data.has(child),false);
 const replay=await f.cleanup.finish(A,request,proof);
 assert.equal(replay.firebaseDeletedRecords,0);
});
test('id-less tombstone with changed operation or signed target never removes Firebase',async()=>{
 for(const mutate of [
  p=>{p.record._syncOperationId='another-operation';},
  p=>{p.record._syncErasePlan.targets=[...p.record._syncErasePlan.targets].reverse();},
  p=>{p.deletionTargets[0].revision='different-revision';}
 ]){
  const proof=ack();delete proof.record.id;mutate(proof);
  const f=fixture([[root,source()],[child,fee()]]);
  await assert.rejects(f.cleanup.finish(A,request,proof));
  assert.equal(f.data.has(root),true);
  assert.equal(f.data.has(child),true);
  assert.equal(f.calls.length,0);
 }
});

test('Firestore permission denial is explicit, private and never grants a final Delete ACK',async()=>{
 const denied=Object.assign(Error('Private provider and service-account details'),{code:7});
 const db={doc:path=>({path}),runTransaction:async()=>{throw denied}};
 const cleanup=createDeleteEverywhere({db});
 await assert.rejects(cleanup.finish(A,request,ack()),e=>
   e.status===503 && e.code==='DELETE_EVERYWHERE_FIREBASE_PERMISSION_DENIED' &&
   e.publicMessage===true && !String(e.message).includes('Private provider'));
});

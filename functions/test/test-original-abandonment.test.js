'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createTestOriginalAbandonment,SCHOOL,EPOCH}=require('../test-original-abandonment');
const {fixture,A}=require('./helpers/managed-school-broker');
function setup(){
 const f=fixture(),ref='school_live_migrations/'+SCHOOL;
 f.docs.set('schools/'+SCHOOL,{schoolName:'TEST Sync V2'});
 f.docs.set(ref,{inflight:Object.fromEntries(Array.from({length:14},(_,i)=>['token'+i,{collection:'school_notices',activeAttempts:0,operationBinding:{schoolId:SCHOOL,lane:'legacy',collection:'school_notices'},original:i}])),liveInflight:{},collections:{school_calendar:{state:'active'}},other:'preserve'});
 const action=createTestOriginalAbandonment({db:f.db,testSchoolId:SCHOOL,enabled:true,queuesDrained:async()=>true,now:()=>123});
 const m={schoolId:SCHOOL,uid:'test-owner'},b={confirmDisposableTest:EPOCH};
 return {...f,ref,action,m,b};
}
test('disposable cleanup disabled by default; production/foreign scope cannot enable it',async()=>{
 assert.equal(createTestOriginalAbandonment({}),null);
 assert.throws(()=>createTestOriginalAbandonment({enabled:true,testSchoolId:null}));
 const f=setup();await assert.rejects(f.action({...f.m,schoolId:A},{...f.b,operation:'preview'}));
 const normal=fixture();await assert.rejects(normal.call({action:'managed/test-originals',schoolId:A}),e=>e.status===403);
});
test('zero-write preview; CAS archives exactly14 as abandoned, never verified backup',async()=>{
 const f=setup(),before=structuredClone(f.docs.get(f.ref)),size=f.docs.size;
 const p=await f.action(f.m,{...f.b,operation:'preview'});
 assert.equal(p.previewOnly,true);assert.equal(p.count,14);assert.equal(f.docs.size,size);assert.deepEqual(f.docs.get(f.ref),before);
 const out=await f.action(f.m,{...f.b,operation:'abandon',expectedCohortHash:p.cohortHash});
 assert.equal(out.abandoned,14);assert.equal(out.backupVerified,false);assert.equal(out.unsettledWrites,0);
 const archive=f.docs.get('school_test_abandonment/'+SCHOOL+'/epochs/'+EPOCH);
 assert.deepEqual(archive.markers.inflight,before.inflight);assert.equal(archive.backupVerified,false);
 assert.deepEqual(f.docs.get(f.ref).collections,before.collections);assert.equal(f.docs.get(f.ref).other,'preserve');
 f.docs.get(f.ref).inflight.new={newPending:'untouched'};
 const replay=await f.action(f.m,{...f.b,operation:'abandon',expectedCohortHash:p.cohortHash});
 assert.equal(replay.alreadyApplied,true);assert.equal(replay.unsettledWrites,1);assert.ok(f.docs.get(f.ref).inflight.new);
});
test('changed cohort, active attempts, wrong collection, missing confirmation and queued delivery fail closed',async()=>{
 for(const change of [f=>delete f.docs.get(f.ref).inflight.token0,f=>{f.docs.get(f.ref).inflight.token0.activeAttempts=1;},f=>{f.docs.get(f.ref).inflight.token0.collection='students_directory';},f=>{f.b.confirmDisposableTest='wrong';},f=>{f.docs.get('schools/'+SCHOOL).schoolName='Actual school';}]){
  const f=setup();change(f);const original=structuredClone(f.docs.get(f.ref));await assert.rejects(f.action(f.m,{...f.b,operation:'preview'}));assert.deepEqual(f.docs.get(f.ref),original);
 }
 const f=setup(),p=await f.action(f.m,{...f.b,operation:'preview'});
 f.docs.get(f.ref).inflight.token0.original='changed';
 await assert.rejects(f.action(f.m,{...f.b,operation:'abandon',expectedCohortHash:p.cohortHash}),e=>e.code==='TEST_ORIGINAL_CAS_MISMATCH');
 const busy=createTestOriginalAbandonment({db:f.db,testSchoolId:SCHOOL,enabled:true,queuesDrained:async()=>false});
 await assert.rejects(busy(f.m,{...f.b,operation:'preview'}),e=>e.code==='TEST_ORIGINAL_DELIVERY_NOT_DRAINED');
});

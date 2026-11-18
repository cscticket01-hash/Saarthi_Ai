'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {fixture,A,B}=require('./helpers/managed-school-broker');
const {rolloutStatus}=require('../live-sync-rollout-status');
test('school rollout status remains own-school, read-only and cannot activate a disabled rollout',async()=>{
 const f=fixture(),before=JSON.stringify([...f.docs]);
 await assert.rejects(f.call({action:'managed/live/rollout-status',schoolId:B}),e=>e.status===403);
 const status=await f.call({action:'managed/live/rollout-status'});
 assert.equal(status.schoolId,A);assert.equal(status.configured,false);assert.equal(status.fullRolloutVerified,false);
 assert.ok(status.blockers.includes('BROKER_SCHOOL_NOT_ENABLED'));
 assert.equal(f.sent.length,0);assert.equal(JSON.stringify([...f.docs]),before);
 await assert.rejects(f.call({action:'managed/live/rollout-status'},'invalid'));
});
test('positive control-plane status never pretends legacy collections are active or unknown queues are empty',async()=>{
 const f=fixture();f.docs.set('school_live_migrations/'+A,{collections:{school_expenses:{state:'active'}},inflight:{uncertain:{secret:'not-returned'}}});
 const readDrive=async()=>({success:true,schoolId:A,storageReady:true,recordSyncVersion:2,sheetLifecycleVersion:1,teacherRetirementVersion:1,staffRetirementVersion:1,deleteEverywhereVersion:1,scriptBundleVersion:'2026-11-04.1'});
 const args={schoolId:A,enabled:true,db:f.db,readDrive,edge:{rpc:async(s,l)=>l==='live'?{schoolId:s,liveProtocol:1,cursor:0}:{pending:0,needsAttention:0}}};
 const result=await rolloutStatus(args);
 assert.equal(result.workerVerified,true);assert.equal(result.scriptVerified,true);assert.equal(result.pending,0);assert.equal(result.unsettledWrites,1);
 assert.equal(result.collections.school_expenses,'active');assert.equal(result.collections.students_directory,'legacy');
 assert.ok(result.blockers.includes('UNSETTLED_WRITES_REQUIRE_RECONCILIATION'));
 assert.ok(result.blockers.includes('VERIFIED_COLLECTION_MIGRATION_REQUIRED'));assert.ok(!JSON.stringify(result).includes('not-returned'));
 const retained=await rolloutStatus({...args,edge:{rpc:async(s,l)=>l==='live'
  ?{schoolId:s,liveProtocol:1,cursor:0}
  :{pending:0,needsAttention:l==='notices'?1:0,privatePayload:'not-returned'}}});
 assert.equal(retained.needsAttention,1);
 assert.deepEqual(retained.deliveryQueues,{records:{pending:0,needsAttention:0},notices:{pending:0,needsAttention:1}});
 assert.ok(retained.blockers.includes('LEGACY_DELIVERY_PENDING'));
 assert.ok(!JSON.stringify(retained).includes('not-returned'));
 const unknown=await rolloutStatus({...args,readDrive:async()=>({success:true,schoolId:B}),edge:{rpc:async()=>({})}});
 assert.equal(unknown.pending,null);assert.equal(unknown.queuesVerified,false);assert.equal(unknown.scriptVerified,false);assert.equal(unknown.workerVerified,false);
});

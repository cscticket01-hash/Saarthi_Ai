'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {fixture,A,B}=require('./helpers/managed-school-broker');
const {createLiveMigration}=require('../live-sync-migration');
const {bindOperation}=require('../live-sync-reconciliation');
const {legacyFingerprint,markNoticeRejection,isNoticeRejection}=require('../live-sync-rejection');
const body={action:'managed_records',collection:'school_notices',operation:'write',syncProtocol:2,
 id:'notice',operationId:'negative-notice-operation-001',expectedRecordRevision:'stale-revision',data:{schoolId:A,title:'Rejected synthetic edit'}};
const conflict=()=>Object.assign(Error('rejected'),{status:409,code:'RECORD_REVISION_CONFLICT'});
const markers=f=>f.docs.get('school_live_migrations/'+A)?.inflight||{};
function broker(message='Record revision conflict',operation='write'){
 const f=fixture(async(_,options)=>{const envelope=JSON.parse(options.body);
  return {ok:true,status:200,text:async()=>JSON.stringify({success:false,schoolId:envelope.schoolId,message})};
 },{cloudflareSync:{enabled:()=>true},liveSyncSchools:[A]});
 // Verified rollback selects the direct signed owner instead of a notice cache.
 f.docs.set('school_live_migrations/'+A,{collections:{school_notices:{state:'legacy',rollbackProof:{}}}});
 return f;
}
test('actual authenticated Script notice rejection remains HTTP 409 without an uncertain write marker',async()=>{
 for(const message of ['Record revision conflict','Sync operation ID conflict']){
  const f=broker(message);
  await assert.rejects(f.call({action:'managed/records',collection:body.collection,operation:body.operation,id:body.id,
   syncProtocol:2,operationId:body.operationId,expectedRecordRevision:body.expectedRecordRevision,data:body.data}),e=>e.status===409);
  assert.equal(f.sent.length,1);assert.deepEqual(markers(f),{});
 }
});
test('timeouts, forged public conflict flags and delete/cascade conflicts retain their markers',async()=>{
 for(const err of [Error('timeout'),Object.assign(conflict(),{providerWriteRejected:true})]){
  const f=fixture(),gate=createLiveMigration({db:f.db});
  await assert.rejects(gate.legacy(A,body,async()=>{throw err;}));assert.equal(Object.keys(markers(f)).length,1);
 }
 const f=broker();
 await assert.rejects(f.call({action:'managed/records',collection:body.collection,operation:'delete',id:body.id,
  syncProtocol:2,operationId:body.operationId,expectedRecordRevision:body.expectedRecordRevision}),e=>e.status===409);
 assert.equal(Object.keys(markers(f)).length,1);
});
test('a new rejection never clears a historical marker that lacks a full request fingerprint',async()=>{
 const f=broker(),historical={collection:body.collection,startedAt:1,activeAttempts:0,operationBinding:bindOperation(A,'legacy',body)};
 f.docs.get('school_live_migrations/'+A).inflight={historical:structuredClone(historical)};
 await assert.rejects(f.call({action:'managed/records',collection:body.collection,operation:body.operation,id:body.id,
  syncProtocol:2,operationId:body.operationId,expectedRecordRevision:body.expectedRecordRevision,data:body.data}));
 assert.deepEqual(markers(f),{historical});
});
test('changed CAS with the same operation and payload cannot share or settle the other attempt',async()=>{
 const f=fixture(),gate=createLiveMigration({db:f.db});
 let rejectFirst,started;const ready=new Promise(r=>started=r);
 const original={...body,expectedRecordRevision:'original-base'};
 const pending=gate.legacy(A,original,()=>{started();return new Promise((_,reject)=>rejectFirst=reject);});
 await ready;
 assert.notEqual(legacyFingerprint(A,original),legacyFingerprint(A,body));
 await assert.rejects(gate.legacy(A,body,async()=>{throw markNoticeRejection(conflict(),A,body);}));
 assert.equal(Object.keys(markers(f)).length,1);assert.equal(Object.values(markers(f))[0].activeAttempts,1);
 rejectFirst(Error('uncertain original'));await assert.rejects(pending);
 assert.equal(Object.keys(markers(f)).length,1);assert.equal(Object.values(markers(f))[0].activeAttempts,0);
});
test('identical concurrent attempts keep admission closed until the last peer settles',async()=>{
 const f=fixture(),gate=createLiveMigration({db:f.db});let rejectFirst,started;const ready=new Promise(r=>started=r);
 const pending=gate.legacy(A,body,()=>{started();return new Promise((_,reject)=>rejectFirst=reject);});
 await ready;
 await assert.rejects(gate.legacy(A,body,async()=>{throw markNoticeRejection(conflict(),A,body);}));
 assert.equal(Object.values(markers(f))[0].activeAttempts,1);
 await assert.rejects(gate.prepare(A,'school_notices',async()=>true,async()=>({state:'active'})),e=>e.code==='LIVE_LEGACY_DRAIN_GRACE');
 rejectFirst(Error('transport lost'));await assert.rejects(pending);assert.deepEqual(markers(f),{});
});
test('private rejection proof binds school and every request field and excludes other record owners',()=>{
 const err=markNoticeRejection(conflict(),A,body);assert.equal(isNoticeRejection(err,A,body),true);
 assert.equal(isNoticeRejection(err,B,body),false);
 for(const patch of [{expectedRecordRevision:'other'},{operationId:'another-original-operation'},{data:{...body.data,title:'Different'}},
  {collection:'students_directory'},{operation:'delete'}])assert.equal(isNoticeRejection(err,A,{...body,...patch}),false);
 for(const patch of [{collection:'students_directory'},{operation:'delete'},{syncProtocol:1}]){
  const other=markNoticeRejection(conflict(),A,{...body,...patch});assert.equal(isNoticeRejection(other,A,{...body,...patch}),false);
 }
 assert(!JSON.stringify(err).includes('Rejected synthetic edit'));
});

'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {bindOperation,createLiveReconciliation,noticeProofMatches}=require('../live-sync-reconciliation');
const {fixture,A,B}=require('./helpers/managed-school-broker');
const hash=x=>crypto.createHash('sha256').update(x).digest('hex');
const request={action:'managed_records',collection:'school_notices',id:'synthetic-notice',operation:'write',
 operationId:'original-notice-operation-001',syncProtocol:2,expectedRecordRevision:'original',
 data:{schoolId:A,_syncFieldPatch:{version:1,set:{title:'synthetic'},remove:[],before:{}}}};
const binding=bindOperation(A,'legacy',request);
function proof(){const revision='cf-original';return {schoolId:A,lane:'notices',job:{
 id:hash(JSON.stringify([A,request.operationId])),kind:'notice',state:'completed',
 payload:JSON.stringify({request,fingerprint:hash(JSON.stringify(request)),ack:{success:true,schoolId:A,syncProtocol:2,recordRevision:revision,
  record:{id:request.id,schoolId:A,_syncOperationId:request.operationId,_syncRevision:revision}}}),
 response:JSON.stringify({state:'completed',driveRevision:'signed-google-revision'})}};}
test('retained notice job proves the original patch even after a newer Drive operation',async()=>{
 const f=fixture(),marker={collection:'school_notices',activeAttempts:0,startedAt:1,operationBinding:binding};
 f.docs.set('school_live_migrations/'+A,{inflight:{original:marker},collections:{students_directory:{state:'legacy'}},preserve:true});
 let lookups=0;
 const r=await createLiveReconciliation({db:f.db,readDrive:async()=>({success:true,schoolId:A,syncProtocol:2,pointRead:true,records:{[request.id]:{schoolId:A,_syncRevision:'newer',_syncOperationId:'newer-operation'}}}),
  readNoticeReceipt:async(s,op)=>{assert.equal(s,A);assert.equal(op,request.operationId);lookups++;return proof();}}).reconcile(A);
 assert.equal(r.cleared,1);assert.equal(lookups,1);assert.deepEqual(f.docs.get('school_live_migrations/'+A).inflight,{});
 assert.equal(f.docs.get('school_live_migrations/'+A).preserve,true);
});
test('foreign, changed, incomplete, missing and purged notice receipts never authorize clearing',()=>{
 for(const change of [p=>({...p,schoolId:B}),p=>({...p,lane:'records'}),
  p=>({...p,job:{...p.job,id:'other'}}),p=>({...p,job:{...p.job,kind:'attendance'}}),
  p=>({...p,job:{...p.job,state:'pending'}}),p=>({...p,job:{...p.job,payload:''}}),
  p=>({...p,job:{...p.job,response:'{}'}}),
  p=>({...p,job:{...p.job,response:JSON.stringify({state:'completed',driveRevision:'cf-pending'})}}),
  p=>{const v=JSON.parse(p.job.payload);v.fingerprint='wrong';p.job.payload=JSON.stringify(v);return p;},
  p=>{const v=JSON.parse(p.job.payload);v.request.data={schoolId:A,title:'different'};v.fingerprint=hash(JSON.stringify(v.request));p.job.payload=JSON.stringify(v);return p;},
  p=>{const v=JSON.parse(p.job.payload);v.ack.record._syncOperationId='other';p.job.payload=JSON.stringify(v);return p;}
 ])assert.equal(noticeProofMatches(change(proof()),binding),false);
 assert.equal(noticeProofMatches(proof(),{...binding,collection:'students_directory'}),false);
 assert.equal(noticeProofMatches(null,binding),false);
});
test('notice evidence cannot clear a marker replaced while its proof was read',async()=>{
 const f=fixture(),marker={collection:'school_notices',activeAttempts:0,startedAt:1,operationBinding:binding};
 f.docs.set('school_live_migrations/'+A,{inflight:{original:marker}});
 const r=await createLiveReconciliation({db:f.db,readNoticeReceipt:async()=>{
  f.docs.get('school_live_migrations/'+A).inflight.original={...marker,startedAt:2};return proof();
 }}).reconcile(A);
 assert.equal(r.cleared,0);assert.equal(r.reasons.marker_changed,1);
});
test('cached idle notice proof never clears an active peer marker for the same operation',async()=>{
 const f=fixture(),marker={collection:'school_notices',activeAttempts:0,startedAt:1,operationBinding:binding};
 f.docs.set('school_live_migrations/'+A,{inflight:{idle:marker,active:{...marker,activeAttempts:1,startedAt:2}}});
 const r=await createLiveReconciliation({db:f.db,readNoticeReceipt:async()=>proof()}).reconcile(A);
 assert.equal(r.cleared,1);assert.equal(r.retained,1);
 assert.ok(f.docs.get('school_live_migrations/'+A).inflight.active);
});

test('a matching original notice receipt can recover despite Google and records-lane read errors',async()=>{
 const f=fixture(),marker={collection:'school_notices',activeAttempts:0,startedAt:1,operationBinding:binding};
 f.docs.set('school_live_migrations/'+A,{inflight:{original:marker}});
 const result=await createLiveReconciliation({db:f.db,
  readDrive:async()=>{throw Error('Google read quota');},
  readEdgeReceipt:async()=>{throw Error('unrelated records-lane source unavailable');},
  readNoticeReceipt:async()=>proof(),
 }).reconcile(A);
 assert.equal(result.cleared,1);
 assert.equal(result.reasons.proof_unavailable,undefined);
 assert.equal(result.proofSources.notice_exact,1);
 assert.deepEqual(f.docs.get('school_live_migrations/'+A).inflight,{});
});
test('a missing or foreign notice proof still retains a marker after upstream read errors',async()=>{
 for(const response of [null,{...proof(),schoolId:B}]){
  const f=fixture(),marker={collection:'school_notices',activeAttempts:0,startedAt:1,operationBinding:binding};
  f.docs.set('school_live_migrations/'+A,{inflight:{original:marker}});
  const result=await createLiveReconciliation({db:f.db,
   readDrive:async()=>{throw Error('Google read quota');},
   readEdgeReceipt:async()=>{throw Error('records source unavailable');},
   readNoticeReceipt:async()=>response,
  }).reconcile(A);
  assert.equal(result.cleared,0);
  assert.equal(result.reasons.proof_unavailable,1);
  assert.ok(f.docs.get('school_live_migrations/'+A).inflight.original);
 }
});

test('sanitized preview distinguishes a missing original notice job from a mismatched completed job',async()=>{
 for(const [receipt,reason] of [
  [{schoolId:A,lane:'notices',job:null},'notice_job_missing'],
  [{...proof(),job:{...proof().job,kind:'other'}},'notice_receipt_mismatch'],
 ]){
  const f=fixture(),marker={collection:'school_notices',activeAttempts:0,startedAt:1,operationBinding:binding};
  f.docs.set('school_live_migrations/'+A,{inflight:{original:marker}});
  f.db.runTransaction=async()=>{throw Error('read-only inspection must not mutate');};
  const result=await createLiveReconciliation({db:f.db,
   readDrive:async()=>({success:true,schoolId:A,syncProtocol:2,pointRead:true,records:{}}),
   readNoticeReceipt:async()=>receipt,
  }).reconcile(A,{previewOnly:true});
  assert.equal(result.previewWouldClear,0);
  assert.equal(result.proofSources[reason],1);
  assert.equal(result.reasons.proof_unverified,1);
  assert.ok(f.docs.get('school_live_migrations/'+A).inflight.original);
  assert.ok(!JSON.stringify(result).includes(binding.operationId));
 }
});

test('read-only proof diagnostics explain missing original fields without clearing or revealing identities',async()=>{
 const mutations=[
  ['job_identity',p=>{p.job.id='not-the-original-job';return p;}],
  ['original_request_binding',p=>{const x=JSON.parse(p.job.payload);x.request.data._syncFieldPatch.set.title='changed-original';x.fingerprint=hash(JSON.stringify(x.request));p.job.payload=JSON.stringify(x);return p;}],
  ['request_fingerprint',p=>{const x=JSON.parse(p.job.payload);x.fingerprint='f'.repeat(64);p.job.payload=JSON.stringify(x);return p;}],
  ['cloudflare_ack',p=>{const x=JSON.parse(p.job.payload);x.ack.schoolId=B;p.job.payload=JSON.stringify(x);return p;}],
  ['ack_original_record',p=>{const x=JSON.parse(p.job.payload);x.ack.record._syncOperationId='wrong-original';p.job.payload=JSON.stringify(x);return p;}],
  ['drive_completion',p=>{const x=JSON.parse(p.job.response);x.driveRevision='cf-not-yet-verified';p.job.response=JSON.stringify(x);return p;}],
  ['unparseable_payload',p=>{p.job.response='{invalid-json';return p;}],
 ];
 for(const [reason,change] of mutations){
  const f=fixture(),marker={collection:'school_notices',activeAttempts:0,startedAt:1,operationBinding:binding};
  f.docs.set('school_live_migrations/'+A,{inflight:{original:marker}});
  f.db.runTransaction=async()=>{throw Error('Read-only mismatch audit must not write');};
  const result=await createLiveReconciliation({db:f.db,readNoticeReceipt:async()=>change(proof())}).reconcile(A,{previewOnly:true});
  assert.equal(result.cleared,0,reason);
  assert.equal(result.previewWouldClear,0,reason);
  assert.equal(result.proofSources.notice_receipt_mismatch,1,reason);
  assert.equal(result.proofSources['notice_mismatch_'+reason],1,reason);
  assert.equal(result.reasons.proof_unverified,1,reason);
  assert.ok(f.docs.get('school_live_migrations/'+A).inflight.original,reason);
  assert.ok(!JSON.stringify(result).includes(request.operationId),reason);
  assert.ok(!JSON.stringify(result).includes(request.id),reason);
 }
});

test('original receipt mismatch breakdown is fixed-string only and never clears an unverified marker',async()=>{
 const cases=[
  ['intent_hash',r=>{r.data._syncFieldPatch.set.title='different-synthetic-intent';}],
  ['record_id',r=>{r.id='another-synthetic-notice';}],
  ['collection',r=>{r.collection='school_calendar';}],
  ['operation_kind',r=>{r.operation='delete';}],
  ['operation_id',r=>{r.operationId='different-synthetic-operation-002';}],
  ['invalid_original_request',r=>{r.operationId='';}],
 ];
 for(const [reason,mutate] of cases){
  const f=fixture(),original={collection:'school_notices',activeAttempts:0,startedAt:1,operationBinding:binding};
  f.docs.set('school_live_migrations/'+A,{inflight:{original}});
  f.db.runTransaction=async()=>{throw Error('read-only proof check must never mutate data');};
  const receipt=proof(),payload=JSON.parse(receipt.job.payload);mutate(payload.request);
  payload.fingerprint=hash(JSON.stringify(payload.request));
  receipt.job.payload=JSON.stringify(payload);
  const result=await createLiveReconciliation({db:f.db,readNoticeReceipt:async()=>receipt}).reconcile(A,{previewOnly:true});
  assert.equal(result.cleared,0,reason);
  assert.equal(result.previewWouldClear,0,reason);
  assert.equal(result.reasons.proof_unverified,1,reason);
  assert.equal(result.proofSources.notice_mismatch_original_request_binding,1,reason);
  assert.equal(result.proofSources['notice_original_binding_'+reason],1,reason);
  assert.ok(f.docs.get('school_live_migrations/'+A).inflight.original,reason);
  const diagnostics=JSON.stringify(result);
  assert.equal(diagnostics.includes(binding.operationId),false,reason);
  assert.equal(diagnostics.includes(binding.requestHash),false,reason);
  assert.equal(diagnostics.includes(binding.id),false,reason);
 }
});

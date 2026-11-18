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

'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {bindOperation,legacyRequestHash,edgeProofMatches,createLiveReconciliation}=require('../live-sync-reconciliation');
const {createHash}=require('node:crypto');
const {fixture,A,B}=require('./helpers/managed-school-broker');
const {storage}=require('./helpers/managed-storage');
const request={action:'managed_records',collection:'school_expenses',id:'expense-one',operation:'write',operationId:'uncertain-operation-00001',syncProtocol:2,expectedRecordRevision:'',data:{schoolId:A,amount:15}};
const liveRequest={collection:request.collection,id:request.id,operation:'write',operationId:request.operationId,expectedRevision:'',data:request.data};
function marker(lane,op=lane==='live'?liveRequest:request){return {collection:request.collection,startedAt:1,operationBinding:bindOperation(A,lane,op)};}
function save(f,map,value){f.docs.set('school_live_migrations/'+A,{collections:{school_calendar:{state:'active'}},[map]:{token:value},unrelated:'preserved'});}
function liveProof(binding){return {liveProtocol:1,schoolId:A,operationId:binding.operationId,found:true,fingerprint:binding.requestHash,receipt:{liveProtocol:1,schoolId:A,operationId:binding.operationId,cloudState:'committed',backupState:'pending',recordRevision:'live-retained-original',cursor:1}};}
test('actual signed GS full/patch/delete readbacks prove only the bound committed legacy operation',async()=>{
 const gs=storage({lifecycle:true,bundle:true}),f=fixture(),reconciler=createLiveReconciliation({db:f.db,readDrive:async(s,b)=>{assert.equal(s,A);return gs.call(b);}});let op=request;
 for(const next of ['write','patch','delete']){
  if(next!=='write'){
   const existing=gs.call({action:'managed_records',operation:'read',collection:op.collection,id:op.id,syncProtocol:2}).records[op.id];
   op=next==='patch'?{...request,operationId:'uncertain-patch-operation-001',expectedRecordRevision:existing._syncRevision,data:{schoolId:A,_syncFieldPatch:{version:1,set:{amount:20},remove:[],before:{}}}}:{...request,operation:'delete',operationId:'uncertain-delete-operation-001',expectedRecordRevision:existing._syncRevision};
   if(next==='delete')delete op.data;
  }
  const ack=gs.call(op);assert.equal(ack.success,true,JSON.stringify(ack));save(f,'inflight',marker('legacy',op));
  assert.equal((await reconciler.reconcile(A)).cleared,1,next);assert.deepEqual(f.docs.get('school_live_migrations/'+A).inflight,{});assert.equal(f.docs.get('school_live_migrations/'+A).unrelated,'preserved');
 }
});
test('immutable live receipt clears uncertain marker without requiring or deleting pending backup',async()=>{
 const f=fixture(),value=marker('live');save(f,'liveInflight',value);
 const result=await createLiveReconciliation({db:f.db,readLiveReceipt:async(s,id)=>{assert.equal(s,A);assert.equal(id,request.operationId);return liveProof(value.operationBinding);}}).reconcile(A);
 assert.equal(result.cleared,1);assert.equal(f.docs.get('school_live_migrations/'+A).collections.school_calendar.state,'active');
});
test('missing, foreign, rebound or incomplete receipts never clear markers regardless of age',async()=>{
 for(const transform of [()=>({found:false}),p=>({...p,schoolId:B}),p=>({...p,fingerprint:'f'.repeat(64)}),p=>({...p,operationId:'other-operation-00001'}),p=>({...p,receipt:{...p.receipt,schoolId:B}}),p=>({...p,receipt:{...p.receipt,cloudState:'pending'}}),p=>({...p,receipt:{...p.receipt,cursor:undefined}}),p=>({...p,receipt:{...p.receipt,backupState:undefined}}),p=>({...p,receipt:{...p.receipt,backupState:'expired'}}),p=>({...p,receipt:{...p.receipt,recordRevision:'cf-unverified'}}),p=>({...p,receipt:{...p.receipt,recordRevision:'live-'}})]){
  const f=fixture(),value=marker('live');save(f,'liveInflight',value);
  const result=await createLiveReconciliation({db:f.db,now:()=>Number.MAX_SAFE_INTEGER,readLiveReceipt:async()=>transform(liveProof(value.operationBinding))}).reconcile(A);
  assert.equal(result.cleared,0);assert.equal(result.retained,1);assert.ok(f.docs.get('school_live_migrations/'+A).liveInflight.token);
 }
 const f=fixture();save(f,'inflight',{collection:request.collection,startedAt:0});assert.equal((await createLiveReconciliation({db:f.db}).reconcile(A)).reasons.unbound,1);
});
test('newer GS operation and matching content without exact operation hash do not prove old commit',async()=>{
 const gs=storage({lifecycle:true,bundle:true}),f=fixture();assert.equal(gs.call(request).success,true);save(f,'inflight',marker('legacy'));
 const current=gs.call({action:'managed_records',operation:'read',collection:request.collection,id:request.id,syncProtocol:2}).records[request.id];
 assert.equal(gs.call({...request,operationId:'newer-operation-after-uncertainty',expectedRecordRevision:current._syncRevision}).success,true);
 assert.equal((await createLiveReconciliation({db:f.db,readDrive:async(_,b)=>gs.call(b)}).reconcile(A)).cleared,0);
 const proof={success:true,schoolId:A,syncProtocol:2,pointRead:true,records:{[request.id]:{...current,_syncRequestHash:'0'.repeat(64)}}};
 assert.equal((await createLiveReconciliation({db:f.db,readDrive:async()=>proof}).reconcile(A)).cleared,0);
});
test('changed marker and provider failure preserve work, bounded batches leave other markers intact',async()=>{
 const f=fixture(),value=marker('live');save(f,'liveInflight',value);
 let result=await createLiveReconciliation({db:f.db,readLiveReceipt:async()=>{f.docs.get('school_live_migrations/'+A).liveInflight.token={...value,startedAt:2};return liveProof(value.operationBinding);}}).reconcile(A);
 assert.equal(result.cleared,0);assert.equal(result.reasons.marker_changed,1);
 assert.equal((await createLiveReconciliation({db:f.db,readLiveReceipt:async()=>{throw Error('provider timeout');}}).reconcile(A)).reasons.proof_unavailable,1);
 f.docs.get('school_live_migrations/'+A).liveInflight.other={...value,startedAt:3};const reconciler=createLiveReconciliation({db:f.db,readLiveReceipt:async()=>liveProof(value.operationBinding)});
 result=await reconciler.reconcile(A,{limit:1});assert.equal(result.cleared,1);assert.equal(result.more,true);assert.ok(f.docs.get('school_live_migrations/'+A).liveInflight.other);
 await assert.rejects(reconciler.reconcile('foreign'),e=>e.status===400);await assert.rejects(reconciler.reconcile(A,{limit:101}),e=>e.status===400);
});
test('bindings store hashes only and ignore precisely the GS receipt metadata fields',()=>{
 assert.equal(bindOperation(A,'legacy',{...request,syncProtocol:1}),null);assert.equal(bindOperation(A,'live',{...liveRequest,operationId:'short'}),null);assert.equal(bindOperation(A,'legacy',{...request,action:'managed_recycle'}),null);
 for(const id of ['__proto__','prototype','constructor','.','..'])assert.equal(bindOperation(A,'legacy',{...request,id}),null,'forbidden record identifier must not become a reconciliation proof');
 assert.ok(!JSON.stringify(marker('legacy')).includes('amount'));assert.equal(legacyRequestHash({...request,data:{...request.data,_syncRevision:'ignored'}}),legacyRequestHash(request));
});

test('repeated lost responses for the same operation share one proof lookup',async()=>{
 const f=fixture(),value=marker('live');save(f,'liveInflight',value);f.docs.get('school_live_migrations/'+A).liveInflight.other={...value,startedAt:2};let reads=0;
 const result=await createLiveReconciliation({db:f.db,readLiveReceipt:async()=>{reads++;return liveProof(value.operationBinding);}}).reconcile(A);
 assert.equal(reads,1);assert.equal(result.cleared,2);
});

function exactEdgeProof(binding){
 const id=createHash('sha256').update(JSON.stringify([binding.schoolId,
   'managed_records',[binding.collection,binding.id,binding.operationId]])).digest('hex');
 return {id,state:'completed',response:{result:{
   success:true,schoolId:binding.schoolId,syncProtocol:2,
   recordRevision:'verified-original-revision',record:{
    id:binding.id,schoolId:binding.schoolId,
    _syncOperationId:binding.operationId,
    _syncRequestHash:binding.requestHash,
    _syncRevision:'verified-original-revision',_syncDeleted: false,
   },
 }}};
}
test('a completed *exact original* Cloudflare receipt safely reconciles a superseded Sheet row',async()=>{
 const f=fixture(),value={...marker('legacy'),activeAttempts:0};save(f,'inflight',value);
 const binding=value.operationBinding;
 let reads=0;
 const result=await createLiveReconciliation({db:f.db,
   readDrive:async()=>({success:true,schoolId:A,syncProtocol:2,pointRead:true,
     records:{[binding.id]:{schoolId:A,_syncOperationId:'newer-operation-revision',
       _syncRevision:'newer-sheet-revision',_syncRequestHash:'f'.repeat(64)}}}),
   readEdgeReceipt:async(s,b)=>{reads++;assert.equal(s,A);assert.deepEqual(b,binding);return exactEdgeProof(binding);},
 }).reconcile(A);
 assert.equal(reads,1);
 assert.equal(result.cleared,1);
 assert.deepEqual(f.docs.get('school_live_migrations/'+A).inflight,{});
});
test('staged edge job, active legacy attempts, wrong original proof, or GC-purged records NEVER clear',async()=>{
 const value={...marker('legacy'),activeAttempts:0},binding=value.operationBinding,good=exactEdgeProof(binding);
 const corrupt=[
  p=>({...p,state:'pending'}),
  p=>({...p,state:'needsAttention'}),
  p=>({...p,id:'f'.repeat(64)}),
  p=>({...p,response:{result:{...p.response.result,schoolId:B}}}),
  p=>({...p,response:{result:{...p.response.result,recordRevision:'cf-fake'}}}),
  p=>({...p,response:{result:{...p.response.result,record:null,recordSource:{version:1}}}}),
  p=>({...p,response:{result:{...p.response.result,record:{...p.response.result.record,schoolId:B}}}}),
  p=>({...p,response:{result:{...p.response.result,record:{...p.response.result.record,_syncOperationId:'another-operation-0001'}}}}),
  p=>({...p,response:{result:{...p.response.result,record:{...p.response.result.record,_syncRequestHash:'0'.repeat(64)}}}}),
  p=>({...p,response:{result:{...p.response.result,record:{...p.response.result.record,_syncRevision:'unrelated'}}}}),
  p=>({...p,response:{result:{...p.response.result,record:{...p.response.result.record,_syncDeleted:true}}}}),
 ];
 for(const damage of corrupt){
  const f=fixture();save(f,'inflight',{...value});
  const proof=damage(good);
  assert.equal(edgeProofMatches(proof,binding),false);
  const result=await createLiveReconciliation({db:f.db,readEdgeReceipt:async()=>proof}).reconcile(A);
  assert.equal(result.cleared,0);
  assert.ok(f.docs.get('school_live_migrations/'+A).inflight.token);
 }
 const f=fixture();save(f,'inflight',{...value,activeAttempts:1});
 const result=await createLiveReconciliation({db:f.db,readEdgeReceipt:async()=>good}).reconcile(A);
 assert.equal(result.cleared,0);
 assert.ok(f.docs.get('school_live_migrations/'+A).inflight.token);
});
test('a Google point-read timeout can fall back to original completed edge proof, never to a pending ticket',async()=>{
 const f=fixture(),value={...marker('legacy'),activeAttempts:0};save(f,'inflight',value);
 const result=await createLiveReconciliation({db:f.db,
  readDrive:async()=>{throw Error('Google quota timeout');},
  readEdgeReceipt:async()=>exactEdgeProof(value.operationBinding),
 }).reconcile(A);
 assert.equal(result.cleared,1);
 const g=fixture();save(g,'inflight',value);
 const failed=await createLiveReconciliation({db:g.db,
  readDrive:async()=>{throw Error('Google quota timeout');},
  readEdgeReceipt:async()=>({...exactEdgeProof(value.operationBinding),state:'retry'}),
 }).reconcile(A);
 assert.equal(failed.cleared,0);
 assert.equal(failed.reasons.proof_unavailable,1);
});

test('source diagnostics count unavailable original proofs without exposing operation identities',async()=>{
 const f=fixture(),value={...marker('legacy'),activeAttempts:0},binding=value.operationBinding;
 save(f,'inflight',value);
 const result=await createLiveReconciliation({db:f.db,
  readDrive:async()=>{throw Error('Google source read unavailable');},
  readEdgeReceipt:async()=>{throw Error('Original edge receipt missing');}
 }).reconcile(A);
 assert.equal(result.cleared,0);
 assert.equal(result.reasons.proof_unavailable,1);
 assert.deepEqual(result.proofSources,{
  legacy_marker:1,drive_read_error:1,edge_read_error:1,source_error_retained:1
 });
 assert.ok(!JSON.stringify(result).includes(binding.operationId));
 assert.ok(!JSON.stringify(result).includes(binding.id));
 assert.ok(!JSON.stringify(result).includes(binding.requestHash));
 assert.ok(f.docs.get('school_live_migrations/'+A).inflight.token);
});

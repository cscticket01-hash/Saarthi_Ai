'use strict';
const {randomUUID}=require('node:crypto');
const {COLLECTIONS}=require('./live-sync');
const {bindOperation}=require('./live-sync-reconciliation');
const {canonical}=require('./live-sync-canonical');
const refuse=code=>{throw Object.assign(Error('Sync migration is pending; saved changes are retained.'),{status:503,code,publicMessage:true});};
// Durable admission markers intentionally do not expire. A process crash can
// leave an uncertain Google request running; a timeout is not proof of failure.
function createLiveMigration({db,now=Date.now,drainGraceMs=120000}){
 const ref=school=>db.doc('school_live_migrations/'+school);
 async function legacy(school,body,run){
  // Mobile operations have their own person/session/attendance/complaint
  // owners and cannot mutate any admitted live collection. Public invalid
  // sessions must not consume permanent admin migration admission markers.
  if(body.action==='managed_mobile')return run();
  const read=body.action==='managed_records'&&body.operation==='read'||['managed_health','managed_summary','managed_delta'].includes(body.action);
  if(read)return run();
  let token=randomUUID();const r=ref(school),collection=body.action==='managed_records'?body.collection:null;
  await db.runTransaction(async tx=>{
   const state=(await tx.get(r)).data()||{},collections=state.collections||{};
   if(Object.entries(collections).some(([name,value])=>value.state!=='legacy'&&(!collection||collection===name)))refuse('LIVE_LEGACY_WRITE_FENCED');
   const operationBinding=bindOperation(school,'legacy',body);
   const inflight={...state.inflight};
   if(operationBinding){const prior=Object.entries(inflight).find(([,marker])=>marker.operationBinding&&canonical(marker.operationBinding)===canonical(operationBinding));if(prior){token=prior[0];return;}}
   if(Object.keys(inflight).length>=100)refuse('LIVE_MIGRATION_ADMISSION_BUSY');
   inflight[token]={collection:collection||'*',startedAt:now(),...(operationBinding?{operationBinding}:{})};tx.set(r,{...state,inflight});
  });
  const result=await run();
  {
   await db.runTransaction(async tx=>{const state=(await tx.get(r)).data()||{},inflight={...state.inflight};delete inflight[token];tx.set(r,{...state,inflight});});
  }
  return result;
 }
 async function prepare(school,collection,drained,seed){
  if(!COLLECTIONS.has(collection))refuse('LIVE_COLLECTION_NOT_ADMITTED');
  const r=ref(school);
  const active=await db.runTransaction(async tx=>{
   const state=(await tx.get(r)).data()||{},collections={...state.collections};
   if(collections[collection]?.state==='active')return true;
   if(collections[collection]&&!['preparing'].includes(collections[collection].state))refuse('LIVE_MIGRATION_REVIEW_REQUIRED');
   collections[collection]={state:'preparing',startedAt:collections[collection]?.startedAt??now()};
   tx.set(r,{...state,collections});return false;
  });
  if(active)return {liveProtocol:1,schoolId:school,state:'active'};
  const state=(await r.get()).data();
  if(now()-state.collections[collection].startedAt<drainGraceMs)refuse('LIVE_LEGACY_DRAIN_GRACE');
  if(Object.values(state.inflight||{}).some(item=>item.collection==='*'||item.collection===collection))refuse('LIVE_LEGACY_WRITES_IN_FLIGHT');
  // Legacy edge jobs bypass user admission so they can drain while fenced.
  // Read both queues only after admission is closed and old writers settled.
  if(!await drained())refuse('LIVE_LEGACY_DELIVERY_PENDING');
  const result=await seed();
  if(result.state!=='active')refuse('LIVE_BASELINE_UNVERIFIED');
  await db.runTransaction(async tx=>{
   const current=(await tx.get(r)).data()||{};
   if(current.collections?.[collection]?.state!=='preparing')refuse('LIVE_MIGRATION_STATE_CHANGED');
   tx.set(r,{...current,collections:{...current.collections,[collection]:{state:'active',activatedAt:now()}}});
  });
  return result;
 }
 async function assertActive(school,collection){
  if((await ref(school).get()).data()?.collections?.[collection]?.state!=='active')refuse('LIVE_MIGRATION_NOT_ACTIVE');
 }
 async function live(school,collection,run,request){
  if(!COLLECTIONS.has(collection))refuse('LIVE_COLLECTION_NOT_ADMITTED');
  const r=ref(school);let token=randomUUID();
  await db.runTransaction(async tx=>{
   const state=(await tx.get(r)).data()||{};
   if(state.collections?.[collection]?.state!=='active')refuse('LIVE_MIGRATION_NOT_ACTIVE');
   const liveInflight={...state.liveInflight};
   const operationBinding=request?bindOperation(school,'live',request):null;
   if(operationBinding){const prior=Object.entries(liveInflight).find(([,marker])=>marker.operationBinding&&canonical(marker.operationBinding)===canonical(operationBinding));if(prior){token=prior[0];return;}}
   if(Object.keys(liveInflight).length>=100)refuse('LIVE_MIGRATION_ADMISSION_BUSY');
   liveInflight[token]={collection,startedAt:now(),...(operationBinding?{operationBinding}:{})};tx.set(r,{...state,liveInflight});
  });
  // An uncertain outcome retains its marker. Clearing it on a timeout could
  // allow rollback while a committed Cloudflare write is still being handled.
  const result=await run();
  await db.runTransaction(async tx=>{
   const state=(await tx.get(r)).data()||{},liveInflight={...state.liveInflight};
   delete liveInflight[token];tx.set(r,{...state,liveInflight});
  });
  return result;
 }
 async function rollback(school,collection,verifyAndSeal){
  if(!COLLECTIONS.has(collection))refuse('LIVE_COLLECTION_NOT_ADMITTED');
  const r=ref(school);
  const migration=await db.runTransaction(async tx=>{
   const state=(await tx.get(r)).data()||{},current=state.collections?.[collection];
   if(current?.state==='legacy'&&current.rollbackProof)return current;
   if(!current||!['active','rolling_back'].includes(current.state))refuse('LIVE_MIGRATION_NOT_ACTIVE');
   const next=current.state==='rolling_back'?current:{...current,state:'rolling_back',rollbackToken:randomUUID(),rollbackStartedAt:now()};
   tx.set(r,{...state,collections:{...state.collections,[collection]:next}});return next;
  });
  if(migration.state==='legacy')return {liveProtocol:1,schoolId:school,collection,state:'legacy',...migration.rollbackProof};
  const state=(await r.get()).data()||{};
  if(Object.values(state.liveInflight||{}).some(item=>item.collection===collection))refuse('LIVE_WRITES_IN_FLIGHT');
  if(Object.values(state.inflight||{}).some(item=>item.collection==='*'||item.collection===collection))refuse('LIVE_LEGACY_WRITES_IN_FLIGHT');
  // Only a trusted server-side verifier may supply this proof. It must compare
  // every current record/deletion against school Drive and seal the Worker
  // collection against writes BEFORE it returns. HTTP success alone is not
  // proof. No payloads, cursors, jobs or uncertain markers are deleted here.
  if(typeof verifyAndSeal!=='function')refuse('LIVE_ROLLBACK_VERIFIER_REQUIRED');
  const proof=await verifyAndSeal({schoolId:school,collection,rollbackToken:migration.rollbackToken});
  if(!proof||proof.success!==true||proof.liveProtocol!==1||proof.schoolId!==school||proof.collection!==collection||proof.state!=='legacy'||proof.driveVerified!==true||proof.pending!==0||proof.needsAttention!==0||!Number.isSafeInteger(proof.cursor)||proof.cursor<0||proof.rollbackToken!==migration.rollbackToken||typeof proof.fingerprint!=='string'||!/^[a-f0-9]{64}$/.test(proof.fingerprint))refuse('LIVE_ROLLBACK_UNVERIFIED');
  const rollbackProof={cursor:proof.cursor,fingerprint:proof.fingerprint,driveVerified:true};
  await db.runTransaction(async tx=>{
   const state=(await tx.get(r)).data()||{},current=state.collections?.[collection];
   if(current?.state!=='rolling_back'||current.rollbackToken!==migration.rollbackToken)refuse('LIVE_MIGRATION_STATE_CHANGED');
   if(Object.values(state.liveInflight||{}).some(item=>item.collection===collection))refuse('LIVE_WRITES_IN_FLIGHT');
   tx.set(r,{...state,collections:{...state.collections,[collection]:{state:'legacy',rolledBackAt:now(),rollbackProof}}});
  });
  return {liveProtocol:1,schoolId:school,collection,state:'legacy',...rollbackProof};
 }
 async function state(school,collection){return (await ref(school).get()).data()?.collections?.[collection]?.state||'legacy';}
 async function rolledBack(school,collection){const value=(await ref(school).get()).data()?.collections?.[collection];return value?.state==='legacy'&&!!value.rollbackProof;}
 return {legacy,prepare,assertActive,live,rollback,state,rolledBack};
}
module.exports={createLiveMigration};

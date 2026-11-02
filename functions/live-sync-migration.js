'use strict';
const {randomUUID}=require('node:crypto');
const {COLLECTIONS}=require('./live-sync');
const refuse=code=>{throw Object.assign(Error('Sync migration is pending; saved changes are retained.'),{status:503,code,publicMessage:true});};
// Durable admission markers intentionally do not expire. A process crash can
// leave an uncertain Google request running; a timeout is not proof of failure.
function createLiveMigration({db,now=Date.now,drainGraceMs=120000}){
 const ref=school=>db.doc('school_live_migrations/'+school);
 async function legacy(school,body,run){
  const read=body.action==='managed_records'&&body.operation==='read'||['managed_health','managed_summary','managed_delta'].includes(body.action);
  if(read)return run();
  const token=randomUUID(),r=ref(school),collection=body.action==='managed_records'?body.collection:null;
  await db.runTransaction(async tx=>{
   const state=(await tx.get(r)).data()||{},collections=state.collections||{};
   if(Object.entries(collections).some(([name,value])=>value.state!=='legacy'&&(!collection||collection===name)))refuse('LIVE_LEGACY_WRITE_FENCED');
   const inflight={...state.inflight};if(Object.keys(inflight).length>=100)refuse('LIVE_MIGRATION_ADMISSION_BUSY');
   inflight[token]={collection:collection||'*',startedAt:now()};tx.set(r,{...state,inflight});
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
   collections[collection]={state:'preparing',startedAt:collections[collection]?.startedAt||now()};
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
 return {legacy,prepare,assertActive};
}
module.exports={createLiveMigration};

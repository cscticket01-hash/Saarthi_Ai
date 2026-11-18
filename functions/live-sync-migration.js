'use strict';
const {randomUUID}=require('node:crypto');
const {COLLECTIONS}=require('./live-sync');
const {bindOperation}=require('./live-sync-reconciliation');
const {canonical}=require('./live-sync-canonical');
const {legacyFingerprint,isNoticeRejection}=require('./live-sync-rejection');
const NATIVE_LIFECYCLE_COLLECTIONS=new Set(['students_directory','teachers_directory','documents','student_scan_index','fee_settings','fee_ledger','fee_payments','teacher_salary','attendance_records','attendance_logs','teacher_attendance','teacher_schedules','exams','exam_results','exam_center_results']);
const refuse=code=>{throw Object.assign(Error('Sync migration is pending; saved changes are retained.'),{status:503,code,publicMessage:true});};
// Durable admission markers intentionally do not expire. A process crash can
// leave an uncertain Google request running; a timeout is not proof of failure.
function createLiveMigration({db,now=Date.now,drainGraceMs=120000}){
 const ref=school=>db.doc('school_live_migrations/'+school);
 // A retry may share one immutable operation marker with another request.
 // Keep the marker until ALL admitted attempts finish; a timed-out attempt
 // must not let migration/rollback start while its peer is still executing.
 async function settleAttempt(r,map,token,completed){
  await db.runTransaction(async tx=>{
   const state=(await tx.get(r)).data()||{},markers={...state[map]},marker=markers[token];
   if(!marker)return;
   const active=Number.isSafeInteger(marker.activeAttempts)?marker.activeAttempts:1;
   const left=Math.max(0,active-1);
   if(left===0&&(completed||marker.completedAttempt===true))delete markers[token];
   else markers[token]={...marker,activeAttempts:left,...(completed?{completedAttempt:true}:{})};
   tx.set(r,{...state,[map]:markers});
  });
 }
 async function legacy(school,body,run){
  // Mobile operations have their own person/session/attendance/complaint
  // owners and cannot mutate any admitted live collection. Public invalid
  // sessions must not consume permanent admin migration admission markers.
  if(body.action==='managed_mobile')return run();
  // managed_file only reads an owned Drive blob. A failed download must not
  // leave an unbound write marker that permanently fences later migration.
  const read=body.action==='managed_records'&&body.operation==='read'||['managed_health','managed_summary','managed_delta','managed_file','managed_binary_inventory','managed_binary_download'].includes(body.action);
  if(read)return run();
  let token=randomUUID();const r=ref(school),collection=body.action==='managed_records'?body.collection:null;
  await db.runTransaction(async tx=>{
   const state=(await tx.get(r)).data()||{},collections=state.collections||{};
   if(Object.entries(collections).some(([name,value])=>value.state!=='legacy'&&(!collection||collection===name)))refuse('LIVE_LEGACY_WRITE_FENCED');
   const operationBinding=bindOperation(school,'legacy',body),requestFingerprint=legacyFingerprint(school,body);
   const inflight={...state.inflight};
   if(operationBinding){const prior=Object.entries(inflight).find(([,marker])=>marker.operationBinding&&marker.requestFingerprint===requestFingerprint&&canonical(marker.operationBinding)===canonical(operationBinding));if(prior){token=prior[0];inflight[token]={...prior[1],activeAttempts:(Number.isSafeInteger(prior[1].activeAttempts)?prior[1].activeAttempts:0)+1};tx.set(r,{...state,inflight});return;}}
   if(Object.keys(inflight).length>=100)refuse('LIVE_MIGRATION_ADMISSION_BUSY');
   inflight[token]={collection:collection||'*',startedAt:now(),activeAttempts:1,...(operationBinding?{operationBinding,requestFingerprint}:{})};tx.set(r,{...state,inflight});
  });
  let completed=false;
  try{const result=await run();completed=true;return result;}
  catch(error){completed=isNoticeRejection(error,school,body);throw error;}
  finally{await settleAttempt(r,'inflight',token,completed);}
 }
 async function prepare(school,collection,drained,seed){
  if(NATIVE_LIFECYCLE_COLLECTIONS.has(collection))refuse('LIVE_DEPENDENCY_GROUP_REQUIRED');
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
   if(state.nativeCohort?.state==='preparing'&&state.nativeCohort.collections.includes(collection))refuse('LIVE_DEPENDENCY_PREPARING');
   if(state.collections?.[collection]?.state!=='active')refuse('LIVE_MIGRATION_NOT_ACTIVE');
   const liveInflight={...state.liveInflight};
   const operationBinding=request?bindOperation(school,'live',request):null;
   if(operationBinding){const prior=Object.entries(liveInflight).find(([,marker])=>marker.operationBinding&&canonical(marker.operationBinding)===canonical(operationBinding));if(prior){token=prior[0];liveInflight[token]={...prior[1],activeAttempts:(Number.isSafeInteger(prior[1].activeAttempts)?prior[1].activeAttempts:0)+1};tx.set(r,{...state,liveInflight});return;}}
   if(Object.keys(liveInflight).length>=100)refuse('LIVE_MIGRATION_ADMISSION_BUSY');
   liveInflight[token]={collection,startedAt:now(),activeAttempts:1,...(operationBinding?{operationBinding}:{})};tx.set(r,{...state,liveInflight});
  });
  // An uncertain outcome retains its marker. Clearing it on a timeout could
  // allow rollback while a committed Cloudflare write is still being handled.
  let completed=false;
  try{const result=await run();completed=true;return result;}
  finally{await settleAttempt(r,'liveInflight',token,completed);}
 }
 function checkedRollbackProof(proof,school,collection,rollbackToken){
  if(!proof||proof.success!==true||proof.liveProtocol!==1||proof.schoolId!==school||proof.collection!==collection||proof.state!=='legacy'||proof.driveVerified!==true||proof.pending!==0||proof.needsAttention!==0||!Number.isSafeInteger(proof.cursor)||proof.cursor<0||proof.rollbackToken!==rollbackToken||typeof proof.fingerprint!=='string'||!/^[a-f0-9]{64}$/.test(proof.fingerprint))refuse('LIVE_ROLLBACK_UNVERIFIED');
  return {cursor:proof.cursor,fingerprint:proof.fingerprint,driveVerified:true};
 }
 async function rollback(school,collection,verifyAndSeal){
  if(!COLLECTIONS.has(collection))refuse('LIVE_COLLECTION_NOT_ADMITTED');
  const r=ref(school);
  const migration=await db.runTransaction(async tx=>{
   const state=(await tx.get(r)).data()||{},current=state.collections?.[collection];
   if(state.nativeCohort?.collections?.includes(collection))refuse('LIVE_DEPENDENCY_ROLLBACK_REQUIRES_COHORT');
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
  const rollbackProof=checkedRollbackProof(proof,school,collection,migration.rollbackToken);
  await db.runTransaction(async tx=>{
   const state=(await tx.get(r)).data()||{},current=state.collections?.[collection];
   if(current?.state!=='rolling_back'||current.rollbackToken!==migration.rollbackToken)refuse('LIVE_MIGRATION_STATE_CHANGED');
   if(Object.values(state.liveInflight||{}).some(item=>item.collection===collection))refuse('LIVE_WRITES_IN_FLIGHT');
   tx.set(r,{...state,collections:{...state.collections,[collection]:{state:'legacy',rolledBackAt:now(),rollbackProof}}});
  });
  return {liveProtocol:1,schoolId:school,collection,state:'legacy',...rollbackProof};
 }
 async function prepareGroup(school,collections,drained,seed){
  if(!Array.isArray(collections)||collections.length<1||collections.length>22||new Set(collections).size!==collections.length||collections.some(collection=>!COLLECTIONS.has(collection)))refuse('LIVE_DEPENDENCY_GROUP_INVALID');
  const ordered=[...collections].sort(),r=ref(school);
  const active=await db.runTransaction(async tx=>{
   const current=(await tx.get(r)).data()||{},group=current.nativeCohort;
   if(group&&canonical(group.collections)!==canonical(ordered))refuse('LIVE_DEPENDENCY_GROUP_CHANGED');
   if(group?.state==='active')return true;
   if(group&&group.state!=='preparing')refuse('LIVE_MIGRATION_REVIEW_REQUIRED');
   const states={...current.collections};
   for(const collection of ordered){
    const prior=states[collection];if(prior&&!['legacy','preparing','active'].includes(prior.state)||prior?.rollbackProof)refuse('LIVE_MIGRATION_REVIEW_REQUIRED');
    if(prior?.state!=='active')states[collection]={state:'preparing',startedAt:prior?.startedAt??now()};
   }
   tx.set(r,{...current,collections:states,nativeCohort:{state:'preparing',collections:ordered,startedAt:group?.startedAt??now()}});return false;
  });
  if(active)return {liveProtocol:1,schoolId:school,state:'active',collections:ordered};
  const current=(await r.get()).data();
  if(now()-current.nativeCohort.startedAt<drainGraceMs)refuse('LIVE_LEGACY_DRAIN_GRACE');
  const relevant=item=>item.collection==='*'||ordered.includes(item.collection);
  if(Object.values(current.inflight||{}).some(relevant))refuse('LIVE_LEGACY_WRITES_IN_FLIGHT');
  if(Object.values(current.liveInflight||{}).some(relevant))refuse('LIVE_WRITES_IN_FLIGHT');
  if(!await drained())refuse('LIVE_LEGACY_DELIVERY_PENDING');
  for(const collection of ordered){const result=await seed(collection);if(result.state!=='active')refuse('LIVE_BASELINE_UNVERIFIED');}
  await db.runTransaction(async tx=>{
   const latest=(await tx.get(r)).data()||{},group=latest.nativeCohort;
   if(group?.state==='active'&&canonical(group.collections)===canonical(ordered))return;
   if(group?.state!=='preparing'||canonical(group.collections)!==canonical(ordered))refuse('LIVE_MIGRATION_STATE_CHANGED');
   if(Object.values(latest.inflight||{}).some(relevant)||Object.values(latest.liveInflight||{}).some(relevant))refuse('LIVE_WRITES_IN_FLIGHT');
   const states={...latest.collections};for(const collection of ordered)states[collection]={state:'active',activatedAt:now()};
   tx.set(r,{...latest,collections:states,nativeCohort:{...group,state:'active',activatedAt:now()}});
  });
  return {liveProtocol:1,schoolId:school,state:'active',collections:ordered};
 }
 async function rollbackGroup(school,collections,verifyAndSeal){
  const ordered=[...collections].sort(),r=ref(school);
  const migration=await db.runTransaction(async tx=>{
   const state=(await tx.get(r)).data()||{},group=state.nativeCohort;
   if(!group||canonical(group.collections)!==canonical(ordered))refuse('LIVE_DEPENDENCY_GROUP_CHANGED');
   if(group.state==='legacy')return group;
   if(!['active','rolling_back'].includes(group.state))refuse('LIVE_MIGRATION_NOT_ACTIVE');
   if(group.state==='rolling_back')return group;
   if(ordered.some(name=>state.collections?.[name]?.state!=='active'))refuse('LIVE_MIGRATION_NOT_ACTIVE');
   const next={...group,state:'rolling_back',rollbackToken:randomUUID()};
   const states={...state.collections};
   for(const name of ordered)states[name]={...states[name],state:'rolling_back'};
   tx.set(r,{...state,collections:states,nativeCohort:next});
   return next;
  });
  const response={liveProtocol:1,schoolId:school,state:'legacy',collections:ordered};
  if(migration.state==='legacy')return response;
  const relevant=item=>item.collection==='*'||ordered.includes(item.collection);
  const requireIdle=state=>{
   if(Object.values(state.inflight||{}).some(relevant))refuse('LIVE_LEGACY_WRITES_IN_FLIGHT');
   if(Object.values(state.liveInflight||{}).some(relevant))refuse('LIVE_WRITES_IN_FLIGHT');
  };
  requireIdle((await r.get()).data()||{});
  const proofs={};
  // Worker seals are idempotent and each retry rechecks current Drive bytes.
  // Keep all broker writes fenced until every collection has a signed proof.
  for(const name of ordered){
   const proof=await verifyAndSeal({schoolId:school,collection:name,rollbackToken:migration.rollbackToken});
   proofs[name]=checkedRollbackProof(proof,school,name,migration.rollbackToken);
  }
  await db.runTransaction(async tx=>{
   const state=(await tx.get(r)).data()||{},group=state.nativeCohort;
   if(group?.state==='legacy'&&group.rollbackToken===migration.rollbackToken)return;
   if(group?.state!=='rolling_back'||group.rollbackToken!==migration.rollbackToken||
      ordered.some(name=>state.collections?.[name]?.state!=='rolling_back'))
    refuse('LIVE_MIGRATION_STATE_CHANGED');
   requireIdle(state);
   const states={...state.collections};
   for(const name of ordered)states[name]={state:'legacy',rolledBackAt:now(),rollbackProof:proofs[name]};
   tx.set(r,{...state,collections:states,nativeCohort:{...group,state:'legacy',rolledBackAt:now()}});
  });
  return response;
 }
 async function assertCohortAdmission(school,collection){
  const value=(await ref(school).get()).data()?.nativeCohort;
  if(!value||collection&&!value.collections.includes(collection))return;
  if(value.state==='preparing')refuse('LIVE_DEPENDENCY_PREPARING');
  if(value.state==='rolling_back')refuse('LIVE_ROLLBACK_PENDING');
 }
 async function state(school,collection){return (await ref(school).get()).data()?.collections?.[collection]?.state||'legacy';}
 async function rolledBack(school,collection){const value=(await ref(school).get()).data()?.collections?.[collection];return value?.state==='legacy'&&!!value.rollbackProof;}
 return {legacy,prepare,prepareGroup,assertCohortAdmission,assertActive,live,rollback,rollbackGroup,state,rolledBack};
}
module.exports={createLiveMigration,NATIVE_LIFECYCLE_COLLECTIONS};

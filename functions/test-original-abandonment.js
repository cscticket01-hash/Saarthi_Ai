'use strict';
// Explicit owner-authorized disposable TEST cleanup, never delivery reconciliation.
const {createHash}=require('node:crypto');
const {canonical}=require('./live-sync-canonical');
const SCHOOL='vs-db8afb01a3be46a983c8284714d06e5d';
const EPOCH='owner-disposable-test-20261115';
const fail=code=>{throw Object.assign(Error('Disposable TEST cleanup scope changed; nothing removed.'),{status:409,code,publicMessage:true});};
function createTestOriginalAbandonment({db,testSchoolId,enabled=false,queuesDrained,now=Date.now}){
 if(!enabled)return null;
 if(testSchoolId!==SCHOOL)throw Error('Disposable original cleanup requires fixed isolated TEST school');
 const ref=db.doc('school_live_migrations/'+SCHOOL),archive=db.doc('school_test_abandonment/'+SCHOOL+'/epochs/'+EPOCH);
 const digest=s=>createHash('sha256').update(canonical({inflight:s.inflight||{},liveInflight:s.liveInflight||{}})).digest('hex');
 function validate(s){
  const rows=[...Object.values(s.inflight||{}),...Object.values(s.liveInflight||{})];
  if(rows.length!==14||Object.keys(s.liveInflight||{}).length)fail('TEST_ORIGINAL_COHORT_CHANGED');
  for(const r of rows)if(r.activeAttempts!==0||r.collection!=='school_notices'||r.operationBinding?.schoolId!==SCHOOL||r.operationBinding?.lane!=='legacy'||r.operationBinding?.collection!=='school_notices')fail('TEST_ORIGINAL_SCOPE_CHANGED');
  return rows.length;
 }
 return async(m,b)=>{
  if(m.schoolId!==SCHOOL)fail('TEST_ORIGINAL_SCHOOL_REQUIRED');
  if(!['preview','abandon'].includes(b.operation))fail('TEST_ORIGINAL_ACTION_REQUIRED');
  if(b.confirmDisposableTest!==EPOCH)fail('TEST_ORIGINAL_CONFIRMATION_REQUIRED');
  if(await queuesDrained()!==true)fail('TEST_ORIGINAL_DELIVERY_NOT_DRAINED');
  return db.runTransaction(async tx=>{
   const school=(await tx.get(db.doc('schools/'+SCHOOL))).data();
   if(!school||!/^TEST\b/i.test(school.schoolName||''))fail('TEST_ORIGINAL_IDENTITY_REQUIRED');
   const prior=await tx.get(archive),s=(await tx.get(ref)).data()||{};
   if(prior.exists)return {success:true,schoolId:SCHOOL,status:'TEST_HISTORY_ABANDONED_NOT_BACKUP_PROOF',alreadyApplied:true,abandoned:prior.data().count,unsettledWrites:Object.keys(s.inflight||{}).length+Object.keys(s.liveInflight||{}).length,backupVerified:false};
   const count=validate(s),cohortHash=digest(s);
   if(b.operation==='preview')return {success:true,schoolId:SCHOOL,status:'PREVIEW_ONLY',previewOnly:true,count,cohortHash,backupVerified:false};
   if(b.expectedCohortHash!==cohortHash)fail('TEST_ORIGINAL_CAS_MISMATCH');
   // Both writes commit together. Keep full original markers in a private,
   // school-bound archive; never touch business rows, Drive, R2 or receipts.
   tx.set(archive,{schoolId:SCHOOL,epoch:EPOCH,count,cohortHash,markers:{inflight:s.inflight||{},liveInflight:s.liveInflight||{}},abandonedAt:now(),actorUid:m.uid,reason:'USER_AUTHORIZED_DISPOSABLE_TEST_ABANDONMENT',backupVerified:false});
   tx.set(ref,{...s,inflight:{},liveInflight:{},testAbandonment:{epoch:EPOCH,count,cohortHash,backupVerified:false}});
   return {success:true,schoolId:SCHOOL,status:'TEST_HISTORY_ABANDONED_NOT_BACKUP_PROOF',abandoned:count,unsettledWrites:0,backupVerified:false};
  });
 };
}
module.exports={createTestOriginalAbandonment,SCHOOL,EPOCH};

'use strict';
const SCHOOL=/^vs-[a-f0-9]{32}$/;
const COLLECTIONS=new Set(['students_directory','teachers_directory','attendance_logs','teacher_attendance','attendance_records','teacher_schedules','school_calendar','school_notices','exam_results','teacher_salary','school_config','school_settings','fee_settings','fee_ledger','fee_payments','school_expenses','student_scan_index','scanner_devices','documents','backups','exams','exam_center_results','mobile_sessions','mobile_users','mobile_complaints']);
const validId=id=>typeof id==='string'&&id.length>0&&id.length<=200&&!id.includes('/')&&!['.','..','__proto__','prototype','constructor'].includes(id);
const fail=code=>{throw Object.assign(Error('Verified cloud deletion is pending; original operation retained.'),{status:409,code,publicMessage:true});};
/** Central operational data only. Auth, licensing, security, school registration
 * and device registries are deliberately outside this namespace and allowlist.
 * The caller must retain its original delivery job until this promise resolves.
 */
function createDeleteEverywhere({db}) {
 async function finish(school,request,result) {
  if(request.deleteEverywhereVersion!==1)return result;
  const canonical=result?.record;
  if(!SCHOOL.test(school)||request.operation!=='delete'||request.syncProtocol!==2||
     !COLLECTIONS.has(request.collection)||!validId(request.id)||
     typeof request.operationId!=='string'||!request.operationId||
     result?.success!==true||result.schoolId!==school||result.syncProtocol!==2||
     result.deleteEverywhereVersion!==1||result.driveDeletionComplete!==true||
     typeof result.recordRevision!=='string'||!result.recordRevision||/^(?:cf-|live-)/.test(result.recordRevision)||
     // A successful HTTP response or a Drive flag alone must not clear Firebase.
     // The Script must return the same completed, immutable original delete.
     !canonical||canonical.schoolId!==school||canonical.id!==request.id||
     canonical._syncDeleted!==true||canonical._syncRevision!==result.recordRevision||
     canonical._syncOperationId!==request.operationId||
     canonical._syncErasePlan?.complete!==true||
     !Array.isArray(result.deletionTargets)||result.deletionTargets.length<1||result.deletionTargets.length>5000)
   fail('DELETE_EVERYWHERE_ACK_UNVERIFIED');
  const targets=result.deletionTargets,keys=new Set();
  for(const target of targets){
   if(!target||!COLLECTIONS.has(target.collection)||!validId(target.id)||
      target.generation!==undefined&&(typeof target.generation!=='string'||!target.generation||target.generation.length>200)||
      keys.has(target.collection+'/'+target.id))fail('DELETE_EVERYWHERE_TARGET_UNVERIFIED');
   keys.add(target.collection+'/'+target.id);
  }
  if(!keys.has(request.collection+'/'+request.id))fail('DELETE_EVERYWHERE_TARGET_UNVERIFIED');
  const root=targets.find(target=>target.collection===request.collection&&target.id===request.id);
  if(root?.revision!==result.recordRevision||
     // This plan must be the same plan that the Google provider completed.
     canonical._syncErasePlan.targets?.length!==targets.length)
    fail('DELETE_EVERYWHERE_ACK_UNVERIFIED');
  let deleted=0;
  // Exact deterministic paths make retries after any partial success idempotent.
  // A transaction rechecks ownership/generation immediately before deletion;
  // a replacement pupil using the same class/roll slot is never erased.
  for(const target of targets){
   const ref=db.doc('schools/'+school+'/'+target.collection+'/'+target.id);
   const removed=await db.runTransaction(async tx=>{
    const snapshot=await tx.get(ref);if(!snapshot.exists)return false;
    const row=snapshot.data();
    if(row.schoolId!==undefined&&row.schoolId!==school)fail('DELETE_EVERYWHERE_FOREIGN_RECORD');
    const generation=row.mobileStableId||row.personId||row._syncDeletedOwner;
    if(target.generation&&generation&&generation!==target.generation)fail('DELETE_EVERYWHERE_GENERATION_CONFLICT');
    // Matching a pupil's identity is not enough: an independent PC may have
    // committed a NEWER same-generation edit while the Drive purge was pending.
    // Delete only the exact original source revision, or the exact verified
    // tombstone revision. Any later Firebase write remains intact for review.
    const sourceMatches=typeof target.sourceRevision==='string'&&
      target.sourceRevision.length>0&&row._syncRevision===target.sourceRevision;
    const tombstoneMatches=row._syncDeleted===true&&
      typeof target.revision==='string'&&target.revision.length>0&&
      row._syncRevision===target.revision;
    if(!sourceMatches&&!tombstoneMatches)
      fail('DELETE_EVERYWHERE_GENERATION_UNPROVEN');
    if(typeof tx.delete!=='function')throw Object.assign(Error('Atomic Firebase delete is unavailable.'),{status:503,code:'DELETE_EVERYWHERE_FIREBASE_UNAVAILABLE'});
    tx.delete(ref);return true;
   });
   if(removed)deleted++;
  }
  return {...result,firebaseDeletionComplete:true,firebaseDeletedRecords:deleted};
 }
 return {finish};
}
module.exports={createDeleteEverywhere};

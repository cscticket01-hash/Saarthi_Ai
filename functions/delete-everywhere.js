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
  if(!SCHOOL.test(school)||request.operation!=='delete'||request.syncProtocol!==2||
     result?.success!==true||result.schoolId!==school||result.syncProtocol!==2||
     result.deleteEverywhereVersion!==1||result.driveDeletionComplete!==true||
     typeof result.recordRevision!=='string'||!result.recordRevision||/^(?:cf-|live-)/.test(result.recordRevision)||
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
    const sameGeneration=target.generation&&generation===target.generation;
    const sameRevision=target.sourceRevision&&row._syncRevision===target.sourceRevision||target.revision&&row._syncDeleted===true&&row._syncRevision===target.revision;
    if(!sameGeneration&&!sameRevision)fail('DELETE_EVERYWHERE_GENERATION_UNPROVEN');
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

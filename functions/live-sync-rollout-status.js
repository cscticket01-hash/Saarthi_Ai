'use strict';
const {COLLECTIONS}=require('./live-sync');
const deliveryLanes=['records','notices'];
// Diagnostic read only: no seed, migration fence, queue reset or authority write.
async function rolloutStatus({schoolId,enabled,db,edge,readDrive}){
 const state=(await db.doc('school_live_migrations/'+schoolId).get()).data()||{};
 const collections=Object.fromEntries([...COLLECTIONS].map(name=>[name,state.collections?.[name]?.state||'legacy']));
 const blockers=[];let workerVerified=false,scriptVerified=false,queuesVerified=false;
 let pending=null,needsAttention=null,scriptBundleVersion=null,deliveryQueues=null;
 if(!enabled)blockers.push('BROKER_SCHOOL_NOT_ENABLED');
 if(enabled){
  try{
   const head=await edge.rpc(schoolId,'live',{command:'head'});
   workerVerified=head?.schoolId===schoolId&&head.liveProtocol===1&&Number.isSafeInteger(head.cursor)&&head.cursor>=0;
  }catch(_){}
  if(!workerVerified)blockers.push('WORKER_SCHOOL_NOT_VERIFIED');
  try{
   const health=await readDrive({action:'managed_health'});
   scriptBundleVersion=typeof health?.scriptBundleVersion==='string'?health.scriptBundleVersion:null;
   scriptVerified=health?.success===true&&health.schoolId===schoolId&&health.storageReady===true&&health.recordSyncVersion===2&&health.sheetLifecycleVersion===1&&health.teacherRetirementVersion===1&&health.staffRetirementVersion===1&&health.deleteEverywhereVersion===1;
  }catch(_){}
  if(!scriptVerified)blockers.push('SCHOOL_SCRIPT_UPGRADE_OR_VERIFICATION_REQUIRED');
  try{
   const stats=await Promise.all(deliveryLanes.map(lane=>edge.rpc(schoolId,lane,{command:'stats'})));
   queuesVerified=stats.every(s=>Number.isSafeInteger(s?.pending)&&s.pending>=0&&Number.isSafeInteger(s?.needsAttention)&&s.needsAttention>=0);
   if(queuesVerified){
    pending=stats.reduce((n,s)=>n+s.pending,0);
    needsAttention=stats.reduce((n,s)=>n+s.needsAttention,0);
    deliveryQueues=Object.fromEntries(deliveryLanes.map((lane,index)=>[
     lane,{pending:stats[index].pending,needsAttention:stats[index].needsAttention}
    ]));
   }
  }catch(_){}
  if(!queuesVerified)blockers.push('LEGACY_DELIVERY_STATUS_UNVERIFIED');
  else if(pending||needsAttention)blockers.push('LEGACY_DELIVERY_PENDING');
 }
 const inflight=Object.keys(state.inflight||{}).length+Object.keys(state.liveInflight||{}).length;
 if(inflight)blockers.push('UNSETTLED_WRITES_REQUIRE_RECONCILIATION');
 if(Object.values(collections).some(s=>s!=='active'))blockers.push('VERIFIED_COLLECTION_MIGRATION_REQUIRED');
 return {success:true,schoolId,liveProtocol:1,configured:enabled,workerVerified,scriptVerified,scriptBundleVersion,queuesVerified,pending,needsAttention,deliveryQueues,unsettledWrites:inflight,collections,blockers,
  // Server status cannot certify installed clients, p95 or physical devices.
  fullRolloutVerified:false};
}
module.exports={rolloutStatus};

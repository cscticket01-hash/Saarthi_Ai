'use strict';
const {createHash}=require('node:crypto');
const STATES=new Set(['healthy','monitoring','degraded','recovering','needsAttention','paused','unknown']);
const FAILURES=new Set(['none','offline','timeout','server','quota','authorization','identity','configuration','conflict','databaseLocked','storage','corrupt','worker','decoding','rendering','overloaded','unknown']);
const COMPONENTS=new Set(['startup','database','smart-sync','sync-view','id-card','qr','inventory','documents','attendance','notices','monitor-worker','sync-scheduler','health-report-timer','sync-retry-dispatch','sync-checkpoint-timer','health-delivery-scheduler','mobile-context-timer','document-worker']);
function reject(status,message){const e=Error(message);e.status=status;e.publicMessage=true;throw e;}
function sanitize(report){
 if(!report||Object.getPrototypeOf(report)!==Object.prototype||Buffer.byteLength(JSON.stringify(report))>8192)reject(400,'Invalid health report');
 const keys=new Set(['schema','measuredAt','platform','version','installation','state','registered','healthy','issues','verifiedRepairs','failedRepairs','components']);
 if(Object.keys(report).some(k=>!keys.has(k))||report.schema!==2||!['windows','android'].includes(report.platform)||!/^\d{1,3}\.\d{1,3}(\.\d{1,6})?(-(alpha|beta|rc|sync-test|test)(\.\d{1,6})?)?$/.test(report.version)||!/^[a-f0-9]{64}$/.test(report.installation)||!STATES.has(report.state))reject(400,'Unsupported health report');
 for(const k of ['registered','healthy','issues','verifiedRepairs','failedRepairs'])if(!Number.isSafeInteger(report[k])||report[k]<0||report[k]>(['registered','healthy','issues'].includes(k)?64:256))reject(400,'Invalid health counters');
 if(!Array.isArray(report.components)||report.components.length>32||report.registered!==report.components.length||report.healthy>report.registered||report.issues>report.registered)reject(400,'Invalid health components');
 const ids=new Set();
 const components=report.components.map(c=>{if(!c||Object.keys(c).sort().join(',')!=='failure,id,state'||!COMPONENTS.has(c.id)||ids.has(c.id)||!STATES.has(c.state)||!FAILURES.has(c.failure))reject(400,'Unsafe health component');ids.add(c.id);return {id:c.id,state:c.state,failure:c.failure};});
 if(components.filter(c=>c.state==='healthy').length!==report.healthy||components.filter(c=>c.failure!=='none').length!==report.issues)reject(400,'Health counters do not match');
 if(!Number.isSafeInteger(report.measuredAt)||report.measuredAt<=0)reject(400,'Measurement timestamp required');
 return {...report,components};
}
function createHealthTelemetry({db,now=Date.now}){
 return {
  async report(schoolId,principal,raw){
   const report=sanitize(raw),id=createHash('sha256').update(JSON.stringify([schoolId,principal,report.installation])).digest('hex');
   const ref=db.doc('universal_health_reports/'+id),at=now();
   if(report.measuredAt>at+120000||report.measuredAt<at-86400000)reject(400,'Health measurement timestamp is unavailable or stale');
   const budget=db.doc('universal_health_limits/'+createHash('sha256').update(schoolId+'/'+principal).digest('hex'));
   return db.runTransaction(async tx=>{
    const [old,limit]=await Promise.all([tx.get(ref),tx.get(budget)]);
    if(limit.exists&&at-limit.data().receivedAt<15000)return {success:true,schoolId,accepted:false,retryAfterMs:15000};
    if(old.exists&&at-old.data().receivedAt<60000)return {success:true,schoolId,accepted:false,retryAfterMs:60000};
    tx.set(budget,{receivedAt:at,expiresAt:at+86400000});
    tx.set(ref,{...report,installation:id,schoolId,receivedAt:at,expiresAt:at+7*86400000});
    return {success:true,schoolId,accepted:true};
   });
  },
  async summary(schoolId){
   const result=await db.collection('universal_health_reports').where('schoolId','==',schoolId).limit(201).get();
   if(result.docs.length>200)return {success:true,schoolId,available:false,reason:'Report bound exceeded; no partial totals',measuredAt:now()};
   const reports=[];
   for(const doc of result.docs){const r=doc.data();if(r.schoolId!==schoolId)reject(403,'Foreign health report');if(r.expiresAt>now())reports.push(r);}
   const fresh=reports.filter(r=>r.receivedAt<=now()&&now()-r.receivedAt<600000&&r.measuredAt<=now()+120000&&now()-r.measuredAt<600000);
   const versions={},failures={};let verified=0,failed=0;
   for(const r of fresh){versions[r.platform+'/'+r.version]=(versions[r.platform+'/'+r.version]||0)+1;verified+=r.verifiedRepairs;failed+=r.failedRepairs;for(const c of r.components)if(c.failure!=='none')failures[c.id+'/'+c.failure]=(failures[c.id+'/'+c.failure]||0)+1;}
   return {success:true,schoolId,available:true,measuredAt:now(),reporting:reports.length,fresh:fresh.length,unknown:reports.length-fresh.length,healthy:fresh.filter(r=>r.state==='healthy').length,needsAttention:fresh.filter(r=>r.state==='needsAttention').length,versions,failures,verifiedRepairs:verified,failedRepairs:failed,repairSuccessRate:verified+failed?verified/(verified+failed):null,reports:reports.map(r=>({installation:r.installation,platform:r.platform,version:r.version,state:now()-r.receivedAt<600000&&r.measuredAt<=now()+120000&&now()-r.measuredAt<600000?r.state:'unknown',receivedAt:r.receivedAt,components:r.components}))};
  }
 };
}
module.exports={sanitize,createHealthTelemetry};

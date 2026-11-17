'use strict';
// TEST evidence gate only. Never logs private records, request hashes or credentials.
const fs=require('node:fs'),path=require('node:path');
const nonneg=x=>Number.isSafeInteger(x)&&x>=0;
const needed=['school_calendar:Cloudflare-ACK-then-Drive',
 'documents:Cloudflare-ACK-then-Drive','teachers_directory:signed-person-lifecycle-Drive'];
function evaluateEvidence({audit,cloud,script,delivery}){
 const blockers=[],block=x=>{if(!blockers.includes(x))blockers.push(x);};
 // A successful read-only diagnosis of unresolved originals is valid audit
 // evidence, NOT a successful release. Differentiate real missing-proof
 // blockers from malformed/untrusted audit data without relaxing either.
 const remaining=audit?.after?.unsettledWrites;
 const abandoned=audit?.after?.abandonedTestOperations;
 if(!nonneg(abandoned))block('ORIGINAL_AUDIT_UNVERIFIED');
 const ownerReset=abandoned===14&&remaining===0&&audit?.after?.originalHistoryVerified===false&&audit?.status==='DISPOSABLE_TEST_HISTORY_ABANDONED';
 if(abandoned>0&&!ownerReset)block('UNREVIEWED_TEST_HISTORY_DISPOSITION');
 const consistentAuditStatus=(audit?.status==='DISPOSABLE_TEST_HISTORY_ABANDONED'&&remaining===0&&abandoned>0)||
   (audit?.status==='NO_BLOCKERS'&&remaining===0)||
   (audit?.status==='READONLY_DIAGNOSTIC_COMPLETE_RELEASE_BLOCKED'&&nonneg(remaining)&&remaining>0);
 if(!consistentAuditStatus||audit?.stage!=='complete'||audit.exactRuntimeVerified!==true||
   audit.previewResponseShape?.previewOnly!==true||audit.previewResponseShape?.cleared!==0||
   audit.reconciliation?.cleared!==0||audit.reconciliation?.more!==false||
   audit.concurrentMarkerChange===true)block('ORIGINAL_AUDIT_UNVERIFIED');
 const before=audit?.before?.unsettledWrites,after=audit?.after?.unsettledWrites;
 const scanned=audit?.reconciliation?.scanned,retained=audit?.reconciliation?.retained;
 if(![before,after,scanned,retained,audit?.reconciliation?.previewWouldClear].every(nonneg)||
   scanned<before||scanned<after||retained>scanned)block('ORIGINAL_AUDIT_INCOMPLETE');
 if(before!==0||after!==0||retained!==0||audit?.reconciliation?.previewWouldClear!==0)
  block('UNSETTLED_ORIGINAL_OPERATIONS');
 if(audit?.queuesVerifiedBefore!==true||!nonneg(audit?.before?.pending)||
  !nonneg(audit?.before?.needsAttention)||!nonneg(audit?.after?.pending)||
  !nonneg(audit?.after?.needsAttention)||audit.before.pending||
  audit.before.needsAttention||audit.after.pending||audit.after.needsAttention)
  block('UNVERIFIED_DELIVERY_QUEUES');
 if(cloud?.status!=='PASS'||cloud?.deployedScriptEvidence?.matchesReviewedSource!==true)
  block('TEST_OWNER_SCRIPT_UNVERIFIED');
 if(script?.status!=='PASS'||script?.actualAdmissionErrorVersion!==1)
  block('SIGNED_ADMISSION_UNVERIFIED');
 const routes=Array.isArray(delivery?.verifiedRoutes)?delivery.verifiedRoutes:[];
 const types=new Set(routes.map(x=>x.collection+':'+x.route));
 if(delivery?.status!=='PASS'||delivery.bytesReadbackVerified!==true||
  !nonneg(delivery.bytesWritten)||delivery.bytesWritten<1||
  !needed.every(x=>types.has(x))||
  routes.filter(x=>x.collection==='teachers_directory'&&x.route==='signed-person-lifecycle-Drive').length<2)
  block('CLOUDFLARE_TO_DRIVE_READBACK_UNVERIFIED');
 return {scope:'isolated TEST evidence; NO production authorization',
  status:blockers.length?'RELEASE_BLOCKED':ownerReset?'TEST_DISPOSABLE_BASELINE_READY':'TEST_ORIGINAL_PROOFS_CLEARED',
  originalHistoryVerified:ownerReset?false:undefined,historyDisposition:ownerReset?'OWNER_ABANDONED_DISPOSABLE_TEST_ONLY':'ORIGINAL_PROOFS_REQUIRED',
  productionAuthorized:false,unresolvedOriginalCount:nonneg(after)?after:null,
  blockerCodes:blockers,
  independentProductionGates:['PHYSICAL_WINDOWS_ANDROID','CROSS_VERSION_ACK_IDLE',
    'ELAPSED_24H_RETENTION','OWNER_APPROVAL']};
}
function read(file){try{return JSON.parse(fs.readFileSync(file,'utf8'));}catch{return null;}}
function main(){
 const base=process.env.VS_TEST_EVIDENCE_ROOT||'build/cloud-prerequisites';
 const result=evaluateEvidence({
  audit:read(path.join(base,'edge-original-reconciliation.json')),
  cloud:read(path.join(base,'report.json')),
  script:read(path.join(base,'script-admission-capability.json')),
  delivery:read(path.join(base,'cloudflare-delivery.json'))});
 fs.mkdirSync(base,{recursive:true});
 fs.writeFileSync(path.join(base,'sync3-release-readiness.json'),JSON.stringify(result,null,2));
 console.log(JSON.stringify(result));
 if(process.env.GITHUB_STEP_SUMMARY)fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY,
  '## Sync 3 TEST release fence\n\nStatus: '+result.status+
  '\n\nUnresolved originals: '+(result.unresolvedOriginalCount??'unknown')+
  '\n\nReasons: '+(result.blockerCodes.join(', ')||'none')+
  '\n\nProduction authorized: **No**. Physical device and elapsed retention gates remain independent.\n');
 if(!['TEST_ORIGINAL_PROOFS_CLEARED','TEST_DISPOSABLE_BASELINE_READY'].includes(result.status))process.exitCode=1;
}
if(require.main===module)main();
module.exports={evaluateEvidence};

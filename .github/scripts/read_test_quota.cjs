"use strict";
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {createRequire}=require('node:module');
const {createMonitor}=require('../../functions/managed-monitor.js');
async function main(){
 assert.equal(process.env.GITHUB_ACTIONS,'true');
 assert.equal(process.env.GITHUB_REPOSITORY,'cscticket01-hash/Saarthi_Ai');
 assert.equal(process.env.GITHUB_REF,'refs/heads/test/read-quota-20261111');
 const account=JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON||'{}');
 assert.equal(account.type,'service_account');assert.equal(account.project_id,'saarthi-ai-df12b');
 assert.ok(account.client_email?.endsWith('@saarthi-ai-df12b.iam.gserviceaccount.com'));
 const req=createRequire(path.resolve(__dirname,'../../functions/package.json'));
 const {cert}=req('firebase-admin/app');
 const credential=cert(account);
 const denied=[];
 const fetchRead=async(url,options)=>{
  assert.ok(!options?.method||options.method==='GET','Read-only provider observation');
  const response=await fetch(url,options);
  if(response.status===403){
   try{const data=await response.clone().json();
    for(const detail of data.error?.details||[]) {
     const reason=/^[A-Z_]{1,100}$/.test(detail.reason||'')?detail.reason:null;
     const permission=/^[a-zA-Z.]{1,100}$/.test(detail.metadata?.permission||'')?detail.metadata.permission:null;
     if(reason||permission)denied.push({reason,permission});
    }
   }catch{}
  }
  return response;
 };
 const metrics=await createMonitor({credential,projectId:account.project_id,fetchImpl:fetchRead})();
 // Existing project monitor makes GET requests only. No workload, API activation,
 // IAM update, billing changes, record reads or fixture creation occurs here.
 const report={status:'BLOCKED_CAPACITY_NOT_CERTIFIED',sourceSha:process.env.GITHUB_SHA,
  observedAt:new Date().toISOString(),projectId:account.project_id,readOnly:true,
  workloadSubmitted:false,billingChanged:false,metrics,accessDenials:denied,
  missing:['Complete daily provider consumption and reserved headroom','Database edition and effective account quotas','Synthetic signed attendance fixture inventory','Measured amplification and restart acceptance']};
 fs.mkdirSync('build/cloud-prerequisites',{recursive:true});
 fs.writeFileSync('build/cloud-prerequisites/test-quota-observation.json',JSON.stringify(report,null,2));
 console.log('TEST_QUOTA_OBSERVATION '+JSON.stringify({status:report.status,available:metrics.available,
  reason:metrics.reason||null,quotasAvailable:metrics.quotas?.available===true,
  quotaReason:metrics.quotas?.reason||null,partial:metrics.partial===true,accessDenials:[...new Set(denied.map(x=>JSON.stringify(x)))].map(x=>JSON.parse(x)),workloadSubmitted:false}));
}
main().catch(()=>{console.error('TEST_QUOTA_OBSERVATION_FAILED: scoped read unavailable');process.exitCode=1;});

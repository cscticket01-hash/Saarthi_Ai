'use strict';
const crypto=require('node:crypto'),assert=require('node:assert/strict'),fs=require('node:fs');
const school='vs-db8afb01a3be46a983c8284714d06e5d';
const endpoint='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const identityUrl='https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const h=s=>crypto.createHash('sha256').update(s).digest('hex');
const recordId='CF_TEST_TEACHER_verify-20261114-43605131030';
const operationId=h(school+':teachers_directory:'+recordId);
const ticket=h(JSON.stringify([school,'managed_records',['teachers_directory',recordId,operationId]]));
const report={mode:'authenticated-read-only-original-synthetic-teacher-diagnosis',status:'UNKNOWN',schoolIdIsTEST:true,checks:[],noWrites:true};
async function send(url,body,token){
 const r=await fetch(url,{method:'POST',redirect:'error',headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(80000)});
 const d=await r.json();return{status:r.status,data:d};
}
(async()=>{
 assert.equal(process.env.GITHUB_ACTIONS,'true');assert.equal(process.env.GITHUB_REPOSITORY,'cscticket01-hash/Saarthi_Ai');
 assert.ok(process.env.VS_TEST_LOGIN_EMAIL&&process.env.VS_TEST_LOGIN_PASSWORD,'TEST secrets unavailable');
 const login=await send(identityUrl,{email:process.env.VS_TEST_LOGIN_EMAIL,password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
 assert.equal(login.status,200);
 assert.ok(typeof login.data.idToken==='string');
 const api=async b=>send(endpoint,{...b,schoolId:school},login.data.idToken);
 const health=await api({action:'managed/storage/check'});assert.equal(health.status,200);
 assert.equal(health.data.schoolId,school);
 report.health={deployedScriptAdmissionErrorVersion:health.data.requestAdmissionErrorVersion??null,edgeDeliveryEnabled:health.data.brokerEdgeDeliveryVersion===1};
 const read=await api({action:'managed/records',operation:'read',syncProtocol:2,collection:'teachers_directory',id:recordId});
 report.record={http:read.status,success:read.data.success===true,schoolBound:read.data.schoolId===school,recordFound:!!read.data.records?.[recordId],
  hasRevision:typeof read.data.records?.[recordId]?._syncRevision==='string',errorCode:/^[A-Z_]{1,60}$/.test(read.data.code||'')?read.data.code:null};
 const status=await api({action:'managed/cloudflare/operation',lane:'records',id:ticket});
 report.ticket={http:status.status,success:status.data.success===true,schoolBound:status.data.schoolId===school,
  cloudflareAccepted:status.data.cloudflareAccepted===true,
  driveState:['pending','verified','failed','receiving','retry'].includes(status.data.driveState)?status.data.driveState:'unreported',
  deliveryPresent:!!status.data.delivery,
  recordRevisionPresent:typeof status.data.recordRevision==='string',
  deliveryState:['pending','retry','completed','needsAttention','claimed'].includes(status.data.deliveryStatus?.state)?status.data.deliveryStatus.state:'unreported',
  errorCode:/^[A-Z_]{1,60}$/.test(status.data.code||'')?status.data.code:null};
 report.status='INSPECTED';
})().catch(e=>{report.status='BLOCKED';report.blocker='TEST identity or signed read-only route unavailable';process.exitCode=1;})
 .finally(()=>{fs.mkdirSync('build/cloud-prerequisites',{recursive:true});fs.writeFileSync('build/cloud-prerequisites/synthetic-teacher-postmortem.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));});

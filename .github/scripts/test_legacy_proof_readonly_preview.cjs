'use strict';
// Isolated TEST-only proof audit. It may retire an original migration marker
// ONLY through the production reconciler's exact completed receipt proof.
// No student write, queue deletion, forced success or migration activation.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const {waitForRuntime}=require('./test_runtime_identity.cjs');
const school='vs-db8afb01a3be46a983c8284714d06e5d';
const endpoint='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const report={status:'NOT_RUN',scope:'read-only original TEST legacy marker proof inspection'};
function writeReport(){
 fs.mkdirSync('build/cloud-prerequisites',{recursive:true});
 fs.writeFileSync('build/cloud-prerequisites/edge-original-reconciliation.json',
  JSON.stringify(report,null,2));
}
async function request(url,body,token){
 const response=await fetch(url,{
  method:'POST',headers:{'content-type':'application/json',
   ...(token?{authorization:'Bearer '+token}:{})},
  body:JSON.stringify(body),signal:AbortSignal.timeout(120000),
 });
 let result;
 try{result=await response.json();}catch{throw Error('TEST response unreadable');}
 if(!response.ok||result.success===false){
  const code=/^[A-Z_]{1,80}$/.test(result.code||'')?result.code:'TEST_CALL_UNAVAILABLE';
  throw Error('Isolated TEST action rejected: '+code);
 }
 return result;
}
async function run(){
 assert.equal(process.env.GITHUB_ACTIONS,'true');
 assert.equal(process.env.GITHUB_REPOSITORY,'cscticket01-hash/Saarthi_Ai');
 assert.equal(process.env.VS_TEST_CONNECT_CONFIRM,school);
 assert.match(process.env.VS_EXPECTED_TEST_RUNTIME||'',/^[a-f0-9]{40}$/);
 assert.ok(process.env.VS_TEST_LOGIN_EMAIL&&process.env.VS_TEST_LOGIN_PASSWORD);
 await waitForRuntime(process.env.VS_EXPECTED_TEST_RUNTIME);
 report.exactRuntimeVerified=true;
 const config=fs.readFileSync('lib/platform/platform_config.dart','utf8');
 const apiKey=config.match(/const platformApiKey = '([A-Za-z0-9_-]+)'/)?.[1];
 assert.ok(apiKey,'TEST identity service unavailable');
 const login=await request(
  'https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key='+apiKey,
  {email:process.env.VS_TEST_LOGIN_EMAIL,
   password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
 assert.ok(login.idToken,'TEST school login required');
 const admin=async(action,body={})=>{
  const response=await request(endpoint,{...body,schoolId:school,action},login.idToken);
  assert.equal(response.schoolId,school);
  return response;
 };
 const profile=await admin('managed/profile',{operation:'read'});
 assert.equal(profile.profile?.schoolName,'TEST Sync V2');
 const status=()=>admin('managed/live/rollout-status',{liveProtocol:1});
 const before=await status();
 assert.equal(before.configured,true);
 assert.equal(before.workerVerified,true);
 assert.equal(before.scriptVerified,true);
 assert.equal(before.queuesVerified,true);
 assert.ok(Number.isSafeInteger(before.unsettledWrites)&&before.unsettledWrites>=0);
 report.before={unsettledWrites:before.unsettledWrites,
  pending:before.pending,needsAttention:before.needsAttention};
 // No Firestore write or original marker retirement is permitted in this audit.
 const result=await admin('managed/live/reconcile',{liveProtocol:1,previewOnly:true});
 assert.equal(result.previewOnly,true,'TEST broker must provide zero-write inspection');
 assert.equal(result.cleared,0,'Zero-write inspection cannot retire original markers');
 assert.ok(Number.isSafeInteger(result.previewWouldClear)&&result.previewWouldClear>=0);
 assert.equal(result.success,true);
 assert.ok(Number.isSafeInteger(result.cleared)&&result.cleared>=0);
 report.reconciliation={scanned:result.scanned,cleared:result.cleared,previewWouldClear:result.previewWouldClear,
  retained:result.retained,reasons:result.reasons,proofSources:result.proofSources||{},more:result.more};
 const after=await status();
 assert.ok(Number.isSafeInteger(after.unsettledWrites)&&after.unsettledWrites>=0);
 assert.equal(after.unsettledWrites,before.unsettledWrites,
  'A read-only preview may not change outstanding markers');
 report.after={unsettledWrites:after.unsettledWrites,
  pending:after.pending,needsAttention:after.needsAttention};
 report.status=after.unsettledWrites===0?'NO_BLOCKERS':'READONLY_DIAGNOSTIC_COMPLETE_RELEASE_BLOCKED';
}
run().catch(error=>{
 report.status='DIAGNOSTIC_FAILED';
 console.error(error.message);
 process.exitCode=1;
}).finally(()=>{
 try{writeReport();}catch(error){
  console.error('TEST evidence could not be written');
  process.exitCode=1;
 }
});
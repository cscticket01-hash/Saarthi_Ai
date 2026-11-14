'use strict';
// Isolated TEST only. One existing server CAS may retire at most the two
// ORIGINAL signed Drive proofs authenticated in the 2026-11-14 read-only audit.
// Never touch school rows, notice queues, unverified markers or production.
const assert=require('node:assert/strict'),fs=require('node:fs');
const {waitForRuntime}=require('./test_runtime_identity.cjs');
const school='vs-db8afb01a3be46a983c8284714d06e5d';
const endpoint='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const report={scope:'isolated_TEST_exact_original_2_only',status:'NOT_RUN',writesAllowed:'existing_exact_CAS_only',productionAuthorized:false};
function save(){fs.mkdirSync('build/cloud-prerequisites',{recursive:true});fs.writeFileSync('build/cloud-prerequisites/exact-original-2-cas.json',JSON.stringify(report,null,2));}
async function request(url,body,token){
 const response=await fetch(url,{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(360000)});
 let out;try{out=await response.json();}catch{throw Error('Authenticated TEST response unreadable');}
 if(!response.ok||out.success===false){
  const code=/^[A-Z_]{1,80}$/.test(out?.code||'')?out.code:'TEST_CALL_UNAVAILABLE';
  throw Error('Isolated TEST action blocked: '+code);
 }
 return out;
}
const nonnegative=x=>Number.isSafeInteger(x)&&x>=0;
function safeCounts(source){return Object.fromEntries(Object.entries(source||{}).filter(([name,n])=>/^[a-z_]{1,80}$/.test(name)&&nonnegative(n)));}
async function run(){
 assert.equal(process.env.GITHUB_ACTIONS,'true');
 assert.equal(process.env.GITHUB_REPOSITORY,'cscticket01-hash/Saarthi_Ai');
 assert.equal(process.env.GITHUB_REF,'refs/heads/test/exact-original-2-proof-cas-20261114');
 assert.equal(process.env.VS_TEST_CONNECT_CONFIRM,school);
 assert.match(process.env.VS_EXPECTED_TEST_RUNTIME||'',/^[a-f0-9]{40}$/);
 assert.ok(process.env.VS_TEST_LOGIN_EMAIL&&process.env.VS_TEST_LOGIN_PASSWORD);
 report.stage='pinned_runtime';
 await waitForRuntime(process.env.VS_EXPECTED_TEST_RUNTIME);
 const platform=fs.readFileSync('lib/platform/platform_config.dart','utf8');
 const apiKey=platform.match(/const platformApiKey = '([A-Za-z0-9_-]+)'/)?.[1];
 assert.ok(apiKey,'TEST identity unavailable');
 report.stage='authenticated_test_profile';
 const login=await request('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key='+apiKey,
  {email:process.env.VS_TEST_LOGIN_EMAIL,password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
 assert.ok(login.idToken);
 const admin=async(action,extra={})=>{
  const reply=await request(endpoint,{...extra,schoolId:school,action},login.idToken);
  assert.equal(reply.schoolId,school);
  return reply;
 };
 const profile=await admin('managed/profile',{operation:'read'});
 assert.equal(profile.profile?.schoolName,'TEST Sync V2');
 const status=()=>admin('managed/live/rollout-status',{liveProtocol:1});
 report.stage='status_before';
 const before=await status();
 assert.equal(before.configured,true);
 assert.equal(before.workerVerified,true);
 assert.equal(before.scriptVerified,true);
 assert.equal(before.queuesVerified,true);
 assert.equal(before.pending,0);
 assert.equal(before.needsAttention,0);
 report.before={unsettledWrites:before.unsettledWrites,pending:before.pending,needsAttention:before.needsAttention};
 assert.equal(before.unsettledWrites,16,'Original TEST marker cohort changed: require a new read-only review');
 report.stage='preview_exact_signed_originals';
 const preview=await admin('managed/live/reconcile',{liveProtocol:1,previewOnly:true,limit:100});
 assert.equal(preview.previewOnly,true);
 assert.equal(preview.cleared,0);
 assert.equal(preview.more,false);
 assert.equal(preview.scanned,16);
 assert.equal(preview.previewWouldClear,2,'Only the two previously audited originals may be retired');
 assert.equal(preview.retained,14);
 assert.equal(preview.reasons?.proof_unverified,14);
 assert.equal(preview.proofSources?.drive_exact,2);
 assert.equal(preview.proofSources?.legacy_marker,16);
 report.preview={scanned:preview.scanned,previewWouldClear:preview.previewWouldClear,
  retained:preview.retained,reasons:safeCounts(preview.reasons),sources:safeCounts(preview.proofSources)};
 // This single existing API is already implemented as exact original
 // operation+request-hash+Drive revision proof followed by transactional CAS.
 // No direct Firestore write, new business request or forged successful ACK.
 report.stage='exact_original_cas';
 const result=await admin('managed/live/reconcile',{liveProtocol:1,limit:100});
 assert.equal(result.success,true);
 assert.ok(nonnegative(result.cleared)&&result.cleared<=2,'Unexpected marker retirement');
 report.cleared=result.cleared;
 report.reconciliation={scanned:result.scanned,cleared:result.cleared,retained:result.retained,reasons:safeCounts(result.reasons),sources:safeCounts(result.proofSources)};
 report.stage='after_readback';
 const after=await status();
 report.after={unsettledWrites:after.unsettledWrites,pending:after.pending,needsAttention:after.needsAttention};
 assert.equal(after.unsettledWrites,16-result.cleared,'Concurrent state changed; preserve all remaining originals');
 assert.equal(after.pending,0);
 assert.equal(after.needsAttention,0);
 const secondPreview=await admin('managed/live/reconcile',{liveProtocol:1,previewOnly:true,limit:100});
 assert.equal(secondPreview.cleared,0);
 assert.equal(secondPreview.previewOnly,true);
 assert.equal(secondPreview.more,false);
 assert.equal(secondPreview.previewWouldClear,0,'No second retirement without new original proof');
 report.finalPreview={scanned:secondPreview.scanned,previewWouldClear:secondPreview.previewWouldClear,retained:secondPreview.retained,
  reasons:safeCounts(secondPreview.reasons)};
 report.status=result.cleared===2&&after.unsettledWrites===14?'TWO_EXACT_ORIGINALS_CAS_RECOVERED_RELEASE_BLOCKED':
  'PARTIAL_ORIGINAL_CAS_REVIEW_REQUIRED';
 report.stage='complete';
 console.log(JSON.stringify({scope:report.scope,status:report.status,before:report.before,
  cleared:report.cleared,after:report.after,finalPreview:report.finalPreview,productionAuthorized:false}));
}
run().catch(error=>{
 report.status='BLOCKED_OR_RECHECK_REQUIRED';
 console.error(error.message);
 process.exitCode=1;
}).finally(()=>{try{save();}catch{console.error('Could not save sanitized exact-proof report');process.exitCode=1;}});

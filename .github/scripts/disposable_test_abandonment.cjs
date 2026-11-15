'use strict';
const assert=require('node:assert/strict'),fs=require('node:fs');
const {waitForRuntime}=require('./test_runtime_identity.cjs');
const school='vs-db8afb01a3be46a983c8284714d06e5d',url='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const report={scope:'OWNER_AUTHORIZED_DISPOSABLE_TEST_ABANDONMENT',backupVerified:false,productionAuthorized:false,status:'NOT_RUN'};
async function send(url,body,token){const r=await fetch(url,{method:'POST',headers:{'content-type':'application/json',...(token?{authorization:'Bearer '+token}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(120000)});return {http:r.status,data:await r.json()};}
async function run(){
 assert.equal(process.env.GITHUB_ACTIONS,'true');assert.equal(process.env.GITHUB_REPOSITORY,'cscticket01-hash/Saarthi_Ai');assert.equal(process.env.GITHUB_REF,'refs/heads/test/abandon-originals-20261115');
 await waitForRuntime(process.env.VS_EXPECTED_TEST_RUNTIME);
 const source=fs.readFileSync('lib/platform/platform_config.dart','utf8'),key=source.match(/const platformApiKey = '([A-Za-z0-9_-]+)'/)?.[1];assert.ok(key);
 const login=await send('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key='+key,{email:process.env.VS_TEST_LOGIN_EMAIL,password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});assert.equal(login.http,200);assert.ok(login.data.idToken);
 const call=async(action,extra={})=>{const r=await send(url,{...extra,action,schoolId:school},login.data.idToken);assert.equal(r.http,200,'TEST request unavailable');assert.equal(r.data.success,true);assert.equal(r.data.schoolId,school);return r.data;};
 assert.equal((await call('managed/profile',{operation:'read'})).profile?.schoolName,'TEST Sync V2');
 if(process.env.VS_CLEANUP_PHASE==='inventory_verify'){
  const started=Date.now();const inventory=await call('managed/file/inventory');
  assert.equal(inventory.binaryInventoryVersion,1);assert.ok(Array.isArray(inventory.items));
  const inventoryMs=Date.now()-started;
  const item=inventory.items.find(x=>x.verification==='bytes_hashed'&&x.sizeBytes>0&&x.sizeBytes<=1024*1024);assert.ok(item,'No small verified original on inventory page');
  const readStarted=Date.now();const downloaded=await call('managed/file/download',{fileId:item.fileId,expectedSha256:item.sha256,expectedVersion:item.version});
  const downloadMs=Date.now()-readStarted;const bytes=Buffer.from(downloaded.base64,'base64');assert.equal(bytes.length,item.sizeBytes);assert.equal(require('node:crypto').createHash('sha256').update(bytes).digest('hex'),item.sha256);
  const status=await call('managed/live/rollout-status',{liveProtocol:1});
  Object.assign(report,{scope:'READ_ONLY_TEST_INVENTORY_ORIGINAL_READBACK',status:'PASS',inventoryMs,downloadMs,items:inventory.items.length,partial:inventory.partial,scanLimited:inventory.scanLimited,coverageComplete:inventory.coverageComplete,verifiedOriginalBytes:bytes.length,exactSha256Verified:true,unsettledWrites:status.unsettledWrites,inventoryScriptRoundTripMillis:inventory.syncTiming?.scriptRoundTripMillis});
  return;
 }
 const confirmDisposableTest='owner-disposable-test-20261115';
 if(process.env.VS_CLEANUP_PHASE==='verified_reconcile'){
  const before=await call('managed/live/rollout-status',{liveProtocol:1});assert.equal(before.abandonedTestOperations,14);
  const preview=await call('managed/live/reconcile',{liveProtocol:1,previewOnly:true,limit:100});assert.equal(preview.previewOnly,true);assert.equal(preview.cleared,0);
  const result=await call('managed/live/reconcile',{liveProtocol:1,limit:100});
  const after=await call('managed/live/rollout-status',{liveProtocol:1});assert.equal(after.abandonedTestOperations,14);assert.equal(after.originalHistoryVerified,false);
  Object.assign(report,{status:after.unsettledWrites===0?'NEW_TEST_ORIGINALS_EXACT_PROOF_RECONCILED':'NEW_TEST_PROOFS_STILL_PENDING',before:before.unsettledWrites,clearedWithProof:result.cleared,remaining:after.unsettledWrites,priorAbandoned:14});
  assert.equal(after.unsettledWrites,0);return;
 }
 if(process.env.VS_CLEANUP_PHASE==='disabled'){
  const r=await send(url,{action:'managed/test-originals',schoolId:school,operation:'preview',confirmDisposableTest},login.data.idToken);assert.equal(r.http,403);report.status='TEMPORARY_TEST_MAINTENANCE_DISABLED';return;
 }
 report.stage='preview';const p=await call('managed/test-originals',{operation:'preview',confirmDisposableTest});
 assert.equal(p.status,'PREVIEW_ONLY');assert.equal(p.previewOnly,true);assert.equal(p.count,14);assert.equal(p.backupVerified,false);assert.match(p.cohortHash,/^[a-f0-9]{64}$/);
 report.stage='archive_exact_snapshot';const a=await call('managed/test-originals',{operation:'abandon',confirmDisposableTest,expectedCohortHash:p.cohortHash});
 assert.equal(a.status,'TEST_HISTORY_ABANDONED_NOT_BACKUP_PROOF');assert.equal(a.abandoned,14);assert.equal(a.unsettledWrites,0);assert.equal(a.backupVerified,false);
 report.stage='fresh_readback';const s=await call('managed/live/rollout-status',{liveProtocol:1});assert.equal(s.unsettledWrites,0);assert.equal(s.abandonedTestOperations,14);assert.equal(s.originalHistoryVerified,false);
 const again=await call('managed/test-originals',{operation:'abandon',confirmDisposableTest,expectedCohortHash:p.cohortHash});assert.equal(again.alreadyApplied,true);assert.equal(again.unsettledWrites,0);
 Object.assign(report,{status:'14_TEST_MARKERS_ARCHIVED_AS_ABANDONED',archived:14,unsettledWrites:s.unsettledWrites,originalHistoryVerified:false,idempotentReplay:true});
}
run().catch(()=>{report.status='BLOCKED_REVIEW_REQUIRED';process.exitCode=1;}).finally(()=>{fs.mkdirSync('build/cloud-prerequisites',{recursive:true});fs.writeFileSync('build/cloud-prerequisites/test-abandonment.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));});

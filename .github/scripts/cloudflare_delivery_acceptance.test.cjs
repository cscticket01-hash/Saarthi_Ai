'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {acceptance,ENDPOINT,LOGIN,SCHOOL}=require('./cloudflare_delivery_acceptance.cjs');
const env={VS_CF_DELIVERY_ACCEPTANCE:'1',VS_EXPECTED_RUNTIME:'a'.repeat(40),
 VS_CF_DELIVERY_RUN_ID:'synthetic-retained',VS_TEST_LOGIN_EMAIL:'secret-test-email',VS_TEST_LOGIN_PASSWORD:'secret-test-password'};
test('live acceptance cannot run without explicit opt-in and a stable run ID',async()=>{
 for(const patch of [{VS_CF_DELIVERY_ACCEPTANCE:'0'},{VS_CF_DELIVERY_RUN_ID:'../unsafe'},{VS_EXPECTED_RUNTIME:'wrong'}]){
  let requests=0;const result=await acceptance({env:{...env,...patch},request:async()=>{requests++;throw Error();}});
  assert.equal(result.status,'FAIL');assert.equal(requests,0);
 }
});
test('unexpected deployed runtime prevents TEST login and all writes',async()=>{
 const calls=[];const result=await acceptance({env,request:async(url,body)=>{
  calls.push({url,body});return {status:200,data:{ready:true,projectId:'saarthi-ai-df12b',runtimeCommit:'b'.repeat(40)}};
 }});
 assert.equal(result.status,'FAIL');assert.equal(calls.length,1);assert.equal(calls[0].url,ENDPOINT+'/healthz');assert.equal(calls[0].body,undefined);
});
test('foreign membership fails before business data and reports no credentials',async()=>{
 const calls=[];const result=await acceptance({env,request:async(url,body)=>{
  calls.push({url,body});
  if(url===ENDPOINT+'/healthz')return {status:200,data:{ready:true,projectId:'saarthi-ai-df12b',runtimeCommit:env.VS_EXPECTED_RUNTIME}};
  if(url===LOGIN)return {status:200,data:{idToken:'private-token',localId:'private-uid'}};
  assert.equal(body.schoolId,SCHOOL);assert.equal(body.action,'managed/session');
  return {status:403,data:{success:false,code:'SCHOOL_MEMBERSHIP_REQUIRED',message:'private-secret'}};
 }});
 assert.equal(result.status,'FAIL');assert.equal(calls.length,3);
 assert.doesNotMatch(JSON.stringify(result),/private-token|private-uid|private-secret|secret-test-email|secret-test-password/);
});
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),crypto=require('node:crypto');
const hash=v=>crypto.createHash('sha256').update(v).digest('hex');
const offlineEnv={...env,GITHUB_ACTIONS:'true',GITHUB_REPOSITORY:'cscticket01-hash/Saarthi_Ai',GITHUB_REF:'refs/heads/test/r2-offline-provider-20261114'};
function offlineFixture(state='verified'){
 const calls=[],bytes=Buffer.from('%PDF-1.4\n% SYNTHETIC OFFLINE DELIVERY TEST ONLY\n%%EOF\n');
 const id=hash(JSON.stringify([SCHOOL,'cf_offline_'+env.VS_CF_DELIVERY_RUN_ID]));
 return {calls,request:async(url,body)=>{
  calls.push(body?.action||url);
  const data={success:true,schoolId:SCHOOL};
  if(url===ENDPOINT+'/healthz')Object.assign(data,{ready:true,projectId:'saarthi-ai-df12b',runtimeCommit:env.VS_EXPECTED_RUNTIME});
  else if(url===LOGIN)Object.assign(data,{idToken:'private-token',localId:'private-uid'});
  else if(body.action==='managed/session')Object.assign(data,{allowed:true,uid:'private-uid'});
  else if(body.action==='managed/storage/check')Object.assign(data,{storageReady:true,scriptBundleVersion:require('./reviewed_script_version.cjs').currentReviewedScriptVersion(),brokerEdgeDeliveryVersion:1,recordSyncVersion:2,uploadResumableVersion:1,brokerAtomicSmallFilesVersion:1});
  else if(body.action==='managed/file/upload')Object.assign(data,{cloudflareAccepted:true,driveState:'pending',delivery:{id,lane:'file-'+id}});
  else if(body.action==='managed/cloudflare/operation')Object.assign(data,{cloudflareAccepted:true,driveState:state,committed:state==='verified',sha256:hash(bytes),sizeBytes:bytes.length,...(state==='verified'?{fileId:'test-file'}:{delivery:{id,lane:'file-'+id}})});
  else if(body.action==='managed/file/read')Object.assign(data,{mime:'application/pdf',base64:bytes.toString('base64')});
  else throw Error('Unexpected write or drain');
  return {status:200,data};
 }};
}
test('offline acceptance exits after one durable upload; verifier never uploads or drains',async()=>{
 const cwd=process.cwd(),temp=fs.mkdtempSync(path.join(os.tmpdir(),'offline-delivery-'));process.chdir(temp);
 try{
  const f=offlineFixture();const accepted=await acceptance({env:{...offlineEnv,VS_CF_OFFLINE_PHASE:'accept'},request:f.request});
  assert.equal(accepted.status,'ACCEPTED');assert.equal(f.calls.filter(x=>x==='managed/file/upload').length,1);assert(!f.calls.includes('managed/cloudflare/operation'));
  const p='build/cloud-prerequisites/offline-accepted.json',proof=JSON.parse(fs.readFileSync(p));assert.doesNotMatch(JSON.stringify(proof),/private-token|secret-test/);
  const early=offlineFixture();assert.equal((await acceptance({env:{...offlineEnv,VS_CF_OFFLINE_PHASE:'verify'},request:early.request})).status,'FAIL');assert(!early.calls.includes('managed/cloudflare/operation'));
  proof.acceptedAtClient-=181000;fs.writeFileSync(p,JSON.stringify(proof));
  const v=offlineFixture();const done=await acceptance({env:{...offlineEnv,VS_CF_OFFLINE_PHASE:'verify'},request:v.request});assert.equal(done.status,'PASS');assert(done.bytesReadbackVerified);assert(!v.calls.includes('managed/file/upload'));assert.equal(v.calls.filter(x=>x==='managed/cloudflare/operation').length,1);
  const pending=offlineFixture('pending');assert.equal((await acceptance({env:{...offlineEnv,VS_CF_OFFLINE_PHASE:'verify'},request:pending.request})).status,'FAIL');assert(!pending.calls.includes('managed/file/read'));
  proof.id='0'.repeat(64);fs.writeFileSync(p,JSON.stringify(proof));const changed=offlineFixture();assert.equal((await acceptance({env:{...offlineEnv,VS_CF_OFFLINE_PHASE:'verify'},request:changed.request})).status,'FAIL');assert(!changed.calls.includes('managed/cloudflare/operation'));
 }finally{process.chdir(cwd);fs.rmSync(temp,{recursive:true,force:true});}
});

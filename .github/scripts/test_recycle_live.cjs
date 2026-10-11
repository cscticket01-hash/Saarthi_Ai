'use strict';
// Disposable synthetic notice only. No real-school access, purge or queue ACK.
const fs=require('node:fs'),assert=require('node:assert/strict');
const schoolId='vs-db8afb01a3be46a983c8284714d06e5d';
const endpoint='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const apiKey='AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const mode=process.env.VS_TEST_RECYCLE_MODE||'restore';
const report={schoolId,mode,sourceSha:/^[a-f0-9]{40}$/.test(process.env.GITHUB_SHA||'')?process.env.GITHUB_SHA:null,checks:[],status:'RUNNING',permanentDeletion:false};
function expiryInputs(){
 assert.ok(['restore','start-expiry','check-expiry'].includes(mode));
 if(mode==='restore')return null;
 const id=process.env.VS_TEST_RECYCLE_FIXTURE_ID||'';
 assert.match(id,/^recycle-expiry-v1-[a-z0-9][a-z0-9-]{7,60}$/);
 if(mode==='check-expiry'){
  assert.match(process.env.VS_TEST_RECYCLE_DELETED_REVISION||'',/^[A-Za-z0-9_-]{16,100}$/);
  for(const k of ['VS_TEST_RECYCLE_DELETED_AT','VS_TEST_RECYCLE_RECOVER_UNTIL'])assert.match(process.env[k]||'',/^[0-9]{13}$/);
 }
 return id;
}
async function post(url,body,token){
 const response=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(120000)});
 return {http:response.status,data:await response.json()};
}
async function run(){
 const expiryId=expiryInputs();
 assert.equal(process.env.GITHUB_ACTIONS,'true');assert.equal(process.env.VS_TEST_CONNECT_CONFIRM,schoolId);
 assert.ok(process.env.VS_TEST_LOGIN_EMAIL&&process.env.VS_TEST_LOGIN_PASSWORD);
 let r=await post('https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key='+apiKey,{email:process.env.VS_TEST_LOGIN_EMAIL,password:process.env.VS_TEST_LOGIN_PASSWORD,returnSecureToken:true});
 assert.equal(r.http,200);const token=r.data.idToken;assert.ok(token);
 const call=async body=>{
  const result=await post(endpoint,{...body,schoolId},token);
  assert.equal(result.http,200);assert.equal(result.data.success,true);assert.equal(result.data.schoolId,schoolId);return result.data;
 };
 const pass=name=>report.checks.push({name,status:'PASS'});
 await call({action:'managed/session'});pass('Authenticated isolated TEST identity');
 if(expiryId){
  const read=()=>call({action:'managed/records',operation:'read',collection:'school_notices',syncProtocol:2});
  const title='Retained TEST elapsed expiry capture 12345';
  let row=(await read()).records[expiryId];
  if(mode==='start-expiry'&&row?._syncDeleted!==true){
   if(row){assert.equal(row.syntheticTest,true);assert.equal(row.capturedAt,12345);assert.equal(row.title,title);assert.equal(row._syncOperationId,expiryId+'-create');}
   const created=row||await call({action:'managed/records',operation:'write',collection:'school_notices',id:expiryId,syncProtocol:2,operationId:expiryId+'-create',expectedRecordRevision:'',data:{schoolId,syntheticTest:true,title,capturedAt:12345}});
   const revision=created.recordRevision||created._syncRevision;assert.ok(revision);
   const before=(await read()).records[expiryId];assert.equal(before.capturedAt,12345);assert.equal(before.syntheticTest,true);
   await call({action:'managed/records',operation:'delete',collection:'school_notices',id:expiryId,syncProtocol:2,operationId:expiryId+'-delete',expectedRecordRevision:revision});
   row=(await read()).records[expiryId];
  }
  assert.equal(row?._syncDeleted,true);assert.equal(row.schoolId,schoolId);assert.equal(row._syncOperationId,expiryId+'-delete');assert.ok(row._syncRecycleFileId);
  let after='',entry=null,serverNow=0;
  for(let page=0;page<20;page++){
   const inventory=await call({action:'managed/recycle',operation:'list',collection:'school_notices',after});
   assert.equal(inventory.recycleVersion,1);assert.ok(Number.isSafeInteger(inventory.serverNow));serverNow=inventory.serverNow;
   entry=inventory.entries.find(item=>item.id===expiryId);if(entry||!inventory.partial)break;after=inventory.nextAfter;
  }
  assert.ok(entry);assert.equal(entry.name,title);assert.equal(entry.deletedRevision,row._syncRevision);assert.equal(entry.auditRetained,true);
  assert.equal(entry.recoverUntil-entry.deletedAt,86400000);assert.equal(row._syncRecycleUntil,entry.recoverUntil);
  assert.equal(entry.status,serverNow>=entry.recoverUntil?'expired':'recoverable');
  if(mode==='check-expiry'){assert.equal(entry.deletedRevision,process.env.VS_TEST_RECYCLE_DELETED_REVISION);assert.equal(entry.deletedAt,Number(process.env.VS_TEST_RECYCLE_DELETED_AT));assert.equal(entry.recoverUntil,Number(process.env.VS_TEST_RECYCLE_RECOVER_UNTIL));}
  report.expiry={fixtureId:expiryId,deletedRevision:entry.deletedRevision,deletedAt:entry.deletedAt,recoverUntil:entry.recoverUntil,serverNow,elapsedMillis:serverNow-entry.deletedAt,status:entry.status,elapsedDayVerified:mode==='check-expiry'&&serverNow>=entry.recoverUntil,captureMarkerVerified:true};
  pass('Same TEST Sheets tombstone and retained Drive snapshot with unchanged server deadline');
  if(report.expiry.elapsedDayVerified){
   // Only the retained synthetic TEST fixture, and only after the real server
   // deadline. Never restore during its valid window or permanently purge it.
   const rejected=await post(endpoint,{action:'managed/recycle',operation:'restore',schoolId,
    fileId:row._syncRecycleFileId,operationId:expiryId+'-expired-restore-probe',expectedRecordRevision:entry.deletedRevision},token);
   report.expiry.restoreProbe={http:rejected.http,code:rejected.data.code||null};
   assert.equal(rejected.http,502);assert.equal(rejected.data.code,'SCRIPT_OPERATION_FAILED');
   assert.notEqual(rejected.data.success,true);
   // This observes rejection; the sanitized provider error does not expose the
   // owner-only exception, so do not claim an exact provider exception reason.
   const retained=(await read()).records[expiryId];
   assert.deepEqual(retained,row);
   let retainedEntry=null;after='';
   for(let page=0;page<20;page++){
    const inventory=await call({action:'managed/recycle',operation:'list',collection:'school_notices',after});
    assert.ok(inventory.serverNow>=entry.recoverUntil);
    retainedEntry=inventory.entries.find(item=>item.id===expiryId);
    if(retainedEntry||!inventory.partial)break;after=inventory.nextAfter;
   }
   assert.ok(retainedEntry);assert.equal(retainedEntry.status,'expired');assert.equal(retainedEntry.auditRetained,true);
   for(const field of ['deletedRevision','deletedAt','recoverUntil'])assert.equal(retainedEntry[field],entry[field]);
   report.expiry.expiredRestoreRejected=true;report.expiry.auditRetainedAfterProbe=true;
   pass('Expired TEST restore rejected; unchanged tombstone, snapshot deadline and retained audit read back');
  }
  report.status=report.expiry.elapsedDayVerified?'PASS':'WAITING_REAL_ELAPSED_DAY';report.fixtureRetained=true;return;
 }
 const id='recycle-rehearsal-'+process.env.GITHUB_RUN_ID+'-'+process.env.GITHUB_RUN_ATTEMPT;
 const created=await call({action:'managed/records',operation:'write',collection:'school_notices',id,syncProtocol:2,operationId:id+'-create',expectedRecordRevision:'',data:{schoolId,syntheticTest:true,title:'Disposable TEST recycle rehearsal',capturedAt:12345}});
 assert.equal(created.syncProtocol,2);assert.ok(created.recordRevision);pass('Durable synthetic create ACK');
 const deletion={action:'managed/records',operation:'delete',collection:'school_notices',id,syncProtocol:2,operationId:id+'-delete',expectedRecordRevision:created.recordRevision};
 const deleted=await call(deletion);assert.ok(deleted.recordRevision);pass('Versioned TEST deletion ACK');
 const repeated=await call(deletion);assert.equal(repeated.recordRevision,deleted.recordRevision);pass('Same-operation delete deduplicated');
 const read=()=>call({action:'managed/records',operation:'read',collection:'school_notices',syncProtocol:2});
 const tomb=(await read()).records[id];assert.equal(tomb._syncDeleted,true);assert.ok(tomb._syncRecycleFileId);pass('Sheets tombstone and Drive snapshot readback');
 let after='',entry=null;
 for(let page=0;page<20;page++){
  const inventory=await call({action:'managed/recycle',operation:'list',collection:'school_notices',after});
  assert.equal(inventory.recycleVersion,1);assert.ok(Number.isSafeInteger(inventory.serverNow));
  entry=inventory.entries.find(item=>item.id===id);if(entry||!inventory.partial)break;after=inventory.nextAfter;
 }
 assert.ok(entry);assert.equal(entry.status,'recoverable');assert.equal(entry.deletedRevision,deleted.recordRevision);assert.equal(entry.auditRetained,true);pass('Verified Recycle Bin inventory and 24-hour server deadline');
 const restore={action:'managed/recycle',operation:'restore',fileId:tomb._syncRecycleFileId,operationId:id+'-restore',expectedRecordRevision:deleted.recordRevision};
 const restored=await call(restore);assert.equal(restored.restored,true);assert.equal(restored.syncProtocol,2);assert.notEqual(restored.recordRevision,deleted.recordRevision);pass('Authorized CAS restore durable ACK');
 assert.equal((await call(restore)).recordRevision,restored.recordRevision);pass('Lost-ACK restore retry deduplicated');
 const row=(await read()).records[id];assert.equal(row._syncRevision,restored.recordRevision);assert.equal(row._syncDeleted,undefined);assert.equal(row.capturedAt,12345);assert.equal(row.syntheticTest,true);assert.ok(Number.isSafeInteger(row._syncUpdatedAt)&&row._syncUpdatedAt>=entry.deletedAt);pass('Restored original capture time and new authoritative restore timestamp Sheets readback');
 const stale=await post(endpoint,{...deletion,schoolId,operationId:id+'-stale-delete'},token);assert.notEqual(stale.http,200);pass('Stale deletion cannot overwrite restored record');
 const foreign=await post(endpoint,{action:'managed/recycle',operation:'list',collection:'school_notices',schoolId:'vs-ffffffffffffffffffffffffffffffff'},token);assert.notEqual(foreign.http,200);pass('Foreign school access rejected');
 report.status='PASS';report.fixtureRetained=true;report.permanentDeletion=false;
}
run().catch(()=>{report.status='FAIL';process.exitCode=1;}).finally(()=>{
 fs.mkdirSync('build/cloud-prerequisites',{recursive:true});fs.writeFileSync('build/cloud-prerequisites/recycle-live.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
});

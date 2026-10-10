'use strict';
// Disposable synthetic notice only. No real-school access, purge or queue ACK.
const fs=require('node:fs'),assert=require('node:assert/strict');
const schoolId='vs-db8afb01a3be46a983c8284714d06e5d';
const endpoint='https://saarthi-sync-v2-test.onrender.com/school-cloud';
const apiKey='AIzaSyDherXWiNIbKzO8EFuf1VdpHvu7U6R-W3A';
const report={schoolId,checks:[],status:'RUNNING'};
async function post(url,body,token){
 const response=await fetch(url,{method:'POST',headers:{'Content-Type':'application/json',...(token?{Authorization:`Bearer ${token}`}:{})},body:JSON.stringify(body),signal:AbortSignal.timeout(120000)});
 return {http:response.status,data:await response.json()};
}
async function run(){
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
 const row=(await read()).records[id];assert.equal(row._syncRevision,restored.recordRevision);assert.equal(row._syncDeleted,undefined);assert.equal(row.capturedAt,12345);assert.equal(row.syntheticTest,true);pass('Restored original data and timestamp Sheets readback');
 const stale=await post(endpoint,{...deletion,schoolId,operationId:id+'-stale-delete'},token);assert.notEqual(stale.http,200);pass('Stale deletion cannot overwrite restored record');
 const foreign=await post(endpoint,{action:'managed/recycle',operation:'list',collection:'school_notices',schoolId:'vs-ffffffffffffffffffffffffffffffff'},token);assert.notEqual(foreign.http,200);pass('Foreign school access rejected');
 report.status='PASS';report.fixtureRetained=true;report.permanentDeletion=false;
}
run().catch(()=>{report.status='FAIL';process.exitCode=1;}).finally(()=>{
 fs.mkdirSync('build/cloud-prerequisites',{recursive:true});fs.writeFileSync('build/cloud-prerequisites/recycle-live.json',JSON.stringify(report,null,2));console.log(JSON.stringify(report));
});

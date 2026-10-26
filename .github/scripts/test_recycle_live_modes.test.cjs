'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
const source=fs.readFileSync(require('node:path').join(__dirname,'test_recycle_live.cjs'),'utf8');
const schoolId='vs-db8afb01a3be46a983c8284714d06e5d',id='recycle-expiry-v1-unit-test',revision='deleted-revision-12345',deletedAt=1791600000000;
async function simulate(mode,elapsed,override={}){
 const calls=[];let report,exitCode,recordReads=0;
 const env={GITHUB_ACTIONS:'true',VS_TEST_CONNECT_CONFIRM:schoolId,VS_TEST_LOGIN_EMAIL:'synthetic',VS_TEST_LOGIN_PASSWORD:'synthetic',VS_TEST_RECYCLE_MODE:mode,VS_TEST_RECYCLE_FIXTURE_ID:id,VS_TEST_RECYCLE_DELETED_REVISION:revision,VS_TEST_RECYCLE_DELETED_AT:String(deletedAt),VS_TEST_RECYCLE_RECOVER_UNTIL:String(deletedAt+86400000),...override};
 await new Promise(resolve=>{
 const process={env};
 vm.runInNewContext(source,{require:name=>name==='node:fs'?{mkdirSync(){},writeFileSync(){}}:require(name),process,AbortSignal,console:{log:value=>{report=JSON.parse(value);exitCode=process.exitCode;resolve();}},fetch:async(url,options)=>{
  const b=JSON.parse(options.body);calls.push(b);
  let data;if(url.startsWith('https://identitytoolkit'))data={idToken:'synthetic-token'};
  else if(b.action==='managed/records'){recordReads++;data={records:{[id]:{schoolId,_syncDeleted:true,_syncRevision:override.CHANGE_AFTER_PROBE&&recordReads>1?'unexpected-revision':revision,_syncOperationId:id+'-delete',_syncRecycleFileId:'test-private-file',_syncRecycleUntil:deletedAt+86400000}}};}
  else if(b.action==='managed/recycle'&&b.operation==='restore')return {status:Number(override.PROBE_HTTP||502),json:async()=>({success:false,code:override.PROBE_CODE||'SCRIPT_OPERATION_FAILED'})};
  else if(b.action==='managed/recycle')data={recycleVersion:1,serverNow:deletedAt+elapsed,partial:false,entries:[{id,name:'Retained TEST elapsed expiry capture 12345',deletedRevision:revision,deletedAt,recoverUntil:deletedAt+86400000,status:elapsed>=86400000?'expired':'recoverable',auditRetained:true}]};
  else data={};
  return {status:200,json:async()=>({success:true,schoolId,...data})};
 }});
 });return {calls,report,exitCode};
}
test('read-only elapsed-day check remains pending before real server deadline',async()=>{
 const r=await simulate('check-expiry',86399999);assert.equal(r.report.status,'WAITING_REAL_ELAPSED_DAY');assert.equal(r.report.expiry.elapsedDayVerified,false);assert(!r.calls.some(x=>['write','delete','restore','purge'].includes(x.operation)));
});
test('elapsed-day check probes rejected restore only after full day and rereads retained evidence',async()=>{
 const r=await simulate('check-expiry',86400000);assert.equal(r.report.status,'PASS');assert.equal(r.report.expiry.elapsedDayVerified,true);
 assert.equal(r.report.expiry.expiredRestoreRejected,true);assert.equal(r.report.expiry.auditRetainedAfterProbe,true);
 const probes=r.calls.filter(x=>x.operation==='restore');assert.equal(probes.length,1);assert.equal(probes[0].fileId,'test-private-file');assert.equal(probes[0].expectedRecordRevision,revision);
 assert.equal(r.calls.filter(x=>x.action==='managed/records'&&x.operation==='read').length,2);
 assert(!r.calls.some(x=>['write','delete','purge'].includes(x.operation)));
});
test('accepted or unrelated failed restore cannot pass expired rejection acceptance',async()=>{
 for(const extra of [{PROBE_HTTP:'200'},{PROBE_HTTP:'403',PROBE_CODE:'UNAUTHORIZED'},{PROBE_HTTP:'503',PROBE_CODE:'SCRIPT_TIMEOUT'},{CHANGE_AFTER_PROBE:'true'}]){
  const r=await simulate('check-expiry',86400000,extra);assert.equal(r.report.status,'FAIL');assert.equal(r.exitCode,1);
 }
});
test('invalid fixture scope fails before authentication or cloud calls',async()=>{
 const r=await simulate('check-expiry',86400000,{VS_TEST_RECYCLE_FIXTURE_ID:'original-school-entry'});assert.equal(r.report.status,'FAIL');assert.equal(r.exitCode,1);assert.equal(r.calls.length,0);
});
test('check refuses changed baseline revision and start resumes without another deletion',async()=>{
 const bad=await simulate('check-expiry',86400000,{VS_TEST_RECYCLE_DELETED_REVISION:'wrong-deleted-revision'});assert.equal(bad.report.status,'FAIL');
 const resumed=await simulate('start-expiry',1000);assert.equal(resumed.report.status,'WAITING_REAL_ELAPSED_DAY');assert(!resumed.calls.some(x=>['write','delete','restore','purge'].includes(x.operation)));
});

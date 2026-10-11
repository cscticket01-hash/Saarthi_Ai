import {createHash} from 'node:crypto';
import test from 'node:test';
import assert from 'node:assert/strict';
import {admission,stats,TEST_SCHOOL,verifyReadback} from './staging_attendance_acceptance.mjs';
const config={count:25,concurrency:1,runtimeSha:'a'.repeat(40),maxRequests:100,maxStatusReads:50,deadlineMs:600000};
const evidence=()=>({schoolId:TEST_SCHOOL,runtimeSha:config.runtimeSha,observed:true,projectId:'saarthi-ai-df12b',costCeilingUsd:0,billingChangeAllowed:false,approvedStageCount:25,sampledAt:1000,providers:Object.fromEntries(['firestore','appsScript','sheets','drive'].map(p=>[p,p==='firestore'?{observed:true,available:true,source:'owner-observed counter',unit:'operations',writeHeadroom:500,readHeadroom:500,reservedWrites:100,reservedReads:250,extraWrites:1,extraReads:60,measuredWritesPerEvent:3,measuredReadsPerEvent:2}:{observed:true,available:true,source:'owner-observed counter',unit:'requests',headroom:200,reservedBudget:125}]))});
test('missing, stale, foreign and runtime-mismatched quota evidence blocks before requests',()=>{for(const e of [null,{...evidence(),schoolId:'foreign'},{...evidence(),sampledAt:0},{...evidence(),runtimeSha:'b'.repeat(40)}])assert.throws(()=>admission(config,e,400000),/BLOCKED/);assert.equal(admission(config,evidence(),1001),true);});
test('all providers must have observed sufficient headroom',()=>{for(const p of ['firestore','appsScript','sheets','drive']){const e=evidence();if(p==='firestore')e.providers[p].writeHeadroom=1;else e.providers[p].headroom=1;assert.throws(()=>admission(config,e,1001),/BLOCKED/);}const e=evidence();e.providers.firestore.reservedWrites=74;assert.throws(()=>admission(config,e,1001),/insufficient/);});
test('only approved stage sizes and bounded concurrency are admitted',()=>{for(const c of [0,5,1.5])assert.throws(()=>admission({...config,concurrency:c},evidence(),1001));assert.throws(()=>admission({...config,count:26},evidence(),1001));assert.throws(()=>admission({...config,maxRequests:NaN},evidence(),1001));});
test('percentiles use finite observations and include P99',()=>{assert.deepEqual(stats([5,1,3,2,4,NaN]),{samples:5,p50Ms:3,p95Ms:5,p99Ms:5});assert.equal(stats([]),null);});

test('Firestore read and write budgets cannot substitute for each other',()=>{for(const patch of [{reservedReads:1},{reservedWrites:1},{readHeadroom:1},{writeHeadroom:1},{measuredWritesPerEvent:2},{measuredReadsPerEvent:1},{extraReads:0},{unit:'requests'},{readHeadroom:NaN}]){const e=evidence();Object.assign(e.providers.firestore,patch);assert.throws(()=>admission(config,e,1001),/BLOCKED/);}});
test('known project, zero cost and correct provider units required',()=>{for(const patch of [{projectId:'foreign'},{costCeilingUsd:1},{billingChangeAllowed:true}])assert.throws(()=>admission(config,{...evidence(),...patch},1001),/BLOCKED/);const e=evidence();e.providers.drive.unit='bytes';assert.throws(()=>admission(config,e,1001),/BLOCKED/);});

test('authoritative projection rejects wrong operation, capture and duplicate rows',()=>{const op={role:'student',stablePersonId:'stable',personId:'document',day:'2026-10-11',mode:'entry',operationId:'a'.repeat(64),clientCapturedAt:100};const row={personId:'stable',documentId:'document',role:'student',date:op.day,entryOperationId:op.operationId,entryCapturedAt:100};const id=createHash('sha256').update('student/stable/'+op.day).digest('hex');const records={[id]:row};assert.equal(verifyReadback(records,[op])[0].projectionVerified,true);for(const patch of [{entryCapturedAt:101},{entryOperationId:'b'},{documentId:'foreign'}])assert.throws(()=>verifyReadback({[id]:{...row,...patch}},[op]),/mismatch/);assert.throws(()=>verifyReadback({...records,extra:row},[op]),/mismatch/);});


test('operator guard preserves a sanitized durable blocked report with zero requests',async()=>{
 const {mkdtemp,readFile,rm}=await import('node:fs/promises');
 const {tmpdir}=await import('node:os');const {join}=await import('node:path');
 const {spawnSync}=await import('node:child_process');
 const dir=await mkdtemp(join(tmpdir(),'vs-capacity-guard-'));const target=join(dir,'report.json');
 try{
  const child=spawnSync(process.execPath,[new URL('./staging_attendance_acceptance.mjs',import.meta.url).pathname,'--run-isolated-test'],{encoding:'utf8',env:{...process.env,VS_TEST_SCHOOL_ID:TEST_SCHOOL,VS_TEST_ISOLATED_CONFIRM:TEST_SCHOOL,VS_TEST_ADMIN_ID_TOKEN:'PRIVATE_TOKEN_CANARY',VS_TEST_QUOTA_EVIDENCE:join(dir,'missing-observed-quota.json'),VS_TEST_REPORT_PATH:target}});
  assert.equal(child.status,1);const text=await readFile(target,'utf8');const report=JSON.parse(text);
  assert.equal(report.status,'BLOCKED');assert.equal(report.requests,0);assert.equal(report.pass,false);
  assert.equal(report.realCloudReadbackVerified,false);assert.deepEqual(report.operations,[]);
  assert.ok(!text.includes('PRIVATE_TOKEN_CANARY'));assert.ok(!child.stdout.includes('PRIVATE_TOKEN_CANARY'));
 }finally{await rm(dir,{recursive:true,force:true});}
});

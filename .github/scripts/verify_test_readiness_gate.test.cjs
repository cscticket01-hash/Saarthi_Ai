'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {classify,mismatch}=require('./verify_test_readiness_gate.cjs');
const expectedRuntime='a'.repeat(40);
const env={expectedRuntime,eventName:'pull_request',headRef:'feature/sync3-atomic-bundle-phase1-20261105'};
const health={name:'Firebase readiness',status:'PASS',http:200};
test('unreleased atomic PR reports BLOCKED release acceptance without failing source CI',()=>{
 const report={status:'BLOCKED',runtimeCommit:'b'.repeat(40),checks:[health],blocker:mismatch};
 assert.equal(classify(report,env),'PR_CODE_ONLY_TEST_NOT_DEPLOYED');
});
test('only exact deployed commit plus source-matched Script may obtain real acceptance',()=>{
 const report={status:'PASS',runtimeCommit:expectedRuntime,checks:[health],
   deployedScriptEvidence:{matchesReviewedSource:true}};
 assert.equal(classify(report,env),'DEPLOYED_TEST_VERIFIED');
 for(const changed of [
  {...report,runtimeCommit:'b'.repeat(40)},
  {...report,deployedScriptEvidence:{matchesReviewedSource:false}},
  {...report,checks:[health,{name:'Storage readback',status:'FAIL'}]},
 ])assert.throws(()=>classify(changed,env));
});
test('cannot waive unrelated cloud failure, missing identity, or non-atomic branch',()=>{
 const blocked={status:'BLOCKED',runtimeCommit:'b'.repeat(40),checks:[health],blocker:mismatch};
 for(const changed of [
  {...blocked,blocker:'Owner TEST storage is unavailable'},
  {...blocked,status:'FAIL'},
  {...blocked,runtimeCommit:'Unknown'},
  {...blocked,checks:[{...health,status:'FAIL'}]},
  {...blocked,checks:[health,{name:'Additional failure',status:'FAIL'}]},
 ])assert.throws(()=>classify(changed,env));
 assert.throws(()=>classify(blocked,{...env,headRef:'main'}));
 assert.throws(()=>classify(blocked,{...env,eventName:'push'}));
 assert.throws(()=>classify(blocked,{...env,expectedRuntime:'not-a-hash'}));
 assert.throws(()=>classify(blocked,{...env,expectedRuntime:'b'.repeat(40)}));
});

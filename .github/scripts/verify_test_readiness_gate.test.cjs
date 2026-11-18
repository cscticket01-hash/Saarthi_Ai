'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {sourceOnlyReport,classify}=require('./verify_test_readiness_gate.cjs');
const sha='a'.repeat(40),env={expectedRuntime:sha,eventName:'pull_request',
 headRef:'feature/sync3-atomic-bundle-phase1-20261105'};
const goodHealth={name:'Firebase readiness',status:'PASS',http:200};
test('atomic draft records code-only source evidence, never live cloud PASS',()=>{
 const report=sourceOnlyReport(sha);
 assert.equal(report.status,'BLOCKED');
 assert.equal(report.cloudTestExecuted,false);
 assert.deepEqual(report.checks,[]);
 assert.equal(classify(report,env),'PR_SOURCE_ONLY_CLOUD_NOT_VERIFIED');
});
test('real TEST PASS needs exact runtime, Script source and every provider check',()=>{
 const pass={status:'PASS',runtimeCommit:sha,checks:[goodHealth],
  deployedScriptEvidence:{matchesReviewedSource:true}};
 assert.equal(classify(pass,env),'DEPLOYED_TEST_VERIFIED');
 for(const wrong of [
  {...pass,runtimeCommit:'b'.repeat(40)},
  {...pass,deployedScriptEvidence:{matchesReviewedSource:false}},
  {...pass,checks:[goodHealth,{name:'Drive',status:'FAIL'}]},
  {...pass,status:'BLOCKED'},
 ])assert.throws(()=>classify(wrong,env));
});
test('source-only evidence cannot be forged into release or a different PR',()=>{
 const report=sourceOnlyReport(sha);
 for(const wrong of [
  {...report,status:'PASS'},
  {...report,cloudTestExecuted:true},
  {...report,checks:[goodHealth]},
  {...report,expectedRuntime:'b'.repeat(40)},
  {...report,blocker:'ready'},
 ])assert.throws(()=>classify(wrong,env));
 assert.throws(()=>classify(report,{...env,headRef:'main'}));
 assert.throws(()=>classify(report,{...env,eventName:'push'}));
 assert.throws(()=>classify(report,{...env,expectedRuntime:'not-a-sha'}));
 assert.throws(()=>sourceOnlyReport('bad-sha'));
});

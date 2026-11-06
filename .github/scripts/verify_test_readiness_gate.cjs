'use strict';
/**
 * Keep real deployed-TEST acceptance distinct from review of a feature PR
 * whose exact source was intentionally not deployed.  A green GitHub check
 * must never turn an undeployed TEST readback into a release-ready PASS.
 */
const fs=require('node:fs');
const assert=require('node:assert/strict');
const mismatch='Isolated TEST runtime does not match the reviewed source; existing endpoint health is not new-code acceptance.';
function classify(report,{expectedRuntime,eventName,headRef}={}){
  assert.match(expectedRuntime||'',/^[a-f0-9]{40}$/,'Exact reviewed commit is mandatory');
  assert.equal(report?.checks?.find(c=>c.name==='Firebase readiness')?.status,'PASS',
    'TEST endpoint health and Firebase project must be verified');
  if(report.status==='PASS'){
    assert.equal(report.runtimeCommit,expectedRuntime,'Readiness must match exact deployed source');
    assert.equal(report.deployedScriptEvidence?.matchesReviewedSource,true,
      'Readiness must include deployed matching Apps Script evidence');
    assert.equal(report.checks?.every(c=>c.status==='PASS'),true);
    return 'DEPLOYED_TEST_VERIFIED';
  }
  const isUndeployedReview=eventName==='pull_request'&&
    headRef==='feature/sync3-atomic-bundle-phase1-20261105'&&
    report.status==='BLOCKED'&&report.blocker===mismatch&&
    /^[a-f0-9]{40}$/.test(report.runtimeCommit||'')&&
    report.runtimeCommit!==expectedRuntime&&
    report.checks.length===1;
  if(isUndeployedReview)return 'PR_CODE_ONLY_TEST_NOT_DEPLOYED';
  throw new Error('Isolated TEST acceptance blocked or failed; see sanitized report.');
}
if(require.main===module){
  try{
    const report=JSON.parse(fs.readFileSync('build/cloud-prerequisites/report.json','utf8'));
    const result=classify(report,{expectedRuntime:process.env.VS_EXPECTED_TEST_RUNTIME,
      eventName:process.env.GITHUB_EVENT_NAME,headRef:process.env.VS_TEST_HEAD_REF});
    if(result==='PR_CODE_ONLY_TEST_NOT_DEPLOYED'){
      console.log('PR source review is green, but the exact commit is NOT deployed on isolated TEST.');
      console.log('TEST readiness, Google Drive readback and release acceptance stay BLOCKED.');
      if(process.env.GITHUB_STEP_SUMMARY)fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY,
        '\n**PR source review only. Isolated TEST acceptance: BLOCKED (exact source not deployed).**\n');
    }else console.log('Exact-source deployed TEST readiness verified.');
  }catch(error){console.error('TEST readiness check failed closed:',error.message);process.exitCode=1;}
}
module.exports={classify,mismatch};

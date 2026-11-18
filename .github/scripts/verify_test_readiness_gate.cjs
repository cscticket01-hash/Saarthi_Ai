'use strict';
// Code-review evidence and real exact-source TEST acceptance are separate.
// Never make an offline PR claim Firebase / Apps Script / Google Drive success.
const fs=require('node:fs');
const assert=require('node:assert/strict');
const sourceBlocker='PR source CI does not execute isolated TEST cloud or Drive acceptance; an exact-source deployment and verified readback are required before release.';
const atomicBranch='feature/sync3-atomic-bundle-phase1-20261105';
function sourceOnlyReport(expectedRuntime){
  assert.match(expectedRuntime||'',/^[a-f0-9]{40}$/,'Reviewed source commit required');
  return {status:'BLOCKED',mode:'PR_SOURCE_ONLY',expectedRuntime,
    cloudTestExecuted:false,checks:[],blocker:sourceBlocker,
    remaining:'No Firebase login, Script/Drive ACK, cloud readback or device acceptance was attempted.'};
}
function classify(report,{expectedRuntime,eventName,headRef}={}){
  assert.match(expectedRuntime||'',/^[a-f0-9]{40}$/,'Exact reviewed commit is mandatory');
  if(report?.mode==='PR_SOURCE_ONLY'){
    assert.equal(eventName,'pull_request','Only a PR may record source-only evidence');
    assert.equal(headRef,atomicBranch,'Only the isolated atomic draft uses this review mode');
    assert.equal(report.status,'BLOCKED','No cloud or production success may be inferred');
    assert.equal(report.expectedRuntime,expectedRuntime,'PR evidence must bind to exact commit');
    assert.equal(report.cloudTestExecuted,false);
    assert.equal(report.blocker,sourceBlocker);
    assert.deepEqual(report.checks,[],'No fabricated cloud PASS checks permitted');
    return 'PR_SOURCE_ONLY_CLOUD_NOT_VERIFIED';
  }
  assert.equal(report?.checks?.find(c=>c.name==='Firebase readiness')?.status,'PASS',
    'Actual TEST Firebase project and health must be verified');
  if(report.status==='PASS'){
    assert.equal(report.runtimeCommit,expectedRuntime,'Deployed source must match');
    assert.equal(report.deployedScriptEvidence?.matchesReviewedSource,true,
      'Deployed Script version must match source');
    assert.equal(report.checks.every(c=>c.status==='PASS'),true,
      'Every actual cloud protocol check must pass');
    return 'DEPLOYED_TEST_VERIFIED';
  }
  throw new Error('Isolated TEST acceptance blocked or failed; inspect sanitized report.');
}
if(require.main===module){
  try{
    const settings={expectedRuntime:process.env.VS_EXPECTED_TEST_RUNTIME,
      eventName:process.env.GITHUB_EVENT_NAME,headRef:process.env.VS_TEST_HEAD_REF};
    const path='build/cloud-prerequisites/report.json';
    if(process.argv.includes('--emit-pr-source-only')){
      assert.equal(settings.eventName,'pull_request');
      assert.equal(settings.headRef,atomicBranch);
      const report=sourceOnlyReport(settings.expectedRuntime);
      fs.mkdirSync('build/cloud-prerequisites',{recursive:true});
      fs.writeFileSync(path,JSON.stringify(report,null,2));
      console.log('PR source tests only: live TEST/Drive acceptance BLOCKED and not run.');
    }else{
      const report=JSON.parse(fs.readFileSync(path,'utf8'));
      const result=classify(report,settings);
      if(result==='PR_SOURCE_ONLY_CLOUD_NOT_VERIFIED'){
        console.log('Source code checks only; TEST and Drive acceptance remain BLOCKED.');
        if(process.env.GITHUB_STEP_SUMMARY)fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY,
          '\n**Source CI only. TEST/Drive/release acceptance: BLOCKED; not tested.**\n');
      }else console.log('Exact-source deployed TEST protocol and Drive readback verified.');
    }
  }catch(error){console.error('TEST readiness gate rejected:',error.message);process.exitCode=1;}
}
module.exports={sourceOnlyReport,classify,sourceBlocker};

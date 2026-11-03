'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {selectGate,waitForTestGate}=require('./await_test_gate.cjs');
const sha='a'.repeat(40),repo='cscticket01-hash/Saarthi_Ai';
function run(change={}){return {id:123,name:'Isolated TEST cloud prerequisites',head_sha:sha,head_branch:'feature/smart-sync-3',event:'push',head_repository:{full_name:repo},status:'completed',conclusion:'success',...change};}
function fetchRuns(runs){return async()=>({status:200,json:async()=>({workflow_runs:runs})});}
test('only exact-source own-branch workflow can authorize the provider gate',()=>{
 assert.equal(selectGate([run()], 'cloud',sha).id,123);
 for(const bad of [{head_sha:'b'.repeat(40)},{head_branch:'main'},{event:'pull_request'},{head_repository:{full_name:'foreign/repo'}},{name:'Different workflow'}])
  assert.equal(selectGate([run(bad)],'cloud',sha),null);
});
test('unfinished newest exact-source run never falls back to an older success',async()=>{
 await assert.rejects(waitForTestGate({kind:'cloud',sha,token:'private',fetchImpl:fetchRuns([run({status:'in_progress',conclusion:null}),run({id:122})]),attempts:1}),/unfinished/);
});
test('failed or cancelled exact-source gate remains a failure',async()=>{
 for(const conclusion of ['failure','cancelled','skipped'])await assert.rejects(waitForTestGate({kind:'cloud',sha,token:'private',fetchImpl:fetchRuns([run({conclusion})]),attempts:1}),/did not pass/);
});
test('a completed verified run is awaited with no school provider requests',async()=>{
 let count=0,waits=0;const result=await waitForTestGate({kind:'cloud',sha,token:'private',
 fetchImpl:async url=>{assert.ok(url.startsWith('https://api.github.com/repos/'+repo+'/actions/runs?'));return {status:200,json:async()=>({workflow_runs:[run(++count===1?{status:'queued',conclusion:null}:{})]})};},
 delay:async()=>{waits++;},attempts:2});assert.equal(result.runId,123);assert.equal(waits,1);
});
test('readiness requires the matching PR head and its completed real checks',async()=>{
 const readiness=run({name:'Sync 3 isolated TEST readiness',head_branch:'feature/live-sync-authority-v1-20261102',event:'pull_request'});
 assert.equal((await waitForTestGate({kind:'readiness',sha,token:'private',fetchImpl:fetchRuns([readiness]),attempts:1})).runId,123);
 assert.equal(selectGate([readiness],'cloud',sha),null);
});
test('missing, inaccessible or malformed metadata never authorizes school access',async()=>{
 await assert.rejects(waitForTestGate({kind:'cloud',sha,token:'private',fetchImpl:fetchRuns([]),attempts:1}),/unfinished/);
 await assert.rejects(waitForTestGate({kind:'cloud',sha,token:'private',fetchImpl:async()=>({status:403}),attempts:1}),/unavailable/);
 assert.throws(()=>selectGate([], 'other',sha));assert.throws(()=>selectGate([], '__proto__',sha));assert.throws(()=>selectGate([], 'cloud','bad'));
});

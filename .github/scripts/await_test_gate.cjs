'use strict';
const assert=require('node:assert/strict');
const REPO='cscticket01-hash/Saarthi_Ai';
const GATES={
 disaster:{name:'Isolated TEST disaster recovery acceptance',branch:'feature/smart-sync-3',event:'push'},
 cloud:{name:'Isolated TEST cloud prerequisites',branch:'feature/smart-sync-3',event:'push'},
 readiness:{name:'Sync 3 isolated TEST readiness',branch:'feature/live-sync-authority-v1-20261102',event:'pull_request'}
};
function selectGate(runs,kind,sha){
 assert.ok(Object.hasOwn(GATES,kind));assert.match(sha||'',/^[a-f0-9]{40}$/);assert.ok(Array.isArray(runs));
 const gate=GATES[kind];
 return runs.find(run=>run?.name===gate.name&&run.head_sha===sha&&
  ((run.head_branch===gate.branch&&run.event===gate.event)||
   (kind==='readiness'&&run.head_branch==='feature/smart-sync-3'&&run.event==='push'))&&
  run.head_repository?.full_name===REPO)||null;
}
// The serialized cloud chain took 49m46s including writer-lock queueing on
// 2026-11-09. The old 45-minute poll budget expired before its verified PASS.
// Keep the exact-source checks and allow one hour; callers need job headroom.
async function waitForTestGate({kind,sha,token,fetchImpl=fetch,delay=ms=>new Promise(r=>setTimeout(r,ms)),attempts=240}){
 assert.ok(token);assert.ok(Object.hasOwn(GATES,kind));assert.match(sha||'',/^[a-f0-9]{40}$/);
 for(let n=0;n<attempts;n++){
  const response=await fetchImpl('https://api.github.com/repos/'+REPO+'/actions/runs?head_sha='+sha+'&per_page=100',
   {headers:{Authorization:'Bearer '+token,Accept:'application/vnd.github+json'},signal:AbortSignal.timeout(30000)});
  assert.equal(response.status,200,'Exact-source TEST gate metadata unavailable');
  const run=selectGate((await response.json()).workflow_runs,kind,sha);
  if(run?.status==='completed'){
   assert.equal(run.conclusion,'success','Exact-source TEST prerequisite did not pass');
   console.log('Verified exact-source TEST '+kind+' gate');
   return {runId:run.id,sha:run.head_sha};
  }
  if(n%12===0)console.log('Waiting for exact-source TEST '+kind+' gate');
  if(n+1<attempts)await delay(15000);
 }
 throw new Error('Exact-source TEST prerequisite remains unfinished; no provider access authorized');
}
async function main(){
 assert.equal(process.env.GITHUB_REPOSITORY,REPO);assert.equal(process.env.GITHUB_ACTIONS,'true');
 await waitForTestGate({kind:process.env.VS_TEST_GATE_KIND,sha:process.env.VS_TEST_GATE_SHA,token:process.env.GITHUB_TOKEN});
}
if(require.main===module)main().catch(()=>{console.error('Exact-source TEST prerequisite was not verified');process.exitCode=1;});
module.exports={selectGate,waitForTestGate};

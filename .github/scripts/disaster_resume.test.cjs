'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {fixture,verifyEvidence}=require('./disaster_resume.cjs');
const env={GITHUB_REPOSITORY:'cscticket01-hash/Saarthi_Ai',GITHUB_REF:'refs/heads/feature/smart-sync-3',GITHUB_RUN_ID:'4000',GITHUB_RUN_ATTEMPT:'1'};
const sha='a'.repeat(40),next='b'.repeat(40),run={id:123,name:'Isolated TEST cloud prerequisites',status:'completed',conclusion:'success',head_branch:'feature/smart-sync-3',head_repository:{full_name:env.GITHUB_REPOSITORY},head_sha:sha};
const compare={status:'ahead',merge_base_commit:{sha},files:[{filename:'.github/scripts/test_disaster_live.cjs'}]};
test('authorized resume preserves the original fixture and operation seed across hosted retries',()=>{
 const resumed={...env,VS_TEST_DISASTER_FIXTURE_RUN_ID:'38020985989',VS_TEST_DISASTER_FIXTURE_ATTEMPT:'2'};
 assert.equal(fixture(resumed).id,fixture({...resumed,GITHUB_RUN_ID:'9999',GITHUB_RUN_ATTEMPT:'3'}).id);assert.equal(fixture(resumed).resumed,true);
 assert.notEqual(fixture(env).id,fixture({...env,GITHUB_RUN_ATTEMPT:'2'}).id);
});
test('partial resume identities and foreign branch/repository fail closed',()=>{
 for(const bad of [{VS_TEST_DISASTER_FIXTURE_RUN_ID:'123'},{VS_TEST_DISASTER_FIXTURE_ATTEMPT:'2'},{GITHUB_REF:'refs/heads/main'},{GITHUB_REPOSITORY:'foreign/repo'},{VS_TEST_DISASTER_FIXTURE_RUN_ID:'../123',VS_TEST_DISASTER_FIXTURE_ATTEMPT:'2'}])assert.throws(()=>fixture({...env,...bad}));
});
test('successful same-code evidence accepts review-only changes without rerunning cloud writers',()=>{
 assert.equal(verifyEvidence(run,sha).sha,sha);assert.equal(verifyEvidence(run,next,compare).runId,123);
});
test('changed runtime, renamed runtime, truncated comparison and non-ancestor evidence fail closed',()=>{
 for(const files of [[{filename:'functions/managed-schools.js'}],[{filename:'.github/scripts/test_disaster_live.cjs',previous_filename:'lib/windows_sync_engine.dart'}],Array(300).fill(compare.files[0])])assert.throws(()=>verifyEvidence(run,next,{...compare,files}));
 assert.throws(()=>verifyEvidence(run,next,{...compare,merge_base_commit:{sha:next}}));
});
test('failed, running, foreign or wrong-branch cloud workflows cannot certify recovery',()=>{
 for(const bad of [{status:'in_progress'},{conclusion:'failure'},{head_branch:'main'},{head_repository:{full_name:'foreign/repo'}}])assert.throws(()=>verifyEvidence({...run,...bad},sha));
});

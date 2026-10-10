'use strict';
const assert=require('node:assert/strict');
const repo='cscticket01-hash/Saarthi_Ai';
const reviewOnly=new Set(['lib/windows_disaster_rehearsal.dart','test/windows_sync_revision_test.dart',
 '.github/scripts/test_disaster_live.cjs','.github/scripts/disaster_resume.cjs',
 '.github/scripts/disaster_resume.test.cjs','.github/workflows/disaster-test.yml']);
function fixture(env){
 assert.equal(env.GITHUB_REPOSITORY,repo);assert.equal(env.GITHUB_REF,'refs/heads/feature/smart-sync-3');
 const resumed=Boolean(env.VS_TEST_DISASTER_FIXTURE_RUN_ID||env.VS_TEST_DISASTER_FIXTURE_ATTEMPT);
 const run=resumed?env.VS_TEST_DISASTER_FIXTURE_RUN_ID:env.GITHUB_RUN_ID;
 const attempt=resumed?env.VS_TEST_DISASTER_FIXTURE_ATTEMPT:env.GITHUB_RUN_ATTEMPT;
 assert.match(run||'',/^[1-9][0-9]{0,19}$/);assert.match(attempt||'',/^[1-9][0-9]{0,5}$/);
 return {id:'disaster-rehearsal-'+run+'-'+attempt,resumed};
}
function verifyEvidence(run,currentSha,comparison){
 assert.equal(run.name,'Isolated TEST cloud prerequisites');assert.equal(run.status,'completed');assert.equal(run.conclusion,'success');
 assert.equal(run.head_branch,'feature/smart-sync-3');assert.equal(run.head_repository.full_name,repo);
 assert.match(run.head_sha,/^[a-f0-9]{40}$/);assert.match(currentSha,/^[a-f0-9]{40}$/);
 if(run.head_sha!==currentSha){
  assert.ok(comparison&&comparison.merge_base_commit.sha===run.head_sha);
  assert.equal(comparison.status,'ahead');assert.ok(Array.isArray(comparison.files)&&comparison.files.length>0&&comparison.files.length<300);
  assert.ok(comparison.files.every(file=>reviewOnly.has(file.filename)&&(!file.previous_filename||reviewOnly.has(file.previous_filename))));
 }
 return {runId:run.id,sha:run.head_sha};
}
module.exports={fixture,verifyEvidence};

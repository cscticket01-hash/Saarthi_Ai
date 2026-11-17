import {test} from 'node:test';
import assert from 'node:assert/strict';
import {r2StagingForSchool} from '../src/r2-scoped-admission.mjs';
const school='vs-'+'a'.repeat(32), other='vs-'+'b'.repeat(32);
test('production R2 cannot stage another school even with staging globally enabled',()=>{
 const env={R2_STAGING_ENABLED:'true',R2_STAGING_SCHOOLS:school};
 assert.equal(r2StagingForSchool(env,school),true);
 assert.equal(r2StagingForSchool(env,other),false);
 assert.equal(r2StagingForSchool({...env,R2_STAGING_ENABLED:'false'},school),false);
 assert.equal(r2StagingForSchool({...env,R2_STAGING_SCHOOLS:''},school),false);
 assert.equal(r2StagingForSchool({...env,R2_STAGING_SCHOOLS:'*'},school),false);
 assert.equal(r2StagingForSchool({...env,R2_STAGING_SCHOOLS:'*',R2_STAGING_ALL_SCHOOLS_ENABLED:'true'},other),true);
});
test('invalid or foreign school selectors always fail closed',()=>{
 for(const scope of ['vs-bad','*,'+school,school+',BAD',school+',vs-bad']) {
  assert.equal(r2StagingForSchool({R2_STAGING_ENABLED:'true',R2_STAGING_SCHOOLS:scope},school),false,scope);
 }
 assert.equal(r2StagingForSchool({R2_STAGING_ENABLED:'true',R2_STAGING_SCHOOLS:school},'wrong'),false);
});
test('pre-allowlist isolated TEST configuration remains compatible',()=>{
 assert.equal(r2StagingForSchool({R2_STAGING_ENABLED:'true'},school),false);
 assert.equal(r2StagingForSchool({R2_STAGING_ENABLED:'true',LIVE_SYNC_TEST_SCHOOL_ID:school},school),true);
 assert.equal(r2StagingForSchool({R2_STAGING_ENABLED:'true',LIVE_SYNC_TEST_SCHOOL_ID:school},other),false);
});

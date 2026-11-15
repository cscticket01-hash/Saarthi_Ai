'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {canRebaseFixedTestFixture}=require('./isolated_live_sync.cjs');
const schoolId='vs-db8afb01a3be46a983c8284714d06e5d';
const fixture=()=>({env:{GITHUB_ACTIONS:'true',GITHUB_REPOSITORY:'cscticket01-hash/Saarthi_Ai',VS_TEST_CONNECT_CONFIRM:schoolId,VS_TEST_REBASE_FIXED_FIXTURES:schoolId},schoolId,endpoint:'https://saarthi-sync-v2-test.onrender.com/school-cloud',collection:'school_calendar',id:'2026-11-15',day:'2026-11-15'});
test('owner-approved disposable TEST fixed fixture rebase is limited to exact calendar day and location',()=>{
 assert.equal(canRebaseFixedTestFixture(fixture()),true);
 const f=fixture();f.collection='school_settings';f.id='school_location';assert.equal(canRebaseFixedTestFixture(f),true);
});
test('production, foreign school, ordinary records and missing explicit TEST consent remain protected',()=>{
 for(const mutate of [f=>delete f.env.VS_TEST_REBASE_FIXED_FIXTURES,f=>f.env.GITHUB_ACTIONS='false',f=>f.schoolId='vs-'+'a'.repeat(32),f=>f.endpoint='https://saarthi-oauth-staging.onrender.com/school-cloud',f=>f.collection='students_directory',f=>f.collection='fee_payments',f=>f.id='another-day',f=>f.env.VS_TEST_CONNECT_CONFIRM='wrong']){
  const f=fixture();mutate(f);assert.equal(canRebaseFixedTestFixture(f),false);
 }
});

'use strict';
// These are static release-safety tests, never a Cloudflare deploy.
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'../..');
const load=file=>JSON.parse(fs.readFileSync(path.join(root,file),'utf8'));
const production=load('cloudflare-sync/wrangler.jsonc');
const standby=load('cloudflare-sync/wrangler.production-standby.jsonc');
const testWorker=load('cloudflare-sync/wrangler.test.jsonc');
test('production R2 standby uses a different private bucket, never TEST storage',()=>{
 assert.equal(production.name,'vidya-saarthi-sync');
 assert.equal(standby.name,production.name);
 assert.equal(testWorker.name,'vidya-saarthi-sync-test');
 assert.deepEqual(standby.r2_buckets,[{binding:'R2_STAGE',bucket_name:'saarthi-sync-r2-prod'}]);
 assert.notEqual(standby.r2_buckets[0].bucket_name,testWorker.r2_buckets[0].bucket_name);
 assert.equal(standby.vars.R2_STAGING_ENABLED,'false','no new R2 admissions before release gates');
 assert.equal(standby.vars.R2_STAGING_SCHOOLS,'','no school is admitted in production by default');
 assert.equal(standby.vars.R2_STAGING_ALL_SCHOOLS_ENABLED,'false','no bulk enable without separate provider proof');
 assert.notEqual(standby.vars.R2_STAGING_ENABLED,testWorker.vars.R2_STAGING_ENABLED);
});
test('R2 standby cannot quietly modify production broker, lane migration or original secrets',()=>{
 assert.equal(standby.vars.BROKER_URL,production.vars.BROKER_URL);
 assert.equal(standby.main,production.main);
 assert.deepEqual(standby.durable_objects,production.durable_objects);
 assert.deepEqual(standby.migrations,production.migrations);
 assert.deepEqual(standby.compatibility_flags,production.compatibility_flags);
 assert.deepEqual(standby.observability,production.observability);
 assert.equal(standby.vars.EDGE_KEY,undefined,'worker secrets are out of config');
 assert.equal(standby.vars.LIVE_SYNC_TEST_SCHOOL_ID,undefined);
 const only={...standby};delete only.r2_buckets;only.vars={...only.vars};delete only.vars.R2_STAGING_ENABLED;delete only.vars.R2_STAGING_SCHOOLS;delete only.vars.R2_STAGING_ALL_SCHOOLS_ENABLED;
 assert.deepEqual(only,production,'the standby must be additive and otherwise identical');
});
test('default production file still has no automatic R2 admission',()=>{
 assert.equal(production.r2_buckets,undefined);
 assert.notEqual(production.vars.R2_STAGING_ENABLED,'true');
});

const active=load('cloudflare-sync/wrangler.production-active.jsonc');
test('explicit production ACTIVE config reproduces verified live R2 admission without changing secrets or lanes',()=>{
 assert.equal(active.name,production.name);
 assert.equal(active.main,production.main);
 assert.deepEqual(active.compatibility_flags,production.compatibility_flags);
 assert.deepEqual(active.durable_objects,production.durable_objects);
 assert.deepEqual(active.migrations,production.migrations);
 assert.deepEqual(active.observability,production.observability);
 assert.equal(active.vars.BROKER_URL,production.vars.BROKER_URL);
 assert.deepEqual(active.r2_buckets,standby.r2_buckets);
 assert.equal(active.vars.R2_STAGING_ENABLED,'true');
 assert.equal(active.vars.R2_STAGING_ALL_SCHOOLS_ENABLED,'true');
 assert.equal(active.vars.R2_STAGING_SCHOOLS,'*');
 assert.equal(active.vars.EDGE_KEY,undefined);
 assert.equal(active.vars.LIVE_SYNC_TEST_SCHOOL_ID,undefined);
 assert.notEqual(active.r2_buckets[0].bucket_name,testWorker.r2_buckets[0].bucket_name);
});
test('active production R2 requires manual, reviewed deploy; default and standby remain fail-closed',()=>{
 assert.equal(production.r2_buckets,undefined);
 assert.equal(standby.vars.R2_STAGING_ENABLED,'false');
 assert.equal(active.name,standby.name);
 assert.notDeepEqual(active.vars,standby.vars);
});
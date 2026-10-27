'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { renew, validCredential, SCHOOL, OPERATION, DAYS } = require('../../.github/scripts/renew_sync3_test_licence.cjs');
function fixture() {
  const data = new Map([
    ['platform_schools/' + SCHOOL, { schoolId: SCHOOL, name: 'TEST Sync V2', managed: true, authUid: 'test-auth', blocked: false, trialStartedAt: 10, driveRootId: 'untouched-root', signingSecret: 'untouched-secret' }],
    ['school_entitlements/' + SCHOOL, { active: true, blocked: false, status: 'trial', startsAt: 10, expiresAt: 20, trialExpiresAt: 20 }],
    ['school_memberships/test-auth', { schoolId: SCHOOL, active: true, managed: true, role: 'school_admin' }],
    ['platform_schools/vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', { name: 'Real School', untouched: true }]
  ]);
  const writes = [];
  return { data, writes, doc: p => p, async runTransaction(fn) {
    const pending = [];
    const out = await fn({ get: async p => ({ exists: data.has(p), data: () => structuredClone(data.get(p)) }),
      create: (p,v) => { assert(!data.has(p)); pending.push([p,v,false]); },
      set: (p,v,o) => pending.push([p,v,o?.merge]) });
    for (const [p,v,merge] of pending) { data.set(p, merge ? {...data.get(p),...v} : v); writes.push(p); }
    return out;
  }};
}
const options = { now: () => 1000000, makeKey: () => 'VS-' + 'A'.repeat(32) };
test('TEST-only seven days issue+activation preserves trial, root, secrets and real schools', async () => {
  const db=fixture(), before=structuredClone(db.data.get('platform_schools/' + SCHOOL));
  const result=await renew(db,options), e=db.data.get('school_entitlements/'+SCHOOL);
  assert.deepEqual(result,{renewed:true,expiresAt:1000000+DAYS});
  assert.equal(e.activated,true); assert.equal(e.status,'licensed');assert.equal(e.trialExpiresAt,20);
  assert.equal(e.sync3TestRenewal20261026.operation,OPERATION);
  for(const k of ['trialStartedAt','driveRootId','signingSecret'])assert.equal(db.data.get('platform_schools/'+SCHOOL)[k],before[k]);
  assert.deepEqual(db.data.get('platform_schools/vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'),{name:'Real School',untouched:true});
  assert.equal(db.writes.length,4); assert(db.writes.every(p=>p.endsWith(SCHOOL)||p.startsWith('platform_license')));
  assert(!JSON.stringify([...db.data]).includes(options.makeKey()));
});
test('rerun is idempotent and never extends expiry', async () => {
  const db=fixture();const first=await renew(db,options);db.writes.length=0;
  const next=await renew(db,{...options,now:()=>1000000+2*DAYS,makeKey:()=> 'VS-'+'B'.repeat(32)});
  assert.deepEqual(next,{renewed:false,expiresAt:first.expiresAt});assert.equal(db.writes.length,0);
});
test('foreign name, membership, disabled account and active licence all fail without writes', async () => {
  for(const mutate of [db=>db.data.get('platform_schools/'+SCHOOL).name='Other School',db=>db.data.get('school_memberships/test-auth').schoolId='vs-foreign',db=>db.data.get('school_entitlements/'+SCHOOL).blocked=true,db=>db.data.get('school_entitlements/'+SCHOOL).expiresAt=2000000]){
    const db=fixture();mutate(db);await assert.rejects(renew(db,options));assert.equal(db.writes.length,0);
  }
});
test('changed renewal marker cannot silently renew again',async()=>{
  const db=fixture();await renew(db,options);db.writes.length=0;db.data.get('school_entitlements/'+SCHOOL).licenseHash='changed';
  await assert.rejects(renew(db,options));assert.equal(db.writes.length,0);
});
test('credential is fixed to one project and service-account type',()=>{
  assert.throws(()=>validCredential('{}'));assert.throws(()=>validCredential(JSON.stringify({project_id:'other',type:'service_account'})));
  assert.equal(validCredential(JSON.stringify({project_id:'saarthi-ai-df12b',type:'service_account'})).project_id,'saarthi-ai-df12b');
});

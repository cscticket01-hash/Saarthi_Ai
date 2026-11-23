'use strict';

const {test} = require('node:test');
const assert = require('node:assert/strict');
const {createSchoolAdminSecurity} = require('../school-admin-security');

function memoryDatabase() {
  const values = new Map(), audits = [];
  const snapshot = path => ({
    exists:values.has(path),
    data:()=>values.get(path) && {...values.get(path)}
  });
  const doc = path => ({
    get:async()=>snapshot(path),
    set:async(data,{merge}={})=>{
      values.set(path,merge?{...values.get(path),...data}:{...data});
    },
    update:async(data)=>{
      if(!values.has(path))throw Error('missing update target');
      values.set(path,{...values.get(path),...data});
    },
    create:async(data)=>{
      if(values.has(path))throw Error('duplicate grant');
      values.set(path,{...data});
    }
  });
  return {
    audits,
    doc,
    collection:name=>({
      add:async data=>{audits.push({collection:name,...data});return {id:'audit-'+audits.length}}
    }),
    runTransaction:async work=>work({
      get:async ref=>ref.get(),
      set:(ref,data)=>{ref.set(data);},
      update:(ref,data)=>{ref.update(data);}
    }),
  };
}

const proof='fresh-id-token-'.repeat(9);
const school={schoolId:'vs-'+'a'.repeat(32),uid:'owner-123'};
const password='HorseRiverClock-37!';
function harness() {
  const db=memoryDatabase();
  let clock=1764000000000;
  const auth={verifyIdToken:async(raw)=>{
    if(raw!==proof)throw Error('invalid fresh login');
    return {uid:school.uid,auth_time:Math.floor(clock/1000)};
  }};
  const admin=createSchoolAdminSecurity({db,auth,now:()=>clock});
  return {db,admin,advance:ms=>{clock+=ms;}};
}

test('school admin enrolls once, can unlock, and never returns password hash',async()=>{
  const {admin}=harness();
  assert.equal((await admin.handle({operation:'status'},school)).configured,false);
  await admin.handle({operation:'enroll',freshIdToken:proof,newPassword:password},school);
  const status=await admin.handle({operation:'status'},school);
  assert.equal(status.configured,true);
  assert.equal(Object.hasOwn(status,'passwordHash'),false);
  const unlocked=await admin.handle({operation:'unlock',password},school);
  assert.equal(unlocked.scope,'admin-panel');
  await assert.rejects(admin.handle({operation:'enroll',freshIdToken:proof,newPassword:password},school),/configured/);
});

test('grants are school-scoped, target-scoped and single-use',async()=>{
  const {admin,db}=harness();
  await admin.handle({operation:'enroll',freshIdToken:proof,newPassword:password},school);
  const grant=await admin.handle({
    operation:'authorize',password,scope:'person-delete',
    target:'students_directory/Student_1'
  },school);
  assert.match(grant.approvalToken,/^[a-f0-9]{64}$/);
  await assert.rejects(admin.handle({
    operation:'consume',approvalToken:grant.approvalToken,
    scope:'person-delete',target:'students_directory/Student_2'
  },school),/does not match/);
  const consumed=await admin.handle({
    operation:'consume',approvalToken:grant.approvalToken,
    scope:'person-delete',target:'students_directory/Student_1'
  },school);
  assert.equal(consumed.authorized,true);
  await assert.rejects(admin.handle({
    operation:'consume',approvalToken:grant.approvalToken,
    scope:'person-delete',target:'students_directory/Student_1'
  },school),/expired or does not match/);
  assert.ok(db.audits.some(a=>a.action==='school_admin_action_consumed'));
});

test('expired grant and a password change invalidate previous authorization',async()=>{
  const {admin,advance}=harness();
  await admin.handle({operation:'enroll',freshIdToken:proof,newPassword:password},school);
  const grant=await admin.handle({operation:'authorize',password,
    scope:'force-promotion',target:'Student_1/exam_final'},school);
  advance(121000);
  await assert.rejects(admin.handle({operation:'consume',
    approvalToken:grant.approvalToken,scope:'force-promotion',
    target:'Student_1/exam_final'},school),/expired/);
  const fresh=await admin.handle({operation:'authorize',password,
    scope:'force-promotion',target:'Student_1/exam_final'},school);
  await admin.handle({operation:'change',password,newPassword:'NewAdminPassword-99!'},school);
  await assert.rejects(admin.handle({operation:'consume',
    approvalToken:fresh.approvalToken,scope:'force-promotion',
    target:'Student_1/exam_final'},school),/expired or does not match/);
});

test('five bad passwords temporarily block unlock',async()=>{
  const {admin,advance}=harness();
  await admin.handle({operation:'enroll',freshIdToken:proof,newPassword:password},school);
  for(let n=0;n<5;n++){
    await assert.rejects(admin.handle({operation:'unlock',password:'wrong-password'},school));
  }
  await assert.rejects(admin.handle({operation:'unlock',password},school),/temporarily locked/);
  advance(15*60*1000+1);
  assert.equal((await admin.handle({operation:'unlock',password},school)).verified,true);
});

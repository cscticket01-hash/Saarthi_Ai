'use strict';

const {test} = require('node:test');
const assert = require('node:assert/strict');
const {createSchoolAdminSecurity} = require('../school-admin-security');

function memoryDatabase() {
  let values = new Map(), failAudit = false;
  const snapshot = path => ({
    exists:values.has(path),
    data:()=>values.get(path) && {...values.get(path)}
  });
  const doc = path => ({path,get:async()=>snapshot(path)});
  return {
    get audits(){return [...values.entries()].filter(([key])=>key.startsWith('platform_audit/')).map(([,value])=>value);},
    rejectNextAudit(){failAudit=true;},
    doc,
    runTransaction:async work=>{
      const next=new Map(values);
      const write=(ref,data,mode)=>{
        if(ref.path.startsWith('platform_audit/')&&failAudit){
          failAudit=false;
          throw Error('synthetic audit failure');
        }
        if(mode==='update'&&!next.has(ref.path))throw Error('missing update target');
        if(mode==='create'&&next.has(ref.path))throw Error('duplicate grant');
        next.set(ref.path,mode==='update'?{...next.get(ref.path),...data}:{...data});
      };
      const result=await work({
        get:async ref=>ref.get(),
        set:(ref,data)=>write(ref,data,'set'),
        update:(ref,data)=>write(ref,data,'update'),
        create:(ref,data)=>write(ref,data,'create')
      });
      values=next;
      return result;
    }
  };
}

const proof='fresh-id-token-'.repeat(9);
const school={schoolId:'vs-'+'a'.repeat(32),uid:'owner-123'};
const password='River-37';
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
  await admin.handle({operation:'enroll',newPassword:password},school);
  const status=await admin.handle({operation:'status'},school);
  assert.equal(status.configured,true);
  assert.equal(Object.hasOwn(status,'passwordHash'),false);
  const unlocked=await admin.handle({operation:'unlock',password},school);
  assert.equal(unlocked.scope,'admin-panel');
  await assert.rejects(admin.handle({operation:'enroll',newPassword:password},school),/configured/);
});

test('grants are school-scoped, target-scoped and single-use',async()=>{
  const {admin,db}=harness();
  await admin.handle({operation:'enroll',newPassword:password},school);
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
  await admin.handle({operation:'enroll',newPassword:password},school);
  const grant=await admin.handle({operation:'authorize',password,
    scope:'force-promotion',target:'Student_1/exam_final'},school);
  advance(121000);
  await assert.rejects(admin.handle({operation:'consume',
    approvalToken:grant.approvalToken,scope:'force-promotion',
    target:'Student_1/exam_final'},school),/expired/);
  const fresh=await admin.handle({operation:'authorize',password,
    scope:'force-promotion',target:'Student_1/exam_final'},school);
  await admin.handle({operation:'change',password,newPassword:'NewPass99'},school);
  await assert.rejects(admin.handle({operation:'consume',
    approvalToken:fresh.approvalToken,scope:'force-promotion',
    target:'Student_1/exam_final'},school),/expired or does not match/);
});

test('five bad passwords temporarily block unlock',async()=>{
  const {admin,advance}=harness();
  await admin.handle({operation:'enroll',newPassword:password},school);
  for(let n=0;n<5;n++){
    await assert.rejects(admin.handle({operation:'unlock',password:'wrong-password'},school));
  }
  await assert.rejects(admin.handle({operation:'unlock',password},school),/temporarily locked/);
  advance(15*60*1000+1);
  assert.equal((await admin.handle({operation:'unlock',password},school)).verified,true);
});

test('failed audit writes cannot partially commit credentials or consume approval',async()=>{
  const {admin,db}=harness();
  db.rejectNextAudit();
  await assert.rejects(admin.handle({operation:'enroll',newPassword:password},school),/synthetic audit failure/);
  assert.equal((await admin.handle({operation:'status'},school)).configured,false);
  await admin.handle({operation:'enroll',newPassword:password},school);
  db.rejectNextAudit();
  await assert.rejects(admin.handle({operation:'change',password,newPassword:'NewPass99'},school),/synthetic audit failure/);
  assert.equal((await admin.handle({operation:'unlock',password},school)).verified,true);
  const target='students_directory/Student_1';
  const request={operation:'authorize',password,scope:'person-delete',target};
  db.rejectNextAudit();
  await assert.rejects(admin.handle(request,school),/synthetic audit failure/);
  const grant=await admin.handle(request,school);
  const consume={operation:'consume',approvalToken:grant.approvalToken,scope:'person-delete',target};
  db.rejectNextAudit();
  await assert.rejects(admin.handle(consume,school),/synthetic audit failure/);
  assert.equal((await admin.handle(consume,school)).authorized,true);
  assert.equal(db.audits.filter(a=>a.action==='school_admin_action_consumed').length,1);
});

test('durable delete approval preserves exact original retry but rejects changed generation, revision, payload or actor',async()=>{
  const {admin,advance,db}=harness();
  await admin.handle({operation:'enroll',newPassword:password},school);
  const intent={scope:'person-delete',collection:'students_directory',id:'Student_1',
    operationId:'delete-original-00001',recordRevision:'live-original',
    generation:'p-'+'a'.repeat(64),payloadHash:'a'.repeat(64)};
  const grant=await admin.handle({operation:'authorize',password,scope:intent.scope,
    target:'students_directory/Student_1'},school);
  const request={operation:'bind-mutation',approvalToken:grant.approvalToken,intent};
  db.rejectNextAudit();
  await assert.rejects(admin.handle(request,school),/synthetic audit failure/);
  await assert.rejects(admin.assertMutationApproval(school,intent),/Original Admin Password/);
  await admin.handle(request,school);
  advance(121000);
  assert.equal((await admin.handle(request,school)).authorized,true);
  assert.equal((await admin.assertMutationApproval(school,intent)).authorized,true);
  for(const changed of [{recordRevision:'new-revision'},{generation:'p-'+'b'.repeat(64)},
    {payloadHash:'b'.repeat(64)},{operationId:'delete-original-00002'}]){
    await assert.rejects(admin.assertMutationApproval(school,{...intent,...changed}));
    await assert.rejects(admin.handle({...request,intent:{...intent,...changed}},school));
  }
  await assert.rejects(admin.assertMutationApproval({...school,uid:'different-user'},intent));
  await assert.rejects(admin.assertMutationApproval({...school,schoolId:'vs-'+'b'.repeat(32)},intent));
  assert.equal(db.audits.filter(a=>a.action==='school_admin_mutation_bound').length,1);
});

test('force promotion binding requires exact exam and result revisions',async()=>{
  const {admin}=harness();
  await admin.handle({operation:'enroll',newPassword:password},school);
  const intent={scope:'force-promotion',collection:'students_directory',id:'Student_1',
    operationId:'promotion-original-001',recordRevision:'live-student',
    generation:'p-'+'a'.repeat(64),payloadHash:'c'.repeat(64),examId:'exam_final',
    examRevision:'live-exam',resultRevision:'live-result'};
  const grant=await admin.handle({operation:'authorize',password,scope:intent.scope,
    target:'Student_1/exam_final'},school);
  await assert.rejects(admin.handle({operation:'bind-mutation',approvalToken:grant.approvalToken,
    intent:{...intent,resultRevision:''}},school));
  await admin.handle({operation:'bind-mutation',approvalToken:grant.approvalToken,intent},school);
  assert.equal((await admin.assertMutationApproval(school,intent)).authorized,true);
  await assert.rejects(admin.assertMutationApproval(school,{...intent,resultRevision:'changed'}));
  await assert.rejects(admin.assertMutationApproval(school,{...intent,examRevision:'changed'}));
  await assert.rejects(admin.assertMutationApproval(school,{...intent,examId:'another-exam'}));
});

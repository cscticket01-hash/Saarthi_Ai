'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {createHash}=require('node:crypto');
const {createManagedCardIssueAuthority}=require('../managed-card-issue-authority');
const school='vs-'+'a'.repeat(32), other='vs-'+'b'.repeat(32);
const hash=v=>createHash('sha256').update(v).digest('hex');
function mockFirestore(){
 const docs=new Map();
 const ref=path=>({path,async get(){return {
  exists:docs.has(path),data:()=>structuredClone(docs.get(path)),
 };}});
 return {docs,doc:ref,async runTransaction(fn){
  const writes=[];
  const tx={
   get:(r)=>r.get(),
   set:(r,data)=>writes.push({type:'set',path:r.path,data}),
   create:(r,data)=>writes.push({type:'create',path:r.path,data}),
  };
  const result=await fn(tx);
  for(const w of writes){
   if(w.type==='create'&&docs.has(w.path))throw Error('duplicate event');
   docs.set(w.path,structuredClone(w.data));
  }
  return result;
 }};
}
const base={role:'student',personId:'p-0001',schoolId:school};
const actor={schoolId:school,uid:'verified-admin'};
const person={schoolId:school,mobileStableId:'p-0001',
 mobileLinkToken:'real-school-qr-token-0123456789'};
const asSchool=async()=>person;

test('server controls exact issue, verify, revoke and reissue with replay safety',async()=>{
 const db=mockFirestore(),clock=()=>1781200000000;
 const manage=createManagedCardIssueAuthority({db,now:clock});
 const issue={...base,operation:'issue',operationId:'new-card-operation-0001',
  expiresAt:clock()+86400000};
 const first=await manage({request:issue,identity:actor,readPerson:asSchool});
 assert.equal(first.issued,true);assert.equal(first.state,'active');
 const repeat=await manage({request:issue,identity:actor,readPerson:asSchool});
 assert.deepEqual(repeat,first);
 const qrHash=hash('student/p-0001/'+person.mobileLinkToken);
 const verify={...base,operation:'verify',cardIssueId:first.currentIssueId,qrHash};
 assert.equal((await manage({request:verify,identity:actor})).valid,true);
 assert.equal((await manage({request:{...verify,qrHash:'0'.repeat(64)},
  identity:actor})).valid,false);
 await assert.rejects(manage({request:{...issue,expiresAt:clock()+999999999},
  identity:actor,readPerson:asSchool}),{status:409});
 await assert.rejects(manage({request:{...issue,operationId:'different-operation-0002'},
  identity:actor,readPerson:asSchool}),{status:409});
 const revoke={...base,operation:'revoke',operationId:'revoke-card-operation-0001',
  cardIssueId:first.currentIssueId};
 const stopped=await manage({request:revoke,identity:actor,readPerson:asSchool});
 assert.equal(stopped.revoked,true);
 assert.equal((await manage({request:verify,identity:actor})).valid,false);
 assert.deepEqual(await manage({request:revoke,identity:actor,readPerson:asSchool}),stopped);
 const renewed=await manage({request:{...base,operation:'reissue',
  operationId:'reissue-card-operation-0001',
  cardIssueId:first.currentIssueId,expiresAt:clock()+2*86400000},
  identity:actor,readPerson:asSchool});
 assert.equal(renewed.state,'active');
 assert.notEqual(renewed.currentIssueId,first.currentIssueId);
 assert.equal((await manage({request:verify,identity:actor})).valid,false);
});

test('forged school identity, absent person and expired licences do not become authority',async()=>{
 const db=mockFirestore(),manage=createManagedCardIssueAuthority({db,now:()=>1781200000000});
 const request={...base,operation:'issue',operationId:'new-card-operation-0001',
  expiresAt:1781200000000+86400000};
 await assert.rejects(manage({request,identity:{...actor,schoolId:other},
  readPerson:asSchool}),{status:403});
 await assert.rejects(manage({request,identity:actor,
  readPerson:async()=>({...person,schoolId:other})}),{status:409});
 await assert.rejects(manage({request,identity:actor,readPerson:async()=>null}),{status:409});
 assert.equal(db.docs.size,0);
});

test('invalid expiry, replay variation, caller actor and revocation state fail closed',async()=>{
 const db=mockFirestore(),now=()=>1781200000000;
 const manage=createManagedCardIssueAuthority({db,now});
 const request={...base,operation:'issue',operationId:'new-card-operation-0001',
  expiresAt:now()+86400000};
 await assert.rejects(manage({request:{...request,expiresAt:now()-10},
  identity:actor,readPerson:asSchool}),{status:400});
 const first=await manage({request,identity:actor,readPerson:asSchool});
 await assert.rejects(manage({request,identity:{...actor,uid:'new-admin'},
  readPerson:asSchool}),{status:409});
 await assert.rejects(manage({request:{...base,operation:'revoke',
  operationId:'wrong-card-operation-001',cardIssueId:'0'.repeat(64)},
  identity:actor,readPerson:asSchool}),{status:409});
 assert.equal((await manage({request:{...base,operation:'status'},
  identity:actor})).currentIssueId,first.currentIssueId);
});

test('foreign registry contents are never returned as a valid school card',async()=>{
 const db=mockFirestore(),manage=createManagedCardIssueAuthority({db});
 const key=hash(JSON.stringify([school,'student','p-0001']));
 db.docs.set('school_card_issue_registry/'+key,{
  schoolId:other,role:'student',personId:'p-0001',
  state:'active',currentIssueId:'a'.repeat(64),expiresAt:Date.now()+100000,
 });
 await assert.rejects(manage({request:{...base,operation:'status'},identity:actor}),
  {status:403});
});

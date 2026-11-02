'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createLiveDomainDelivery,deliveryId,domainFor,scrubDomainReceipt,hydrateDomainReceipt,domainPayloadHash}=require('../live-domain-delivery');
const school='vs-'+'a'.repeat(32),other='vs-'+'b'.repeat(32);
const request=(collection='fee_payments')=>({action:'managed_records',collection,operation:'write',syncProtocol:2,id:'payment-one',operationId:'payment-operation-0001',expectedRecordRevision:'drive-before',data:{schoolId:school,amount:100,studentId:'generation-one'}});
const record=r=>({...r.data,id:r.id,_syncRevision:'drive-after',_syncOperationId:r.operationId,_syncFieldRevisions:{amount:'drive-after'}});
const result=r=>({success:true,schoolId:school,syncProtocol:2,recordRevision:'drive-after',record:record(r)});
const point=r=>async body=>{assert.equal(body.collection,r.collection);assert.equal(body.id,r.id);return {success:true,schoolId:school,syncProtocol:2,pointRead:true,records:{[r.id]:record(r)}};};
test('hazardous domains reuse immutable GS delivery, retain exact CAS, and emit metadata-only pending hints',async()=>{
 for(const collection of ['fee_payments','fee_ledger','teacher_salary','fee_settings','attendance_records','attendance_logs','teacher_attendance','teacher_schedules','exams','exam_results','exam_center_results']){
  const r=request(collection),hints=[],calls=[];
  const adapter=createLiveDomainDelivery({edgeDelivery:{record:async(s,body)=>{calls.push(body);return {success:true,schoolId:s,edgeDeliveryVersion:1,driveState:'pending',delivery:{lane:'records',id:deliveryId(s,body)}};}},emitHint:async(s,h)=>hints.push(h)});
  const reply=await adapter.submit(school,r);assert.equal(reply.driveState,'pending');assert.equal(reply.recordRevision,undefined);assert.equal(reply.syncProtocol,undefined);assert.equal(calls[0],r);assert.equal(calls[0].expectedRecordRevision,'drive-before');assert.equal(hints[0].domain,domainFor(collection));assert.equal(hints[0].data,undefined);assert.equal(hints[0].amount,undefined);
 }
});
test('pending cross-device proposal never becomes canonical financial or attendance data',async()=>{
 const r=request(),id=deliveryId(school,r),adapter=createLiveDomainDelivery({edge:{rpc:async(s,l,b)=>{assert.equal(s,school);assert.equal(l,'records');assert.deepEqual(b,{command:'projection',id});return {id,state:'pending',request:r};}}});
 const proposal=await adapter.projection(school,{lane:'records',id});assert.equal(proposal.authoritative,false);assert.equal(proposal.disposition,'pending');assert.equal(proposal.record,undefined);assert.equal(proposal.recordRevision,undefined);assert.equal(proposal.proposal.expectedRecordRevision,'drive-before');assert.equal(proposal.proposal.data.amount,100);
});
test('domain adapter rejects unknown collections, foreign requests and fake queued acknowledgements',async()=>{
 const adapter=createLiveDomainDelivery({edgeDelivery:{record:async()=>{throw Error('must not stage');}}});
 for(const r of [request('students_directory'),request('documents'),request('school_notices'),{...request(),expectedRecordRevision:'live-synthetic'},{...request(),data:{schoolId:other}}])await assert.rejects(adapter.submit(school,r),e=>[400,403].includes(e.status));
 const fake=createLiveDomainDelivery({edgeDelivery:{record:async()=>({success:true,schoolId:school,driveState:'pending',edgeDeliveryVersion:1,recordRevision:'fake-ACK',delivery:{lane:'records',id:'a'.repeat(64)}})}});
 await assert.rejects(fake.submit(school,request()),e=>e.code==='DOMAIN_RECEIPT_UNVERIFIED');
});
test('exact canonical Drive proof produces only a source marker and hydrates after payload deletion',async()=>{
 const r=request(),receipt=scrubDomainReceipt(school,result(r),r);
 assert.equal(receipt.record,null);assert.equal(receipt.recordSource.payloadHash,domainPayloadHash(record(r)));assert.equal(receipt.recordSource.collection,r.collection);assert.equal(JSON.stringify(receipt).includes('generation-one'),false);assert.equal(JSON.stringify(receipt).includes('amount'),false);
 const restored=await hydrateDomainReceipt(school,receipt,point(r));assert.deepEqual(restored.record,record(r));assert.equal(restored.record._syncOperationId,r.operationId);
 assert.equal(await hydrateDomainReceipt(school,restored,async()=>{throw Error('already hydrated receipt must not read Drive twice');}),restored);
 await assert.rejects(hydrateDomainReceipt(school,{...restored,record:{...restored.record,amount:999}}),e=>e.code==='DOMAIN_CANONICAL_UNVERIFIED');
 const optionalWrapper={...record(r)};delete optionalWrapper.id;assert.equal(domainPayloadHash(optionalWrapper),receipt.recordSource.payloadHash);
});
test('fake canonical receipt or changed Drive content cannot trigger purge or hydration',async()=>{
 const r=request();
 for(const change of [{schoolId:other},{_syncOperationId:'other-operation'},{_syncRevision:'other-revision'},{_syncDeleted:true},{id:'another-payment'}])await assert.rejects(async()=>scrubDomainReceipt(school,{...result(r),record:{...record(r),...change}},r),e=>e.code==='DOMAIN_CANONICAL_UNVERIFIED');
 assert.throws(()=>scrubDomainReceipt(school,{...result(r),recordRevision:'live-fake'},r),e=>e.code==='DOMAIN_CANONICAL_UNVERIFIED');
 const receipt=scrubDomainReceipt(school,result(r),r);
 const mutate=changes=>async()=>({success:true,schoolId:school,syncProtocol:2,pointRead:true,records:{[r.id]:{...record(r),...changes}}});
 await assert.rejects(hydrateDomainReceipt(school,receipt,mutate({amount:999})),e=>e.code==='DOMAIN_CANONICAL_UNVERIFIED');
 await assert.rejects(hydrateDomainReceipt(school,receipt,mutate({_syncRevision:'newer'})),e=>e.code==='RECORD_REVISION_CONFLICT');
 await assert.rejects(hydrateDomainReceipt(school,receipt,mutate({_syncOperationId:'newer-operation'})),e=>e.code==='RECORD_REVISION_CONFLICT');
 await assert.rejects(hydrateDomainReceipt(other,receipt,point(r)),e=>e.code==='DOMAIN_SOURCE_UNVERIFIED');
});
test('completed projections hydrate source metadata and review jobs never expose a canonical record',async()=>{
 const r=request(),id=deliveryId(school,r),receipt={...scrubDomainReceipt(school,result(r),r),driveState:'verified'},identity={...r};delete identity.data;
 let state='completed';const adapter=createLiveDomainDelivery({edge:{rpc:async()=>({id,state,identity})},edgeDelivery:{status:async()=>receipt}});
 const verified=await adapter.projection(school,{lane:'records',id},point(r));assert.equal(verified.authoritative,true);assert.equal(verified.disposition,'verified');assert.equal(verified.record.amount,100);
 state='needsAttention';const review=await adapter.projection(school,{lane:'records',id});assert.equal(review.authoritative,false);assert.equal(review.record,undefined);assert.equal(review.proposal,null);
});
test('projection identity cannot be retargeted to another receipt or school',async()=>{
 const r=request(),id=deliveryId(school,r),adapter=createLiveDomainDelivery({edge:{rpc:async()=>({id,state:'pending',request:{...r,id:'other'}})}});
 await assert.rejects(adapter.projection(school,{lane:'records',id}),e=>e.code==='DOMAIN_PROJECTION_UNVERIFIED');
 await assert.rejects(adapter.projection(other,{lane:'records',id}),e=>e.code==='DOMAIN_SCHOOL_MISMATCH');
});
test('deletion proof keeps tombstone intent and optional wakeup failure does not lose staged work',async()=>{
 const r={...request(),operation:'delete'};delete r.data;
 const tombstone={schoolId:school,_syncDeleted:true,_syncRevision:'drive-deleted',_syncOperationId:r.operationId};
 const receipt=scrubDomainReceipt(school,{success:true,schoolId:school,syncProtocol:2,recordRevision:'drive-deleted',record:tombstone},r);assert.equal(receipt.record,null);
 const pending={success:true,schoolId:school,edgeDeliveryVersion:1,driveState:'pending',delivery:{lane:'records',id:deliveryId(school,r)}};
 const adapter=createLiveDomainDelivery({edgeDelivery:{record:async()=>pending},emitHint:async()=>{throw Error('hint down');}});assert.equal(await adapter.submit(school,r),pending);
});

test('retired explicit student generation cannot stage fee, attendance, or exam proposals after offline reconnect',async()=>{
 const generation='p-'+'b'.repeat(32),studentId='Class 1_Roll_1';
 for(const collection of ['fee_payments','fee_ledger','attendance_records','attendance_logs','exam_results','exam_center_results']){
  const r={...request(collection),data:{...request(collection).data,personId:generation,studentDocId:studentId}};
  let checked=0,staged=0;
  const adapter=createLiveDomainDelivery({
   assertStudentDependency:async(s,id,g)=>{checked++;assert.equal(s,school);assert.equal(id,studentId);assert.equal(g,generation);throw Object.assign(Error('Parent generation retired'),{code:'PERSON_GENERATION_RETIRED',status:409});},
   edgeDelivery:{record:async()=>{staged++;throw Error('stale student child must not enter edge queue');}},
  });
  await assert.rejects(adapter.submit(school,r),e=>e.code==='PERSON_GENERATION_RETIRED',collection);
  assert.equal(checked,1,collection);assert.equal(staged,0,collection);
 }
});

test('generation fence admits only validated current student writes and never blocks their explicit cleanup',async()=>{
 const generation='p-'+'c'.repeat(32),studentId='Class 1_Roll_5';
 const r={...request('fee_payments'),data:{...request().data,personId:generation,studentId}};
 let checks=0,staged=0;
 const pending=body=>({success:true,schoolId:school,driveState:'pending',edgeDeliveryVersion:1,delivery:{lane:'records',id:deliveryId(school,body)}});
 const adapter=createLiveDomainDelivery({
  assertStudentDependency:async(s,id,g)=>{checks++;assert.equal(id,studentId);assert.equal(g,generation);},
  edgeDelivery:{record:async(s,body)=>{staged++;return pending(body);}},
 });
 assert.equal((await adapter.submit(school,r)).driveState,'pending');
 assert.equal(checks,1);assert.equal(staged,1);
 const deletion={...r,operation:'delete',operationId:'student-child-delete-0001'};delete deletion.data;
 assert.equal((await adapter.submit(school,deletion)).driveState,'pending');
 assert.equal(checks,1,'tombstone cleanup must remain available after parent retirement');
 assert.equal(staged,2);
 const noVerifier=createLiveDomainDelivery({edgeDelivery:{record:async()=>{throw Error('Must not enqueue without a verified parent');}}});
 await assert.rejects(noVerifier.submit(school,r),e=>e.code==='DOMAIN_STUDENT_DEPENDENCY_UNVERIFIED');
 const teacher={...r,collection:'teacher_salary',data:{...r.data,role:'teacher'}};
 const existing=createLiveDomainDelivery({edgeDelivery:{record:async(s,body)=>pending(body)}});
 assert.equal((await existing.submit(school,teacher)).driveState,'pending','teacher salary retains independent GS owner');
});

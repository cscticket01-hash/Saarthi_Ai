'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {fixture,validatePerson,verifyDeletedLogin,SCHOOL,SHA}=require('./resume_failed_delete_artifact.cjs');
function source(){
 const student='TEST_DELETE_42999713169_00000000',documentId='TEST_DELETE_CARD_42999713169_00000000',feeId='TEST_DELETE_FEE_42999713169_00000000',fileId='synthetic-unit-file';
 return {schoolId:SCHOOL,sourceCommit:SHA,verifiedRuntime:SHA,status:'FAIL',realProviderCalls:true,syntheticDeleted:false,
 checks:['actual Google Drive original PDF byte SHA-256','Website API delta sees student and document before delete','actual Android mobile protocol can authenticate synthetic student','Android mobile protocol gets original TEST PDF before delete'].map(name=>({name,status:'PASS'})),
 fixtureIds:{student,documentId,feeId,fileId},reviewRequired:{student,documentId,feeId,fileId,deleteOperationId:'d'.repeat(32),originalParentRevision:'original-revision-0001'}};
}
test('only the fixed failed run namespace and immutable linked identities are admitted',()=>{
 const r=source(),f=fixture(r);assert.equal(f.student,r.fixtureIds.student);assert.ok(Object.isFrozen(f));
 for(const alter of [
  r=>r.schoolId='vs-'+'b'.repeat(32),r=>r.sourceCommit='0'.repeat(40),
  r=>r.reviewRequired.student='existing-user-record',r=>r.reviewRequired.documentId='other-document',
  r=>r.reviewRequired.deleteOperationId=null,r=>r.fixtureIds.fileId='changed-file',
  r=>r.checks.pop()
 ]){const r=source();alter(r);assert.throws(()=>fixture(r));}
});
test('a live original requires its exact generation and original revision',()=>{
 const f=fixture(source()),row={schoolId:SCHOOL,syntheticTest:true,mobileStableId:f.generation,_syncRevision:f.originalRevision};
 validatePerson(row,f);
 for(const change of [{syntheticTest:false},{mobileStableId:'new-generation'},{_syncRevision:'new-revision'}])assert.throws(()=>validatePerson({...row,...change},f));
});
test('a retained tombstone must bind original targets, generation, source revision and sole PDF',()=>{
 const f=fixture(source()),row={schoolId:SCHOOL,_syncDeleted:true,_syncOperationId:f.operationId,_syncDeletedOwner:f.generation,_syncRevision:'deleted-revision',
 _syncErasePlan:{version:1,targets:[{collection:'students_directory',id:f.student,generation:f.generation,sourceRevision:f.originalRevision,revision:'deleted-revision'},
 {collection:'documents',id:f.documentId},{collection:'fee_payments',id:f.feeId}],files:[f.fileId]}};
 validatePerson(row,f);
 for(const change of [{_syncOperationId:'other-operation'},{_syncDeletedOwner:'other-generation'},{_syncErasePlan:{...row._syncErasePlan,files:['other-file']}}])
  assert.throws(()=>validatePerson({...row,...change},f));
});

test('deleted mobile login proof uses the original public protocol without a bearer token',async()=>{
 const f=fixture(source());let args;
 await verifyDeletedLogin(async(...input)=>{args=input;return {http:403,data:{success:false}};},f);
 assert.equal(args.length,2);assert.equal(args[1].action,'managed/mobile');
 assert.equal(args[1].request.action,'mobile_login');assert.equal(args[1].request.personId,f.generation);
});
test('unavailability, malformed denial or successful login cannot become deletion proof',async()=>{
 const f=fixture(source());
 for(const reply of [{http:503,data:{success:false}},{http:401,data:{success:false}},{http:403,data:{}},
  {http:200,data:{success:true,sessionToken:'synthetic'}},{http:403,data:{success:false,sessionToken:'synthetic'}}])
  await assert.rejects(verifyDeletedLogin(async()=>reply,f),e=>e.code==='MOBILE_DELETE_DENIAL_UNVERIFIED');
});

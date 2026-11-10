'use strict';
const assert=require('node:assert/strict'),{createHash}=require('node:crypto');
const fixture={schoolId:'vs-db8afb01a3be46a983c8284714d06e5d',
 student:'TEST_DELETE_42842637312_acb196df',documentId:'TEST_DELETE_CARD_42842637312_acb196df',
 feeId:'TEST_DELETE_FEE_42842637312_acb196df',fileId:'1013JLSwStOsGTcP0QDDS-ZcRukmY0bLa',
 operationId:'387ff6d3762e8a21f2341ed9fd7506d3',originalRevision:'920a182a-7660-4ff3-985f-d5580380413f'};
fixture.generation='p-'+createHash('sha256').update('test-delete/'+fixture.student).digest('hex');
function validateRetainedPerson(row){
 assert.equal(row?.schoolId,fixture.schoolId);assert.ok(row.id===undefined||row.id===fixture.student);
 if(row._syncDeleted!==true){
  assert.equal(row.syntheticTest,true);assert.equal(row.mobileStableId,fixture.generation);
  assert.equal(row._syncRevision,fixture.originalRevision);
 }else{
  assert.equal(row._syncOperationId,fixture.operationId);assert.equal(row._syncDeletedOwner,fixture.generation);
  const plan=row._syncErasePlan;
  assert.equal(plan?.version,1);assert.ok(Array.isArray(plan.targets)&&plan.targets.length>=3&&plan.targets.length<=10);
  const exact=new Map([['students_directory',fixture.student],['documents',fixture.documentId],['fee_payments',fixture.feeId]]);
  for(const [collection,id] of exact)assert.ok(plan.targets.some(t=>t.collection===collection&&t.id===id));
  for(const t of plan.targets){
   assert.equal(t.generation,fixture.generation);
   assert.ok(exact.has(t.collection)?t.id===exact.get(t.collection):['mobile_users','mobile_sessions','mobile_complaints'].includes(t.collection));
  }
  assert.deepEqual(plan.files,[fixture.fileId]);
 }
 return true;
}
module.exports={fixture:Object.freeze(fixture),validateRetainedPerson};

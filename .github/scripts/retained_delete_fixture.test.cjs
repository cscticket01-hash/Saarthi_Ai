'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {fixture:f,validateRetainedPerson}=require('./retained_delete_fixture.cjs');
const original={schoolId:f.schoolId,id:f.student,syntheticTest:true,mobileStableId:f.generation,_syncRevision:f.originalRevision};
test('retained delete refuses a foreign, replacement or edited live person',()=>{
 assert.equal(validateRetainedPerson(original),true);
 for(const patch of [{schoolId:'foreign'},{id:'other'},{syntheticTest:false},{mobileStableId:'replacement'},{_syncRevision:'newer'}])
  assert.throws(()=>validateRetainedPerson({...original,...patch}));
});
test('retained deletion continuation requires the original exact generation, targets and file',()=>{
 const deleted={schoolId:f.schoolId,_syncDeleted:true,_syncOperationId:f.operationId,_syncDeletedOwner:f.generation,
  _syncErasePlan:{version:1,files:[f.fileId],targets:[['students_directory',f.student],['documents',f.documentId],['fee_payments',f.feeId]].map(([collection,id])=>({collection,id,generation:f.generation}))}};
 assert.equal(validateRetainedPerson(deleted),true);
 for(const change of [r=>r._syncOperationId='other',r=>r._syncDeletedOwner='other',
  r=>r._syncErasePlan.files.push('other'),r=>r._syncErasePlan.targets[1].id='other',
  r=>r._syncErasePlan.targets.push({collection:'school_settings',id:'other',generation:f.generation}),
  r=>r._syncErasePlan.targets[0].generation='replacement']){
  const row=structuredClone(deleted);change(row);assert.throws(()=>validateRetainedPerson(row));
 }
});

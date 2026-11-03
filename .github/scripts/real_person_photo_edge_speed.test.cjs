'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {priorFixtureDeleteBody}=require('./real_person_photo_edge_speed.cjs');
const school='vs-db8afb01a3be46a983c8284714d06e5d',id='CFSPEED_STUDENT_41496978963_0_b10f4c';
const fixture=()=>({schoolId:school,_syncDeleted:true,_syncOperationId:'delete_operation_0001',_syncRevision:'new-tombstone-revision',_syncDeletedOwner:'p-original-generation',_syncErasePlan:{files:['10tja6gbObZ18mgxQy-jZDTgQ90YYgbCj'],targets:[{collection:'students_directory',id,sourceRevision:'original-person-revision'}]}});
test('synthetic cleanup retry preserves original operation, generation and CAS baseline',()=>{
 const row=fixture(),request=priorFixtureDeleteBody(row);
 assert.equal(request.expectedRecordRevision,'original-person-revision');assert.notEqual(request.expectedRecordRevision,row._syncRevision);
 assert.equal(request.operationId,row._syncOperationId);assert.equal(request.deletedStudentGeneration,row._syncDeletedOwner);assert.equal(request.deleteEverywhereVersion,1);
});
test('synthetic cleanup refuses foreign ownership, missing file proof and missing original baseline',()=>{
 for(const change of [r=>r.schoolId='other',r=>r._syncErasePlan.files=[],r=>r._syncErasePlan.targets=[],r=>r._syncDeleted=false,r=>r._syncOperationId='invalid']){const row=fixture();change(row);assert.throws(()=>priorFixtureDeleteBody(row));}
});

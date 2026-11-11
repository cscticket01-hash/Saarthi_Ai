'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {summarize,SCHOOL}=require('./migration_marker_diagnostic.cjs');
test('diagnostic emits schema and hashes without record or operation identifiers',()=>{
 const input={inflight:{'private-marker':{collection:'students_directory',startedAt:1,activeAttempts:0,
  operationBinding:{schoolId:SCHOOL,operation:'write',id:'PRIVATE-PUPIL',operationId:'PRIVATE-OPERATION',requestHash:'a'.repeat(64)},
  hiddenPayload:'PRIVATE-DATA'}}};
 const before=JSON.stringify(input),result=summarize(input),text=JSON.stringify(result);
 assert.equal(result.unsettledWrites,1);assert.equal(result.markers[0].bindingSchoolMatches,true);
 for(const secret of ['private-marker','PRIVATE-PUPIL','PRIVATE-OPERATION','PRIVATE-DATA'])assert(!text.includes(secret));
 assert.equal(JSON.stringify(input),before);
});
test('old unbound markers remain unknown rather than being cleared or treated as writes',()=>{
 const result=summarize({inflight:{old:{collection:'*',startedAt:1,activeAttempts:0}}});
 assert.equal(result.markers[0].bound,false);assert.equal(result.markers[0].collection,'unbound');
 assert.equal(result.unsettledWrites,1);assert.equal(summarize({}).unsettledWrites,0);
});

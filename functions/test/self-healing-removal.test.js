'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {fixture,A}=require('./helpers/managed-school-broker');
test('retired Windows and developer telemetry routes reject without cloud writes or data cleanup',async()=>{
 const f=fixture();f.docs.set('universal_health_reports/retained',{schoolId:A,history:'retain'});const before=JSON.stringify([...f.docs]);
 for(const [action,token]of [['managed/health/report','A'],['developer/managed/health/summary','developer']]){
  await assert.rejects(f.call({action,schoolId:A,report:{schema:2}},token),e=>e.status===400);
 }
 assert.equal(f.sent.length,0);assert.equal(JSON.stringify([...f.docs]),before);
});
test('retired Android telemetry action is rejected before attendance/session routing',async()=>{
 const f=fixture(),before=JSON.stringify([...f.docs]);
 await assert.rejects(f.call({action:'managed/mobile',schoolId:A,request:{action:'mobile_health_report',report:{},attendancePermit:'not-an-attendance-request'}}),e=>e.status===400);
 assert.equal(f.sent.length,0);assert.equal(JSON.stringify([...f.docs]),before);
});
test('ordinary signed storage checks still work after engine removal',async()=>{
 const f=fixture();const r=await f.call({action:'managed/storage/check',schoolId:A});assert.equal(r.success,true);assert.equal(r.storageReady,true);assert.equal(f.sent.length,1);assert.equal(JSON.parse(JSON.parse(f.sent[0].opt.body).payload).action,'managed_health');
 const photo=await f.call({action:'managed/storage/check',schoolId:A,profilePhoto:true});
 assert.equal(photo.success,true);
 assert.equal(f.sent.length,2);
 assert.equal(JSON.parse(JSON.parse(f.sent[1].opt.body).payload).profilePhoto,true);
});

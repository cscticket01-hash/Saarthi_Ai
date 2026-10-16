'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {fixture,A,B}=require('./helpers/managed-school-broker');
const request={action:'managed/records',collection:'students_directory',id:'Class 1_Roll_1',syncProtocol:2,operationId:'verified-route-operation1',expectedRecordRevision:'revision'};
test('recovery forwards only the authenticated school and its exact record proof',async()=>{
 let sent;
 const f=fixture(async(url,opt)=>{sent=JSON.parse(JSON.parse(opt.body).payload);return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,syncProtocol:2,recordRevision:'revision',recovered:true})};});
 assert.equal((await f.call({...request,operation:'recover',data:{schoolId:A,_syncRevision:'revision',name:'Synthetic'}})).recovered,true);
 assert.equal(sent.operation,'recover');assert.equal(sent.data.schoolId,A);assert.equal(sent.data._syncRevision,'revision');
 await assert.rejects(f.call({...request,schoolId:B,operation:'recover',data:{schoolId:B}}));
 await assert.rejects(f.call({...request,collection:'platform_licenses',operation:'recover',data:{}}));
});
test('generation-bound deletion is accepted only for a student delete and survives the signed transport',async()=>{
 let sent;const f=fixture(async(url,opt)=>{sent=JSON.parse(JSON.parse(opt.body).payload);return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,syncProtocol:2,recordRevision:'deleted'})};});
 await f.call({...request,operation:'delete',deletedStudentGeneration:'p-original'});assert.equal(sent.deletedStudentGeneration,'p-original');
 await assert.rejects(f.call({...request,collection:'fee_payments',operation:'delete',deletedStudentGeneration:'p-original'}));
 await assert.rejects(f.call({...request,operation:'write',data:{},deletedStudentGeneration:'p-original'}));
});
test('known missing-Sheet, parent admission and retired-generation failures preserve precise categories without a false ACK',async()=>{
 for(const [code,status]of [['SCRIPT_SHEET_RECOVERY_REQUIRED',503],['SCRIPT_STUDENT_PARENT_PENDING',503],['SCRIPT_STUDENT_GENERATION_DELETED',409],['SCRIPT_SYNC_STATE_IDENTITY',409],['SCRIPT_RECOVERY_MISMATCH',409]]){
  const f=fixture(async()=>({ok:true,status:200,text:async()=>JSON.stringify({success:false,schoolId:A,code})}));
  await assert.rejects(f.call({...request,operation:'write',data:{name:'Synthetic'}}),error=>error.status===status&&error.code===code);
 }
});

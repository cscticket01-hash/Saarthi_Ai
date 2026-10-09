'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {fixture,A,B,secret}=require('./helpers/managed-school-broker');
test('concurrent missing-storage read during pairing cannot block signed readback after durable commit',async()=>{
 let concurrentRead=false;
 const f=fixture(async(_,opt,authorize)=>{
  const b=JSON.parse(opt.body);
  if(b.action==='managed_connect'){
   await assert.rejects(f.call({action:'managed/storage/check',schoolId:A}),e=>e.status===409&&e.code==='SCHOOL_STORAGE_NOT_CONNECTED');
   concurrentRead=true;
   await authorize({action:'managed/storage/authorize',schoolId:A,ticket:b.ticket});
   return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,storageReady:true,connectionSecret:secret})};
  }
  return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,storageReady:true,recordSyncVersion:2})};
 });
 f.docs.delete('school_storage_private/'+A);
 const other=JSON.stringify(f.docs.get('school_storage_private/'+B));
 const paired=await f.call({action:'managed/storage/connect',schoolId:A,scriptUrl:'https://script.google.com/macros/s/TestRaceDeployment/exec'});
 assert(concurrentRead);assert.equal(paired.storageReady,true);
 const readback=await f.call({action:'managed/storage/check',schoolId:A});
 assert.equal(readback.storageReady,true);assert.equal(readback.recordSyncVersion,2);
 assert.equal(JSON.stringify(f.docs.get('school_storage_private/'+B)),other);
 await assert.rejects(f.call({action:'managed/storage/check',schoolId:B}),e=>e.status===403);
});

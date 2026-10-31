'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {fixture,A,B,time}=require('./helpers/managed-school-broker');

test('developer gets verified own-school count, bytes and registered devices only',async()=>{
 const f=fixture(async(_,options)=>({ok:true,status:200,text:async()=>{
  const body=JSON.parse(options.body);
  return JSON.stringify({success:true,schoolId:body.schoolId,studentCount:26,
    driveBytes:1048576,partial:false});
 }}));
 f.docs.get('platform_schools/'+A).storageReady=true;
 f.docs.set('managed_pc_registries/'+A,{
  schemaVersion:1,schoolId:A,devices:{
   a:{schoolId:A,status:'active'},
   b:{schoolId:A,status:'active'},
   c:{schoolId:A,status:'revoked'},
  },
 });
 const r=await f.call({action:'developer/managed/overview',schoolId:A},'developer');
 assert.equal(r.studentCount,26);assert.equal(r.driveBytes,1048576);
 assert.equal(r.deviceCount,2);assert.equal(r.deviceLimit,5);
 assert.equal(f.docs.get('platform_schools/'+A).studentCount,26);
 assert.equal(f.docs.get('platform_schools/'+B).studentCount,undefined);
 const requests=f.sent.length;
 const again=await f.call({action:'developer/managed/overview',schoolId:A},'developer');
 assert.equal(again.studentCount,26);assert.equal(f.sent.length,requests,
  'a fresh signed summary is reused for five minutes');
 await assert.rejects(f.call({action:'developer/managed/overview',schoolId:A},'A'),
  e=>e.status===403);
 await assert.rejects(f.call({action:'developer/managed/overview',schoolId:B},'A'),
  e=>e.status===403);
});
test('unavailable school Drive cannot fabricate zeros or expose foreign PC registry',async()=>{
 const f=fixture();
 const r=await f.call({action:'developer/managed/overview',schoolId:A},'developer');
 assert.equal(r.deviceCount,0);
 assert.equal(r.studentCount,undefined);
 assert.match(r.summaryError,/not connected/);
 assert.equal(f.sent.length,0);
 f.docs.set('managed_pc_registries/'+A,{
  schemaVersion:1,schoolId:B,devices:{bad:{schoolId:B,status:'active'}},
 });
 await assert.rejects(f.call({action:'developer/managed/overview',schoolId:A},'developer'),
  e=>e.status===403);
});
test('a failed signed summary keeps previous measured data and real device count',async()=>{
 const f=fixture(async()=>{throw Error('Google unavailable')});
 const row=f.docs.get('platform_schools/'+A);
 Object.assign(row,{storageReady:true,studentCount:12,driveBytes:42,
   driveBytesPartial:true,summaryAt:time-900000});
 const res=await f.call({action:'developer/managed/overview',schoolId:A},'developer');
 assert.equal(res.studentCount,12);assert.equal(res.driveBytes,42);
 assert.equal(res.deviceCount,0);
 assert.ok(res.summaryError);
});

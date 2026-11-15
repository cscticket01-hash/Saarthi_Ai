'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {schoolCall}=require('./safe_test_read_retry.cjs');
const schoolId='vs-'+'a'.repeat(32),url='https://test.example/',body={action:'managed/records',operation:'read',collection:'students_directory',id:'original',syncProtocol:2};
const retryOptions={wait:async()=>{},random:()=>.5};
test('a transient unsigned-response 502 retries the same read and verifies final school identity',async()=>{
 const seen=[],report={};const result=await schoolCall({url,schoolId,report,retryOptions,post:async(_,request)=>{
  seen.push(structuredClone(request));return seen.length===1?{http:502,data:{success:false,code:'SCRIPT_SIGNED_RESPONSE_UNVERIFIED'}}:{http:200,data:{success:true,schoolId,records:{}}};
 }},body);
 assert.equal(result.success,true);assert.equal(seen.length,2);assert.deepEqual(seen[0],seen[1]);assert.equal(report.readRetries.length,1);
});
test('a permanently unverified read stops after three attempts without a fabricated ACK',async()=>{
 let calls=0;await assert.rejects(schoolCall({url,schoolId,report:{},retryOptions,post:async()=>{
  calls++;return {status:502,data:{success:false,code:'SCRIPT_SIGNED_RESPONSE_UNVERIFIED'}};
 }},body),e=>e.http===502&&e.code==='SCRIPT_SIGNED_RESPONSE_UNVERIFIED');assert.equal(calls,3);
});
test('uncertain writes and deletes are never replayed by the read retry wrapper',async()=>{
 for(const operation of ['write','delete']){
  let calls=0;await assert.rejects(schoolCall({url,schoolId,report:{},retryOptions,post:async()=>{
   calls++;return {http:502,data:{success:false,code:'SCRIPT_SIGNED_RESPONSE_UNVERIFIED'}};
  }},{...body,operation}),e=>e.code==='SCRIPT_SIGNED_RESPONSE_UNVERIFIED');assert.equal(calls,1);
 }
});
test('a foreign or unauthenticated successful HTTP response cannot become signed TEST proof',async()=>{
 for(const data of [{success:true,schoolId:'vs-'+'b'.repeat(32)},{schoolId},{success:true}])
  await assert.rejects(schoolCall({url,schoolId,report:{},retryOptions,post:async()=>({http:200,data})},body));
});

test('an explicit original-progress read can recover on its sixth identical request',async()=>{
 const seen=[],waits=[],report={};const result=await schoolCall({url,schoolId,report,retryOptions:{attempts:6,random:()=>.5,wait:async ms=>waits.push(ms)},post:async(_,request)=>{
  seen.push(structuredClone(request));return seen.length<6?{http:502,data:{code:'SCRIPT_SIGNED_RESPONSE_UNVERIFIED'}}:{http:200,data:{success:true,schoolId}};
 }},body);
 assert.equal(result.success,true);assert.equal(seen.length,6);
 for(const request of seen)assert.deepEqual(request,seen[0]);
 assert.deepEqual(waits,[5000,10000,20000,40000,60000]);
});
test('an extended permanently unverified read remains bounded and never manufactures proof',async()=>{
 let calls=0;await assert.rejects(schoolCall({url,schoolId,report:{},retryOptions:{...retryOptions,attempts:6},post:async()=>{
  calls++;return {http:502,data:{code:'SCRIPT_SIGNED_RESPONSE_UNVERIFIED'}};
 }},body));assert.equal(calls,6);
});
test('extended read settings do not replay a write or delete',async()=>{
 for(const operation of ['write','delete']){
  let calls=0;await assert.rejects(schoolCall({url,schoolId,report:{},retryOptions:{...retryOptions,attempts:6},post:async()=>{
   calls++;return {http:503,data:{code:'SCRIPT_TIMEOUT'}};
  }},{...body,operation}));assert.equal(calls,1);
 }
});
test('invalid retry limits fail before any provider call',async()=>{
 for(const attempts of [0,7,1.5]){
  let calls=0;await assert.rejects(schoolCall({url,schoolId,report:{},retryOptions:{...retryOptions,attempts},post:async()=>{calls++;throw Error();}},body),RangeError);assert.equal(calls,0);
 }
});
test('extended settings preserve the original three-request quota stop',async()=>{
 let calls=0;await assert.rejects(schoolCall({url,schoolId,report:{},retryOptions:{...retryOptions,attempts:6},post:async()=>{calls++;return {http:429,data:{code:'SCRIPT_QUOTA_EXCEEDED'}};}},body));
 assert.equal(calls,3);
});
test('a foreign HTTP200 response is rejected on the first extended read',async()=>{
 let calls=0;await assert.rejects(schoolCall({url,schoolId,report:{},retryOptions:{...retryOptions,attempts:6},post:async()=>{calls++;return {http:200,data:{success:true,schoolId:'vs-'+'b'.repeat(32)}};}},body));assert.equal(calls,1);
});

test('a transport cannot change the next retry or the caller request identity',async()=>{
 const request={...body,filter:{original:true}},seen=[];
 await schoolCall({url,schoolId,report:{},retryOptions,post:async(_,value)=>{
  seen.push(structuredClone(value));value.id='replacement';value.filter.original=false;
  return seen.length===1?{http:503,data:{}}:{http:200,data:{success:true,schoolId}};
 }},request);
 assert.deepEqual(seen[0],seen[1]);assert.equal(request.id,'original');assert.equal(request.filter.original,true);
});

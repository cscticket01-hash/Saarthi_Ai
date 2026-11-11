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

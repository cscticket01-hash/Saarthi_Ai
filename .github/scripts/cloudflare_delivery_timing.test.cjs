'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {acceptance,ENDPOINT,LOGIN,SCHOOL}=require('./cloudflare_delivery_timing.cjs');
const env={VS_CF_DELIVERY_ACCEPTANCE:'1',VS_EXPECTED_RUNTIME:'a'.repeat(40),
 VS_CF_DELIVERY_RUN_ID:'synthetic-retained',VS_TEST_LOGIN_EMAIL:'secret-test-email',VS_TEST_LOGIN_PASSWORD:'secret-test-password'};
test('live acceptance cannot run without explicit opt-in and a stable run ID',async()=>{
 for(const patch of [{VS_CF_DELIVERY_ACCEPTANCE:'0'},{VS_CF_DELIVERY_RUN_ID:'../unsafe'},{VS_EXPECTED_RUNTIME:'wrong'}]){
  let requests=0;const result=await acceptance({env:{...env,...patch},request:async()=>{requests++;throw Error();}});
  assert.equal(result.status,'FAIL');assert.equal(requests,0);
 }
});
test('unexpected deployed runtime prevents TEST login and all writes',async()=>{
 const calls=[];const result=await acceptance({env,request:async(url,body)=>{
  calls.push({url,body});return {status:200,data:{ready:true,projectId:'saarthi-ai-df12b',runtimeCommit:'b'.repeat(40)}};
 }});
 assert.equal(result.status,'FAIL');assert.equal(calls.length,1);assert.equal(calls[0].url,ENDPOINT+'/healthz');assert.equal(calls[0].body,undefined);
});
test('foreign membership fails before business data and reports no credentials',async()=>{
 const calls=[];const result=await acceptance({env,request:async(url,body)=>{
  calls.push({url,body});
  if(url===ENDPOINT+'/healthz')return {status:200,data:{ready:true,projectId:'saarthi-ai-df12b',runtimeCommit:env.VS_EXPECTED_RUNTIME}};
  if(url===LOGIN)return {status:200,data:{idToken:'private-token',localId:'private-uid'}};
  assert.equal(body.schoolId,SCHOOL);assert.equal(body.action,'managed/session');
  return {status:403,data:{success:false,code:'SCHOOL_MEMBERSHIP_REQUIRED',message:'private-secret'}};
 }});
 assert.equal(result.status,'FAIL');assert.equal(calls.length,3);
 assert.doesNotMatch(JSON.stringify(result),/private-token|private-uid|private-secret|secret-test-email|secret-test-password/);
});

'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {Readable}=require('node:stream');
const {createHandler}=require('../../staging-school-cloud/server.cjs');
async function request(error){
 const logs=[];let status,body;const headers={};
 const req=Readable.from([Buffer.from(JSON.stringify({action:'managed/records',schoolId:'private-school',data:{password:'NEVER_LOG_THIS'}}))]);
 Object.assign(req,{url:'/school-cloud',method:'POST',headers:{'content-type':'application/json',authorization:'Bearer NEVER_LOG_THIS'}});
 const res={setHeader:(k,v)=>headers[k]=v,writeHead:c=>status=c,end:v=>body=JSON.parse(v)};
 await createHandler({handle:async()=>{throw error;},health:async()=>{},logger:v=>logs.push(v)})(req,res);
 return {status,body,logs,headers};
}
test('upstream errors retain their actual HTTP status and always log a safe operation/reference',async()=>{
 for(const status of [502,503,504,429,409,403]){
  const e=Object.assign(new Error('secret school data NEVER_LOG_THIS'),{status});
  const r=await request(e);assert.equal(r.status,status);assert.equal(r.body.success,false);
  assert.equal(r.logs[0].event,'central_failure');assert.equal(r.logs[0].operation,'managed/records');assert.equal(r.logs[0].code,'UNKNOWN');
  assert.equal(r.logs[0].requestId,r.body.requestId);assert.equal(r.body.requestId,r.headers['X-Saarthi-Request-Id']);
  assert.equal(JSON.stringify(r).includes('NEVER_LOG_THIS'),false);
 }
});
test('uncoded runtime errors remain unavailable without hiding diagnostic correlation',async()=>{
 const r=await request(new TypeError('NEVER_LOG_THIS'));assert.equal(r.status,503);assert.equal(r.body.success,false);assert.equal(r.logs[0].code,'UNKNOWN');
});
test('safe upstream category survives handler without a fake acknowledgement',async()=>{
 const r=await request(Object.assign(new Error('School script identity or operation failed'),{status:502,code:'SCRIPT_OPERATION_FAILED',publicMessage:true}));
 assert.equal(r.status,502);assert.equal(r.body.code,'SCRIPT_OPERATION_FAILED');assert.equal(r.body.success,false);
});

test('only verified allowlisted sync conflict context is exposed; raw request identity is never used',async()=>{
 const context={schoolId:'vs-'+ 'a'.repeat(32),syncProtocol:2,operationId:'operation-123456789',password:'NEVER_LOG_THIS'};
 const r=await request(Object.assign(new Error('Record revision conflict'),{status:409,code:'RECORD_REVISION_CONFLICT',publicMessage:true,syncDiagnostic:context}));
 for(const value of [r.body,r.logs[0]]){assert.equal(value.schoolId,context.schoolId);assert.equal(value.operationId,context.operationId);assert.equal(value.syncProtocol,2);}
 assert.equal(r.body.success,false);assert.equal(JSON.stringify(r).includes('NEVER_LOG_THIS'),false);
 for(const change of [{code:'UNKNOWN'},{syncDiagnostic:{...context,schoolId:'../private'}},{status:403}]){
  const blocked=await request(Object.assign(new Error('private'),{status:409,code:'RECORD_REVISION_CONFLICT',syncDiagnostic:context},change));
  assert.equal(blocked.body.schoolId,undefined);assert.equal(blocked.logs[0].schoolId,undefined);
 }
});

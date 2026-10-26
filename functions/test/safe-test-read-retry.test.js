'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const retry=require('../../.github/scripts/safe_test_read_retry.cjs');
const options={wait:async()=>{},random:()=>0.5};
test('read retries transient outage with sanitized evidence and bounded delay',async()=>{
 let calls=0;const report={};
 const r=await retry(async()=>({http:++calls===1?503:200,data:{requestId:'safe-reference'},elapsedMs:1}), 'test',{action:'managed/records',operation:'read'},null,report,options);
 assert.equal(calls,2);assert.equal(r.http,200);assert.equal(r.elapsedMs,5002);assert.equal(report.readRetries.length,1);
});
test('uncertain write is never automatically replayed',async()=>{
 let calls=0;await retry(async()=>{calls++;return {http:503,data:{}};},'test',{action:'managed/records',operation:'write',operationId:'same-id'},null,{},options);assert.equal(calls,1);
});
test('persistent read outage fails after three attempts; authorization is not retried',async()=>{
 for(const [status,expected] of [[503,3],[403,1]]){let calls=0;const r=await retry(async()=>{calls++;return {http:status,data:{}};},'test',{action:'managed/records',operation:'read'},null,{},options);assert.equal(calls,expected);assert.equal(r.http,status);}
});

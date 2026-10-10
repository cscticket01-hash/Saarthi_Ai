'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {waitForRuntime}=require('./test_runtime_identity.cjs');
const sha='a'.repeat(40);
test('runtime fence waits through an outage and old deployment before authorizing the exact reviewed TEST runtime',async()=>{
 let calls=0,waits=0;
 await waitForRuntime(sha,{attempts:3,delay:async()=>{waits++;},fetchImpl:async(url,options)=>{
  assert.equal(url,'https://saarthi-sync-v2-test.onrender.com/school-cloud/healthz');assert.equal(options.method,undefined);
  calls++;return {status:calls===1?503:200,json:async()=>({ready:true,projectId:'saarthi-ai-df12b',runtimeCommit:calls===2?'b'.repeat(40):sha})};
 }});assert.equal(calls,3);assert.equal(waits,2);
});
test('missing, foreign, unready or malformed runtime identity never permits cloud writers',async()=>{
 for(const data of [{ready:true,projectId:'saarthi-ai-df12b'},{ready:true,projectId:'foreign',runtimeCommit:sha},{ready:false,projectId:'saarthi-ai-df12b',runtimeCommit:sha}]) {
  await assert.rejects(waitForRuntime(sha,{attempts:1,fetchImpl:async()=>({status:200,json:async()=>data})}));
 }
 await assert.rejects(waitForRuntime('private value',{fetchImpl:()=>{throw Error('must not fetch');}}));
});

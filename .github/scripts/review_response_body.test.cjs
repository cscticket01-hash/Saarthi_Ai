'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {responseJson}=require('./review_response_body.cjs');
test('body evidence waits for JSON completion and observes a response once',async()=>{
 let calls=0,completed=false;
 const data=await responseJson({json:async()=>{calls++;await new Promise(r=>setTimeout(r,2));completed=true;return {verified:true};}},100);
 assert.equal(completed,true);assert.equal(calls,1);assert.deepEqual(data,{verified:true});
});
test('missing response completion fails within a capped deadline without replay',async()=>{
 let calls=0;
 await assert.rejects(responseJson({json:()=>{calls++;return new Promise(()=>{});}},5),/^Error: TEST response body verification timed out$/);
 assert.equal(calls,1);
});
test('malformed JSON is not replaced with success and invalid budgets fail closed',async()=>{
 const malformed=new SyntaxError('Synthetic malformed response');
 await assert.rejects(responseJson({json:async()=>{throw malformed;}},100),error=>error===malformed);
 for(const budget of [0,-1,60001,NaN])await assert.rejects(responseJson({json:async()=>({})},budget),/Invalid response evidence deadline/);
});

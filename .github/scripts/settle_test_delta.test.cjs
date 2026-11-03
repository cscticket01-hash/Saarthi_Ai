'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {settleTestDelta}=require('./settle_test_delta.cjs');
const response=(revision,unchanged,records={})=>({http:200,data:{changes:{school_notices:{syncProtocol:2,collectionRevision:revision,unchanged,records}}}});
test('stable checkpoint requires no records and exactly one read',async()=>{
 let calls=0;const report={};await settleTestDelta(async body=>{calls++;assert.equal(body.action,'managed/changes');assert.equal(body.knownRevisions.school_notices,'a');return response('a',true);},{school_notices:'a'},report);assert.equal(calls,1);
});
test('verified new head is followed before certifying unchanged',async()=>{
 const report={},seen=[];await settleTestDelta(async body=>{seen.push(body.knownRevisions.school_notices);return seen.length===1?response('b',false,{synthetic:{}}):response('b',true);},{school_notices:'a'},report);
 assert.deepEqual(seen,['a','b']);assert.equal(report.deltaCheckpointTransitions[0][0].sameCheckpoint,false);assert.equal(report.deltaCheckpointTransitions[1][0].recordCount,0);
});
test('equal head with data or without unchanged proof fails closed',async()=>{
 for(const reply of [response('a',true,{bad:{}}),response('a',false)])await assert.rejects(settleTestDelta(async()=>reply,{school_notices:'a'},{}),/Equal checkpoint/);
});
test('different head cannot claim unchanged or omit a collection',async()=>{
 await assert.rejects(settleTestDelta(async()=>response('b',true),{school_notices:'a'},{}),/Changed checkpoint/);
 await assert.rejects(settleTestDelta(async()=>({http:200,data:{changes:{}}}),{school_notices:'a'},{}));
});
test('continuously advancing heads remain changed after bounded reads',async()=>{
 let calls=0;const reply=await settleTestDelta(async()=>response(String(++calls),false),{school_notices:'0'},{},3);assert.equal(calls,3);assert.equal(reply.data.changes.school_notices.unchanged,false);
});
test('provider rejection remains rejected and is never fabricated as unchanged',async()=>{
 const denied={http:502,data:{code:'SCRIPT_HTTP_ERROR'}};assert.equal(await settleTestDelta(async()=>denied,{school_notices:'a'},{}),denied);
});

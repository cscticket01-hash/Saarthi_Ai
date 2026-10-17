'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {fixture}=require('./helpers/managed-school-broker');
const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const request={action:'managed/changes',headOnly:true,collections:['fee_payments'],knownRevisions:{}};

test('live broker forwards head discovery without changing signed school identity or minting ACKs',async()=>{
 let payload;
 const broker=fixture(async(_,options)=>{
  const envelope=JSON.parse(options.body);payload=JSON.parse(envelope.payload);
  assert.equal(envelope.schoolId,school);
  return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:school,syncProtocol:2,headOnly:true,revisions:{fee_payments:'revision-1'}})};
 });
 const out=await broker.call(request);
 assert.equal(payload.headOnly,true);assert.deepEqual(payload.collections,['fee_payments']);
 assert.deepEqual(out.revisions,{fee_payments:'revision-1'});
 assert.equal(out.recordRevision,undefined);assert.equal(out.records,undefined);
 await assert.rejects(broker.call({...request,schoolId:school},'B'),e=>e.status===403);
 await assert.rejects(broker.call({...request,headOnly:'true'}),e=>e.status===400);
});

test('live broker rejects old, malformed and foreign head responses',async()=>{
 for(const result of [
  {headOnly:true,revisions:{}},
  {headOnly:true,revisions:{fee_payments:'r',foreign:'x'}},
  {headOnly:true,revisions:{fee_payments:123}},
  {headOnly:true,revisions:{fee_payments:''}},
  {headOnly:true,revisions:{fee_payments:'r'},schoolId:'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'},
  {changes:{fee_payments:{records:{},collectionRevision:'r',syncProtocol:2}}},
 ]){
  const broker=fixture(async()=>({ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:school,syncProtocol:2,...result})}));
  await assert.rejects(broker.call(request),e=>e.status===502);
 }
});

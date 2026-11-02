'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {fixture,A,B}=require('./helpers/managed-school-broker');
const operationId='retained-live-operation-0001';
function setup(){
 const calls=[];
 const receipt={liveProtocol:1,schoolId:A,operationId,cloudState:'committed',backupState:'verified',recordRevision:'live-revision',driveRevision:'drive-revision',record:null};
 const edge={enabled:()=>true,rpc:async(school,lane,body)=>{calls.push({school,lane,body});assert.equal(school,A);assert.equal(lane,'live');assert.equal(body.command,'operationReceipt');return {liveProtocol:1,schoolId:school,operationId:body.operationId,found:body.operationId===operationId,...(body.operationId===operationId?{fingerprint:'a'.repeat(64),receipt}:{})};}};
 const f=fixture(undefined,{cloudflareSync:edge,liveSyncSchools:[A]});
 return {...f,calls,receipt};
}
test('authenticated operation receipt reports independent Drive state after restart',async()=>{
 const f=setup(),result=await f.call({action:'managed/live/operationReceipt',schoolId:A,liveProtocol:1,operationId});
 assert.equal(result.success,true);assert.equal(result.found,true);assert.deepEqual(result.receipt,f.receipt);assert.equal(f.sent.length,0);assert.equal(f.calls.length,1);
 const absent=await f.call({action:'managed/live/operationReceipt',schoolId:A,liveProtocol:1,operationId:'unknown-live-operation-0002'});assert.equal(absent.found,false);assert.equal(absent.receipt,undefined);
});
test('foreign school, invalid operation IDs and missing negotiation never reach receipt storage',async()=>{
 const f=setup();for(const body of [
  {action:'managed/live/operationReceipt',schoolId:B,liveProtocol:1,operationId},
  {action:'managed/live/operationReceipt',schoolId:A,operationId},
  {action:'managed/live/operationReceipt',schoolId:A,liveProtocol:1,operationId:'../other-school'},
 ])await assert.rejects(f.call(body));assert.equal(f.calls.length,0);
});

'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),{createCloudflareDelivery}=require('../cloudflare-delivery');
const school='vs-'+'a'.repeat(32),request={action:'managed_records',collection:'school_settings',id:'school-clock',
 operation:'write',syncProtocol:2,operationId:'fast-ack-add-000000000001',expectedRecordRevision:'',
 data:{schoolId:school,name:'Current clock'}};
test('new record add/delete returns a truthful first-hop durable Cloudflare ACK with only one provider RPC',async()=>{
 const commands=[],edge={rpc:async(s,l,b)=>{
  assert.equal(s,school);assert.equal(l,'records');commands.push(b.command);
  if(b.command==='enqueue')return {id:b.id,state:'pending',due:Date.now(),response:null};
  throw Error('Second Cloudflare status RPC was unnecessary');
 }};
 const delivery=createCloudflareDelivery({edge});
 for(const operation of ['write','delete']){
  const r=operation==='write'?request:{...request,operation:'delete',operationId:'fast-ack-delete-0000000001',data:undefined};
  const reply=await delivery.record(school,r);
  assert.equal(reply.success,true);
  assert.equal(reply.cloudflareAccepted,true);
  assert.equal(reply.driveState,'pending');
  assert.equal(reply.recordRevision,undefined);
  assert.equal(reply.delivery.lane,'records');
  assert.match(reply.delivery.id,/^[a-f0-9]{64}$/);
 }
 assert.deepEqual(commands,['enqueue','enqueue']);
});
test('completed duplicate never equates Cloudflare enqueue with Drive verification without status proof',async()=>{
 const commands=[];
 const edge={rpc:async(s,l,b)=>{
  commands.push(b.command);
  if(b.command==='enqueue')return {id:b.id,state:'completed',response:null};
  if(b.command==='status')return {id:b.id,state:'completed',response:{result:{success:true,schoolId:school,
   syncProtocol:2,recordRevision:'gs-verified-synthetic',record:{id:request.id,schoolId:school,
   _syncRevision:'gs-verified-synthetic',_syncOperationId:request.operationId,name:request.data.name}}}};
  throw Error('Unexpected command');
 }};
 const reply=await createCloudflareDelivery({edge}).record(school,request);
 assert.equal(reply.driveState,'verified');
 assert.equal(reply.recordRevision,'gs-verified-synthetic');
 assert.deepEqual(commands,['enqueue','status']);
});
test('old or malformed enqueue receipt takes verified status owner, never a forged immediate ACK',async()=>{
 const commands=[],edge={rpc:async(_s,_l,b)=>{
  commands.push(b.command);
  if(b.command==='enqueue')return {id:'0'.repeat(64),state:'pending'};
  if(b.command==='status')return {state:'retry',due:Date.now()+5000,response:null};
 }};
 const out=await createCloudflareDelivery({edge}).record(school,request);
 assert.equal(out.driveState,'pending');
 assert.deepEqual(commands,['enqueue','status']);
});

'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {fixture,A,B,time}=require('./helpers/managed-school-broker');
test('central monitor separates verified backend ACK evidence from aggregate Windows queue reports',async()=>{
 const f=fixture(async(_,options)=>{const b=JSON.parse(options.body);return {ok:true,status:200,text:async()=>JSON.stringify({schoolId:b.schoolId,success:true,syncProtocol:2,recordRevision:'verified-revision'})};});
 await f.call({action:'managed/records',operation:'write',collection:'school_notices',id:'notice',syncProtocol:2,operationId:'monitor-operation-0001',expectedRecordRevision:'',data:{title:'Private content never monitored'}});
 const result=await f.call({action:'managed/sync/status',report:{pending:3,needsAttention:1,verifiedReceiptCount:7,lastCloudAckMillis:time-1000}});
 assert.equal(result.serverEvidence.outcome,'durable_ack');assert.equal(result.serverEvidence.observedAt,time);assert.equal(result.latestWindowsReport.pending,3);assert.equal(result.latestWindowsReport.source,'latest_windows_client_report');
 const central=await f.call({action:'developer/managed/sync/status',schoolId:A},'developer');assert.equal(central.latestWindowsReport.pending,3);
 assert(!JSON.stringify(central).includes('Private content'));assert(!JSON.stringify(central).includes('monitor-operation'));assert.equal(f.docs.get('platform_schools/'+B).syncWindowsReport,undefined);
});
test('missing monitor reports remain unknown and school credentials cannot read another school/developer monitor',async()=>{
 const f=fixture();const result=await f.call({action:'managed/sync/status'});assert.equal(result.serverEvidence,null);assert.equal(result.latestWindowsReport,null);
 await assert.rejects(f.call({action:'managed/sync/status',schoolId:B}),e=>e.status===403);
 await assert.rejects(f.call({action:'developer/managed/sync/status',schoolId:A}),e=>e.status===403);
});
test('monitor rejects record bodies, impossible counts and timestamps without touching records',async()=>{
 const f=fixture();for(const report of [{pending:1,needsAttention:2,verifiedReceiptCount:0,lastCloudAckMillis:0},{pending:0,needsAttention:0,verifiedReceiptCount:0,lastCloudAckMillis:time+999999},{pending:0,needsAttention:0,verifiedReceiptCount:0,lastCloudAckMillis:0,studentName:'private'}]){
  await assert.rejects(f.call({action:'managed/sync/status',report}),e=>e.status===400);
 }assert.equal(f.sent.length,0);assert.equal(f.docs.get('platform_schools/'+A).syncWindowsReport,undefined);
});
test('monitor write failures do not turn durable storage ACKs into failures, and safe errors stay distinct',async()=>{
 const f=fixture(async(_,options)=>{const b=JSON.parse(options.body);return {ok:true,status:200,text:async()=>JSON.stringify({schoolId:b.schoolId,success:true,syncProtocol:2,recordRevision:'confirmed'})};});
 const doc=f.db.doc;f.db.doc=path=>{const ref=doc(path);if(path==='platform_schools/'+A)ref.set=async()=>{throw Error('metadata unavailable');};return ref;};
 const ack=await f.call({action:'managed/records',operation:'delete',collection:'school_notices',id:'n',syncProtocol:2,operationId:'monitor-delete-0001',expectedRecordRevision:''});assert.equal(ack.recordRevision,'confirmed');
 const bad=fixture(async(_,options)=>({ok:true,status:200,text:async()=>JSON.stringify({success:false,schoolId:JSON.parse(options.body).schoolId,code:'SCRIPT_TIMEOUT'})}));
 await assert.rejects(bad.call({action:'managed/records',operation:'read',collection:'school_notices'}));
 const result=await bad.call({action:'managed/sync/status'});assert.equal(result.serverEvidence.outcome,'failed');assert.equal(result.serverEvidence.code,'SCRIPT_TIMEOUT');
});

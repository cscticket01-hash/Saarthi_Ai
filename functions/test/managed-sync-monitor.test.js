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
 const doc=f.db.doc;f.db.doc=path=>{const ref=doc(path);if(path==='platform_schools/'+A)ref.set=ref.update=async()=>{throw Error('metadata unavailable');};return ref;};
 const ack=await f.call({action:'managed/records',operation:'delete',collection:'school_notices',id:'n',syncProtocol:2,operationId:'monitor-delete-0001',expectedRecordRevision:''});assert.equal(ack.recordRevision,'confirmed');
 const bad=fixture(async(_,options)=>({ok:true,status:200,text:async()=>JSON.stringify({success:false,schoolId:JSON.parse(options.body).schoolId,code:'SCRIPT_TIMEOUT'})}));
 await assert.rejects(bad.call({action:'managed/records',operation:'read',collection:'school_notices'}));
 const result=await bad.call({action:'managed/sync/status'});assert.equal(result.serverEvidence.outcome,'failed');assert.equal(result.serverEvidence.code,'SCRIPT_TIMEOUT');
});

test('a successful durable ACK replaces obsolete failure evidence without replacing school or client metadata',async()=>{
 const f=fixture(async(_,options)=>({ok:true,status:200,text:async()=>JSON.stringify({schoolId:JSON.parse(options.body).schoolId,success:true,syncProtocol:2,recordRevision:'confirmed'})}));
 const school=f.docs.get('platform_schools/'+A);school.syncServerEvidence={version:1,observedAt:time-1000,outcome:'failed',stage:'managed_records',code:'SCRIPT_TIMEOUT'};
 school.syncWindowsReport={source:'latest_windows_client_report',pending:3};
 await f.call({action:'managed/records',operation:'write',collection:'school_notices',id:'notice',syncProtocol:2,operationId:'monitor-recovery-0001',expectedRecordRevision:'',data:{title:'Synthetic'}});
 const result=await f.call({action:'managed/sync/status'});
 assert.equal(result.serverEvidence.outcome,'durable_ack');
 assert.equal(Object.hasOwn(result.serverEvidence,'code'),false,'Recovered ACK must not retain the preceding failure category');
 assert.equal(result.latestWindowsReport.pending,3);assert.equal(f.docs.get('platform_schools/'+A).managed,true);assert.equal(f.docs.get('platform_schools/'+A).authUid,'A');
});


test('own-school storage evidence returns measured partial byte totals and uses bounded cached reads',async()=>{
 const f=fixture(async(_,options)=>({ok:true,status:200,text:async()=>JSON.stringify({schoolId:JSON.parse(options.body).schoolId,success:true,studentCount:4,driveBytes:321,partial:true})}));
 const measured=await f.call({action:'managed/summary'});
 assert.deepEqual(measured,{success:true,schoolId:A,cached:false,studentCount:4,driveBytes:321,partial:true,measuredAt:time});
 const calls=f.sent.length;const cached=await f.call({action:'managed/summary'});
 assert.equal(cached.cached,true);assert.equal(cached.measuredAt,time);assert.equal(cached.driveBytes,321);assert.equal(f.sent.length,calls);
 await assert.rejects(f.call({action:'managed/summary',schoolId:B}),e=>e.status===403);
 assert.equal(f.docs.get('platform_schools/'+B).driveBytes,undefined);
});
test('missing or invalid cached storage totals require a new verified summary; malformed remote evidence is rejected',async()=>{
 const f=fixture(async(_,options)=>({ok:true,status:200,text:async()=>JSON.stringify({schoolId:JSON.parse(options.body).schoolId,success:true,studentCount:0,driveBytes:0,partial:false})}));
 f.docs.get('platform_schools/'+A).summaryAt=time;
 const r=await f.call({action:'managed/summary'});assert.equal(r.cached,false);assert.equal(r.driveBytes,0);
 const bad=fixture(async(_,options)=>({ok:true,status:200,text:async()=>JSON.stringify({schoolId:JSON.parse(options.body).schoolId,success:true,studentCount:0,driveBytes:-1})}));
 await assert.rejects(bad.call({action:'managed/summary'}),e=>e.status===502);
 assert.equal(bad.docs.get('platform_schools/'+A).driveBytes,undefined);
});

test('optional Windows fleet metadata is bounded, tenant scoped and never retains omitted stale fields',async()=>{
 const f=fixture();const base={pending:3,needsAttention:1,verifiedReceiptCount:7,lastCloudAckMillis:time-1000};
 const r=await f.call({action:'managed/sync/status',report:{...base,appVersion:'2.1.106-test',conflictCount:1,documentPending:2,lastReconciliationMillis:time-2000,lastLocalBackupMillis:time-3000}});
 assert.equal(r.latestWindowsReport.appVersion,'2.1.106-test');assert.equal(r.latestWindowsReport.documentPending,2);
 for(const extra of [{appVersion:'private email@example.com'},{conflictCount:2},{documentPending:4},{lastLocalBackupMillis:time+999999}])await assert.rejects(f.call({action:'managed/sync/status',report:{...base,...extra}}),e=>e.status===400);
 const old=f.docs.get('platform_schools/'+A);old.syncWindowsReport.receivedAt=time-300001;
 const next=await f.call({action:'managed/sync/status',report:base});assert.equal(next.latestWindowsReport.appVersion,undefined);
 assert.equal(f.docs.get('platform_schools/'+B).syncWindowsReport,undefined);
});

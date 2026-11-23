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

test('monitor records protocol transitions immediately and throttles identical evidence only',async()=>{
 let protocol=1;
 const f=fixture(async(_,options)=>({ok:true,status:200,text:async()=>JSON.stringify({schoolId:JSON.parse(options.body).schoolId,success:true,syncProtocol:protocol,records:{}})}));
 const read=()=>f.call({action:'managed/records',operation:'read',collection:'school_settings',syncProtocol:2});
 await read();assert.equal((await f.call({action:'managed/sync/status'})).serverEvidence.protocol,1);
 protocol=2;await read();assert.equal((await f.call({action:'managed/sync/status'})).serverEvidence.protocol,2);
 let writes=0;const doc=f.db.doc;f.db.doc=path=>{const ref=doc(path);const update=ref.update;ref.update=async value=>{writes++;return update(value);};return ref;};
 await read();assert.equal(writes,0,'Repeated identical evidence remains bounded');
});

test('failed monitoring persistence does not suppress the next verified response',async()=>{
 const f=fixture(async(_,options)=>({ok:true,status:200,text:async()=>JSON.stringify({schoolId:JSON.parse(options.body).schoolId,success:true,syncProtocol:2,records:{}})}));
 const doc=f.db.doc;let failOnce=true;
 f.db.doc=path=>{const ref=doc(path);if(path==='platform_schools/'+A){const update=ref.update;ref.update=async value=>{if(failOnce){failOnce=false;throw Error('Transient metadata outage');}return update(value);};}return ref;};
 const read=()=>f.call({action:'managed/records',operation:'read',collection:'school_settings',syncProtocol:2});
 await read();assert.equal((await f.call({action:'managed/sync/status'})).serverEvidence,null);
 await read();assert.equal((await f.call({action:'managed/sync/status'})).serverEvidence.protocol,2);
});

test('handoff monitor separates device-owned work from cloud-owned pending backup',async()=>{
 const f=fixture();const base={pending:0,needsAttention:0,verifiedReceiptCount:7,lastCloudAckMillis:time-1000};
 const report={...base,cloudflareOwnedPendingDrive:4,lastCloudflareHandoffMicros:2499000};
 const saved=await f.call({action:'managed/sync/status',report});
 assert.equal(saved.latestWindowsReport.pending,0);
 assert.equal(saved.latestWindowsReport.cloudflareOwnedPendingDrive,4);
 assert.equal(saved.latestWindowsReport.lastCloudflareHandoffMicros,2499000);
 const developer=await f.call({action:'developer/managed/sync/status',schoolId:A},'developer');
 assert.equal(developer.latestWindowsReport.cloudflareOwnedPendingDrive,4);
 for(const extra of [{cloudflareOwnedPendingDrive:-1},{cloudflareOwnedPendingDrive:100001},{lastCloudflareHandoffMicros:86400000001},{lastCloudflareHandoffMicros:'2499000'}])
  await assert.rejects(f.call({action:'managed/sync/status',report:{...base,...extra}}),e=>e.status===400);
 assert.equal(f.docs.get('platform_schools/'+B).syncWindowsReport,undefined);
});

test('Cloudflare status includes exact school record lane without claiming all-lane Drive verification',async()=>{
 const calls=[];
 const cloudflareSync={
  enabled:school=>school===A,
  rpc:async(school,lane,request)=>{
   calls.push({school,lane,request});
   assert.equal(school,A);
   assert.deepEqual(request,{command:'stats'});
   return lane==='records'
    ?{pending:3,needsAttention:1,due:time+10000}
    :lane==='notices'
    ?{pending:0,needsAttention:0,due:null}
    :{pendingPartitions:1,needsAttention:1};
  }
 };
 const f=fixture(undefined,{cloudflareSync});
 const result=await f.call({action:'managed/cloudflare/status'});
 assert.equal(result.schoolId,A);
 assert.equal(result.enabled,true);
 assert.equal(result.statusScope,'records_notices_delivery');
 assert.equal(result.observedAt,time);
 assert.deepEqual(result.records,{pending:3,needsAttention:1,due:time+10000});
 assert.deepEqual(calls.map(x=>x.lane).sort(),['delivery','notices','records']);
 assert.equal(result.driveVerified,undefined,
  'A Cloudflare queue count can never attest Google provider ACK');
 await assert.rejects(f.call({action:'managed/cloudflare/status',schoolId:B}),e=>e.status===403);
 assert.equal((await f.call({action:'managed/cloudflare/status'},'B')).enabled,false);
 assert.equal(calls.length,3,'A disabled school cannot read another tenant queue');
});
test('malformed or unavailable record statistics fail closed, not as successful backup',async()=>{
 const cloudflareSync={
  enabled:school=>school===A,
  rpc:async(_,lane)=>{
   if(lane==='records')return {pending:0,needsAttention:-1};
   return lane==='notices'?{pending:0,needsAttention:0}
    :{pendingPartitions:0,needsAttention:0};
  }
 };
 const f=fixture(undefined,{cloudflareSync});
 await assert.rejects(f.call({action:'managed/cloudflare/status'}),e=>e.status===502);
});

test('school scoped hourly records inventory is read-only and never reports school-wide Drive completion',async()=>{
 const hourMs=3600000,observedAt=time,firstHourMillis=Math.floor(time/hourMs)*hourMs-23*hourMs;
 const hours=Array.from({length:24},(_,i)=>({hourStartMillis:firstHourMillis+i*hourMs,
  admitted:i===23?2:0,proofStamped:0,completedWithoutProofTimestamp:i===23?1:0,
  pending:i===23?1:0,retry:0,processing:0,needsAttention:0}));
 let calls=0;
 const cloudflareSync={enabled:school=>school===A,rpc:async(school,lane,request)=>{
  calls++;assert.equal(school,A);assert.equal(lane,'records');
  assert.deepEqual(request,{command:'backupHourly'});
  return {version:1,schoolId:A,scope:'records_spool_only',
   countUnit:'original_spool_entries_batches_count_as_one',
   observedAt,firstHourMillis,hours,unattributed:0};
 }};
 const f=fixture(undefined,{cloudflareSync});
 const result=await f.call({action:'managed/cloudflare/backupHourly'});
 assert.equal(result.enabled,true);
 assert.equal(result.statusScope,'records_spool_only');
 assert.equal(result.hours.length,24);
 assert.equal(result.hours[23].admitted,2);
 assert.equal(result.hours[23].proofStamped,0);
 assert.equal(result.driveVerified,undefined);
 assert.equal(result.googleDriveComplete,undefined);
 assert.equal(calls,1);
 await assert.rejects(f.call({action:'managed/cloudflare/backupHourly',schoolId:B}),e=>e.status===403);
 assert.equal((await f.call({action:'managed/cloudflare/backupHourly'},'B')).enabled,false);
 assert.equal(calls,1);
});
test('malformed hourly records response is rejected rather than showing fake success',async()=>{
 const f=fixture(undefined,{cloudflareSync:{enabled:school=>school===A,
  rpc:async()=>({version:1,schoolId:A,scope:'records_spool_only',
   countUnit:'original_spool_entries_batches_count_as_one',
   observedAt:time,firstHourMillis:time,hours:[{admitted:3,proofStamped:4}],unattributed:0})}});
 await assert.rejects(f.call({action:'managed/cloudflare/backupHourly'}),e=>e.status===502);
});

test('notice and attendance owner journals are bounded to authenticated school and original page',async()=>{
 const id='a'.repeat(64),calls=[];
 const cloudflareSync={enabled:school=>school===A,
  rpc:async(school,lane,request)=>{
   calls.push({school,lane,request});
   assert.equal(school,A);
   return {version:1,schoolId:A,scope:'legacyImmutableOwnerJournal',
    source:lane==='notices'?'legacy-notices':'legacy-attendance',
    lane,coverage:'one-owner-journal-only',partial:true,
    entries:[{sequence:4,id,state:'completed',acceptedAt:time-100000,
      driveOwnerReceiptPresent:true,verifiedAt:time-20000}],
    nextCursor:4};
  }};
 const f=fixture(undefined,{cloudflareSync});
 const a=await f.call({action:'managed/cloudflare/auditJournalPage',
  lane:'notices',after:3,limit:1});
 assert.equal(a.success,true);
 assert.equal(a.schoolId,A);
 assert.equal(a.source,'legacy-notices');
 assert.equal(a.statusScope,'one-owner-journal-only');
 assert.equal(a.partial,true);
 assert.equal(a.driveVerified,undefined,
  'An original owner receipt is not an independent Google byte readback');
 assert.equal(a.entries[0].driveOwnerReceiptPresent,true);
 assert.equal(a.nextCursor,4);
 const b=await f.call({action:'managed/cloudflare/auditJournalPage',
  lane:'attendance-a0',after:3,limit:1});
 assert.equal(b.source,'legacy-attendance');
 assert.equal(calls.length,2);
 assert.deepEqual(calls.map(x=>x.request),[
  {command:'auditJournalPage',after:3,limit:1},
  {command:'auditJournalPage',after:3,limit:1}]);
 await assert.rejects(f.call({action:'managed/cloudflare/auditJournalPage',
  schoolId:B,lane:'notices'}),e=>e.status===403);
 assert.equal(calls.length,2,'Cross-school requests cannot touch the Worker');
 const disabled=await f.call({action:'managed/cloudflare/auditJournalPage',lane:'notices'},'B');
 assert.equal(disabled.enabled,false);
 assert.equal(calls.length,2);
});
test('owner journal rejects unrelated lanes, unbounded cursor and malformed provider rows',async()=>{
 let calls=0;
 const ok={version:1,schoolId:A,scope:'legacyImmutableOwnerJournal',
  source:'legacy-notices',lane:'notices',coverage:'one-owner-journal-only',
  partial:true,nextCursor:null,entries:[{sequence:1,id:'a'.repeat(64),
   state:'pending',acceptedAt:time-1000,driveOwnerReceiptPresent:false,verifiedAt:null}]};
 let reply=ok;
 const f=fixture(undefined,{cloudflareSync:{enabled:school=>school===A,
  rpc:async()=>{calls++;return reply;}}});
 for(const args of [
  {lane:'records'}, {lane:'file-'+'f'.repeat(64)},
  {lane:'attendance-zz'}, {lane:'notices',after:-1},
  {lane:'notices',limit:0}, {lane:'notices',limit:101},
  {lane:'notices',after:2.4}, {lane:'notices',limit:1.5}])
  await assert.rejects(f.call({action:'managed/cloudflare/auditJournalPage',...args}),
   e=>e.status===400);
 assert.equal(calls,0,'All invalid pages fail before Worker access');
 const bad=[
  {...ok,schoolId:B},
  {...ok,scope:'all-original-owner-drive-readbacks'},
  {...ok,partial:false},
  {...ok,nextCursor:99},
  {...ok,entries:[{...ok.entries[0],driveOwnerReceiptPresent:false,
    verifiedAt:time-100}]},
  {...ok,entries:[{...ok.entries[0],state:'pending',
    driveOwnerReceiptPresent:true,verifiedAt:time-100}]},
  {...ok,entries:[{...ok.entries[0],id:'untrusted'}]},
  {...ok,entries:[{...ok.entries[0],sequence:0}]},
  {...ok,entries:[{...ok.entries[0],acceptedAt:time,
    driveOwnerReceiptPresent:true,verifiedAt:time-100,state:'completed'}]}
 ];
 for(const value of bad){
  reply=value;
  await assert.rejects(f.call({action:'managed/cloudflare/auditJournalPage',lane:'notices'}),
   e=>e.status===502);
 }
 assert.equal(calls,bad.length);
});

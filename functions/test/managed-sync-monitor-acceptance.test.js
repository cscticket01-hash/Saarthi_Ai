'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {fixture,A,B,time}=require('./helpers/managed-school-broker');

test('measured media remains separate from uploads and unknown inventory never invents a count',async()=>{
 const base={pending:0,needsAttention:0,verifiedReceiptCount:0,lastCloudAckMillis:0};
 const f=fixture();
 const verified=await f.call({action:'managed/sync/status',report:{...base,mediaPending:12,mediaInventoryState:'PARTIAL',lastClientSyncMillis:time-1000}});
 assert.equal(verified.latestWindowsReport.pending,0);
 assert.equal(verified.latestWindowsReport.mediaPending,12);
 assert.equal(verified.latestWindowsReport.mediaInventoryState,'PARTIAL');
 assert.equal(verified.serverEvidence,null);
 for(const extra of [{mediaPending:0},{mediaPending:0,mediaInventoryState:'UNKNOWN'},
   {mediaPending:-1,mediaInventoryState:'VERIFIED'},{mediaPending:100001,mediaInventoryState:'PARTIAL'},
   {lastClientSyncMillis:time+300001}])await assert.rejects(f.call({action:'managed/sync/status',report:{...base,...extra}}),e=>e.status===400);
 const missing=await fixture().call({action:'managed/sync/status',report:{...base,mediaInventoryState:'UNKNOWN'}});
 assert.equal(missing.latestWindowsReport.mediaPending,undefined);
});

test('stale client observations retain their timestamp and never imply a backend ACK',async()=>{
 const f=fixture();
 f.docs.get('platform_schools/'+A).syncWindowsReport={version:1,receivedAt:time-600001,source:'latest_windows_client_report',pending:3,needsAttention:1,verifiedReceiptCount:0,lastCloudAckMillis:0};
 const own=await f.call({action:'managed/sync/status'});
 const central=await f.call({action:'developer/managed/sync/status',schoolId:A},'developer');
 assert.equal(own.measuredAt-own.latestWindowsReport.receivedAt,600001);
 assert.equal(central.latestWindowsReport.receivedAt,time-600001);
 assert.equal(own.serverEvidence,null);assert.equal(central.serverEvidence,null);
 assert.equal(f.sent.length,0);
});

test('switching selected developer school never retains another school client/server evidence',async()=>{
 const f=fixture();
 f.docs.get('platform_schools/'+A).syncWindowsReport={receivedAt:time,pending:3,appVersion:'2.1.106-test'};
 f.docs.get('platform_schools/'+A).syncServerEvidence={version:1,observedAt:time,outcome:'durable_ack'};
 const first=await f.call({action:'developer/managed/sync/status',schoolId:A},'developer');
 assert.equal(first.latestWindowsReport.pending,3);
 const other=await f.call({action:'developer/managed/sync/status',schoolId:B},'developer');
 assert.equal(other.schoolId,B);assert.equal(other.latestWindowsReport,null);assert.equal(other.serverEvidence,null);
 const ownOther=await f.call({action:'managed/sync/status'},'B');
 assert.equal(ownOther.latestWindowsReport,null);assert.equal(ownOther.serverEvidence,null);
 await assert.rejects(f.call({action:'managed/sync/status',schoolId:A},'B'),e=>e.status===403);
 const again=await f.call({action:'developer/managed/sync/status',schoolId:A},'developer');
 assert.equal(again.latestWindowsReport.pending,3);assert.equal(again.serverEvidence.outcome,'durable_ack');
 assert.equal(f.sent.length,0);
});

'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {prepareDisasterFixture}=require('./disaster_fixture_resume.cjs');
const school='vs-'+'a'.repeat(32),identity={id:'disaster-rehearsal-123-2',resumed:true};
const pdf=Buffer.from('%PDF-1.4\nSynthetic TEST disaster binary\n%%EOF\n');
function row(){return {schoolId:school,syntheticTest:true,title:'Disposable disaster recovery fixture',fileId:'verified-file',capturedAt:12345,_syncOperationId:identity.id+'-create',_syncRevision:'acknowledged-revision'};}
function reader(value,bytes=pdf,calls=[]){return async body=>{
 calls.push(body.action);assert.ok(!body.operation || body.operation==='read','Resume must never write a fixture');
 return body.action==='managed/records'?{success:true,schoolId:school,syncProtocol:2,pointRead:true,records:value?{[identity.id]:value}:{}}:{success:true,schoolId:school,base64:bytes.toString('base64')};
};}
test('resume verifies original tenant, operation, revision and exact Drive bytes without writes',async()=>{
 const calls=[],report={};const result=await prepareDisasterFixture(reader(row(),pdf,calls),identity,school,pdf,report);
 assert.deepEqual(calls,['managed/records','managed/file/read']);assert.equal(result.original.recordRevision,'acknowledged-revision');assert.equal(result.upload.fileId,'verified-file');assert.equal(report.fixtureAckMode,'verified_existing_original');
});
test('missing or foreign source never recreates old recovery fixture',async()=>{
 for(const value of [null,{...row(),schoolId:'vs-'+'b'.repeat(32)}])await assert.rejects(prepareDisasterFixture(reader(value),identity,school,pdf,{}));
});
test('changed original operation, payload, revision or deletion fails closed',async()=>{
 for(const change of [{_syncOperationId:'other-create'},{title:'Changed'},{capturedAt:12346},{_syncRevision:''},{_syncDeleted:true},{unexpectedBusinessField:'changed'}])
  await assert.rejects(prepareDisasterFixture(reader({...row(),...change}),identity,school,pdf,{}));
});
test('retained file must still contain the exact original bytes',async()=>{
 await assert.rejects(prepareDisasterFixture(reader(row(),Buffer.from('different')),identity,school,pdf,{}));
});
test('full signed point proof is required before accepting original metadata',async()=>{
 await assert.rejects(prepareDisasterFixture(async()=>({success:true,schoolId:school,syncProtocol:2,pointRead:false,records:{[identity.id]:row()}}),identity,school,pdf,{}));
});
test('fresh fixture still requires an actual upload and durable record ACK',async()=>{
 const calls=[];const result=await prepareDisasterFixture(async body=>{calls.push(body);return body.action==='managed/file/upload'?{fileId:'new-file'}:{recordRevision:'new-ack'};},{...identity,resumed:false},school,pdf,{});
 assert.equal(calls.length,2);assert.equal(calls[1].operation,'write');assert.equal(calls[1].expectedRecordRevision,'');assert.equal(result.original.recordRevision,'new-ack');
});

test('resume monitor distinguishes a verified read from a new durable write ACK',()=>{
 const {fixtureMonitorVerified}=require('./disaster_fixture_resume.cjs');
 const read={version:1,observedAt:123456,outcome:'verified_response',stage:'managed_records',protocol:2};
 assert.equal(fixtureMonitorVerified(read,true),true);
 assert.equal(fixtureMonitorVerified(read,false),false);
 assert.equal(fixtureMonitorVerified({...read,outcome:'durable_ack'},false),true);
 const file={...read,stage:'managed_file',protocol:1};
 assert.equal(fixtureMonitorVerified(file,true,'managed_file'),false);
 assert.equal(fixtureMonitorVerified(file,false,'managed_file'),false);
 assert.equal(fixtureMonitorVerified(file,true),false);
 assert.equal(fixtureMonitorVerified({...file,protocol:2},true,'managed_file'),false);
 assert.equal(fixtureMonitorVerified({...file,outcome:'durable_ack'},true,'managed_file'),false);
 assert.equal(fixtureMonitorVerified({...file,version:2},true,'managed_file'),false);
 for(const bad of [{...read,outcome:'failed'},{...read,protocol:1},{...read,observedAt:0},{...read,stage:'managed_mobile'},{...read,unverifiedPayload:'forbidden'}])
  assert.equal(fixtureMonitorVerified(bad,true),false);
});

// Exercise the production broker rather than duplicating its monitoring rules.
test('actual broker retains record-read evidence after verified fixture file read',async()=>{
 const {fixture,A,time}=require('../../functions/test/helpers/managed-school-broker');
 const retained={...row(),schoolId:A};
 const f=fixture(async(_,options)=>{
  const envelope=JSON.parse(options.body),body=JSON.parse(envelope.payload);
  const result=body.action==='managed_records'
   ?{syncProtocol:2,pointRead:true,records:{[identity.id]:retained}}
   :{base64:pdf.toString('base64')};
  return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,...result})};
 });
 await prepareDisasterFixture(f.call,identity,A,pdf,{});
 const monitor=await f.call({action:'managed/sync/status'});
 assert.deepEqual(monitor.serverEvidence,{version:1,observedAt:time,
  outcome:'verified_response',stage:'managed_records',protocol:2});
 assert.equal(require('./disaster_fixture_resume.cjs').fixtureMonitorVerified(monitor.serverEvidence,true),true);
 assert.equal(monitor.latestWindowsReport,null);
});

test('Cloudflare notice reads leave old failure evidence until an explicit signed settings probe',async()=>{
 const {fixture,A,time}=require('../../functions/test/helpers/managed-school-broker');
 const {createCloudflareSync}=require('../../functions/cloudflare-sync');
 const {prepareMonitorProbe,fixtureMonitorVerified}=require('./disaster_fixture_resume.cjs');
 const edge=createCloudflareSync({url:'https://edge.example/',key:'x'.repeat(32),schools:[A],fetchImpl:async()=>
  new Response(JSON.stringify({success:true,schoolId:A,value:{initialized:true,records:{[identity.id]:{...row(),schoolId:A}},revision:'cf-current'}}),{status:200})});
 const calls=[];
 const f=fixture(async(_,options)=>{
  const envelope=JSON.parse(options.body),request=JSON.parse(envelope.payload);calls.push(request);
  const proof=request.action==='managed_file'?{base64:pdf.toString('base64')}:{syncProtocol:2,pointRead:true,records:{}};
  return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,...proof})};
 },{cloudflareSync:edge,liveSyncSchools:[A]});
 f.docs.get('platform_schools/'+A).syncServerEvidence={version:1,observedAt:time-1000,outcome:'failed',stage:'managed_records',code:'SCRIPT_UNVERIFIED'};
 await prepareDisasterFixture(f.call,identity,A,pdf,{});
 assert.equal((await f.call({action:'managed/sync/status'})).serverEvidence.outcome,'failed');
 const report={};await prepareMonitorProbe(f.call,A,report);
 const monitor=await f.call({action:'managed/sync/status'});
 assert.equal(fixtureMonitorVerified(monitor.serverEvidence,true),true);
 assert.equal(monitor.serverEvidence.code,undefined);assert.equal(monitor.latestWindowsReport,null);
 assert.equal(report.monitorProbe.readOnly,true);
 assert.deepEqual(calls.map(b=>b.action),['managed_file','managed_records']);
 assert.equal(calls[1].collection,'school_settings');assert.equal(calls[1].operation,'read');
});
test('a signed monitor probe rejects missing point proof and foreign school without writing records',async()=>{
 const {prepareMonitorProbe}=require('./disaster_fixture_resume.cjs');
 for(const value of [{success:true,schoolId:school,syncProtocol:2,pointRead:false,records:{}},
  {success:true,schoolId:'foreign',syncProtocol:2,pointRead:true,records:{}}])
  await assert.rejects(prepareMonitorProbe(async request=>{assert.equal(request.operation,'read');return value;},school,{}));
});

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

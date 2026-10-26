'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {fixture,A,B}=require('./helpers/managed-school-broker');
const {storage}=require('./helpers/managed-storage');
const op=id=>({collection:'school_notices',id,operation:'write',syncProtocol:2,operationId:'broker-batch-'+id+'-00001',expectedRecordRevision:'',data:{title:id}});
test('authenticated broker and paste-ready Script retain individual batch receipts through replay',async()=>{
 const s=storage({bundle:true,lifecycle:true}),f=fixture(async(url,options)=>({ok:true,status:200,
  text:async()=>JSON.stringify(s.call(JSON.parse(JSON.parse(options.body).payload)))}));
 const request={action:'managed/records/batch',schoolId:A,operations:[op('one'),op('two')]};
 const first=await f.call(request),again=await f.call(request);
 assert.equal(first.acknowledgements.length,2);assert(first.acknowledgements.every(r=>r.success));
 assert.deepEqual(first.acknowledgements.map(r=>r.recordRevision),again.acknowledgements.map(r=>r.recordRevision));
 await assert.rejects(f.call({...request,schoolId:B}),e=>e.status===403);
});
test('invalid batch or secret fields are rejected before any Script write',async()=>{
 const f=fixture();
 for(const operations of [[op('one'),op('one')],[op('one'),{...op('two'),operationId:op('one').operationId}],
 [op('one'),{...op('two'),data:{password:'forbidden'}}]]) {
  await assert.rejects(f.call({action:'managed/records/batch',schoolId:A,operations}),e=>e.status===400);
 }
 assert.equal(f.sent.length,0);
});

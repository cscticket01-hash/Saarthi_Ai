'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {storage,A}=require('./helpers/managed-storage');
const op=(id,revision='',title=id)=>({operation:'write',collection:'school_notices',id,syncProtocol:2,
 operationId:'batch-operation-'+id+'-00001',expectedRecordRevision:revision,data:{schoolId:A,title}});
test('paste-ready batch has per-record durable ACKs; replay returns original revisions',()=>{
 const s=storage({bundle:true,lifecycle:true}),request={action:'managed_records_batch',operations:[op('one'),op('two')]};
 const first=s.call(request);assert.equal(first.success,true);assert.equal(first.acknowledgements.length,2);
 const again=s.call(request);assert.deepEqual(again.acknowledgements.map(r=>r.recordRevision),first.acknowledgements.map(r=>r.recordRevision));
 const read=s.call({action:'managed_records',operation:'read',collection:'school_notices',syncProtocol:2});
 assert.equal(read.records.one.title,'one');assert.equal(read.records.two.title,'two');
});
test('one stale row does not manufacture ACK or block an independent row',()=>{
 const s=storage({bundle:true,lifecycle:true});s.call({action:'managed_records_batch',operations:[op('one')]});
 const result=s.call({action:'managed_records_batch',operations:[{...op('one'),operationId:'new-operation-0001'},op('two')]});
 assert.equal(result.acknowledgements[0].success,false);assert.equal(result.acknowledgements[1].success,true);
});
test('batch admission rejects duplicate record keys, operation IDs and foreign schools before writes',()=>{
 for(const operations of [[op('one'),op('one')],[op('one'),{...op('two'),operationId:op('one').operationId}],
 [op('one'),{...op('two'),data:{schoolId:'foreign',title:'bad'}}]]) {
  const s=storage({bundle:true,lifecycle:true}),result=s.call({action:'managed_records_batch',operations});
  assert.equal(result.success,false);
  const read=s.call({action:'managed_records',operation:'read',collection:'school_notices',syncProtocol:2});assert.equal(Object.keys(read.records).length,0);
 }
});

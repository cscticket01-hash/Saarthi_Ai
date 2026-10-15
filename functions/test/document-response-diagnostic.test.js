'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {documentResponseDiagnostic}=require('../document-response-diagnostic');
const {fixture,A}=require('./helpers/managed-school-broker');
test('document contract logs expose missing protocol/revisions without record values',()=>{
 const secret='do-not-log-secret',id='private-person-document';
 const response={success:true,schoolId:A,records:{[id]:{schoolId:A,_syncDeleted:true,
  studentName:'private name',fileBase64:'private bytes',fileUrl:'private-url'}}};
 const read=documentResponseDiagnostic({action:'managed_records',collection:'documents',operation:'read',syncProtocol:2},response,A,secret);
 assert.equal(read.responseProtocol2,false);assert.equal(read.records[0].serverRevision,false);
 assert.equal(read.records[0].documentRevision,false);assert.equal(read.records[0].tombstone,true);
 const mutation=documentResponseDiagnostic({action:'managed_records',collection:'documents',operation:'delete',id,expectedRevision:'',expectedRecordRevision:''},{...response,syncProtocol:2,recordRevision:'private-revision'},A,secret);
 assert.equal(mutation.fingerprint,read.records[0].fingerprint);assert.equal(mutation.acknowledgedRevision,true);
 const log=JSON.stringify([read,mutation]);for(const value of [secret,id,A,'private name','private bytes','private-url','private-revision'])assert(!log.includes(value));
 assert.notEqual(documentResponseDiagnostic({action:'managed_records',collection:'documents',operation:'delete',id},{},'other-school',secret).fingerprint,mutation.fingerprint);
 assert.equal(documentResponseDiagnostic({action:'managed_records',collection:'students_directory'},{},A,secret),null);
 const many={};for(let i=0;i<50;i++)many[i]={};const bounded=documentResponseDiagnostic({action:'managed_records',collection:'documents',operation:'read'},{records:many},A,secret);assert.equal(bounded.records.length,10);assert.equal(bounded.recordCount,50);assert.equal(bounded.sampleLimited,true);
});
test('authenticated broker emits contract metadata and logging failure cannot change response',async()=>{
 for(const throwing of [false,true]){
  const logs=[],reply={success:true,schoolId:A,syncProtocol:2,records:{synthetic:{schoolId:A,_syncDeleted:true,_syncRevision:'server'}}};
  const f=fixture(async()=>({ok:true,status:200,text:async()=>JSON.stringify(reply)}),{documentDiagnostics:entry=>{logs.push(entry);if(throwing)throw Error('logger unavailable');}});
  const result=await f.call({action:'managed/records',operation:'read',collection:'documents',syncProtocol:2});
  assert.equal(result.records.synthetic._syncRevision,'server');
  assert.equal(logs.filter(x=>x.event==='document_response_contract').length,1);
 }
});

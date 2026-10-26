'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
const {documentDeleteContracts}=require('./helpers/document-delete-contract');
test('Windows delete ACK fixtures match the actual complete signed Apps Script bundle',()=>{
 const cases=documentDeleteContracts();
 const fixture=JSON.parse(fs.readFileSync(path.join(__dirname,'../../test/fixtures/managed_document_delete_contract.json'),'utf8'));
 assert.deepEqual(cases,fixture);
 for(const c of cases){
  const row=c.readback.records[c.payload.documentId];
  assert.equal(c.deleteResponse.success,true);assert.equal(row._syncDeleted,true);
  assert.equal(c.deleteResponse.recordRevision,row._syncRevision);
  if(c.name!=='existing')assert.equal(Object.hasOwn(row,'documentRevision'),false);
 }
});

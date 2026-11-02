'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createCloudflareDelivery}=require('../cloudflare-delivery');
const {storage,A}=require('./helpers/managed-storage');
const id='Class 1_Roll_12',oldGeneration='p-'+'a'.repeat(32),newGeneration='p-'+'b'.repeat(32);
function setup(){
 const s=storage({lifecycle:true,bundle:true});
 const created=s.call({action:'managed_records',collection:'students_directory',operation:'write',id,syncProtocol:2,operationId:'first-student-create-0001',expectedRecordRevision:'',data:{schoolId:A,name:'Synthetic',class:'Class 1',rollNo:'12',mobileStableId:oldGeneration}});
 assert.equal(created.success,true,JSON.stringify(created));
 const deleted=s.call({action:'managed_records',collection:'students_directory',operation:'delete',id,syncProtocol:2,operationId:'first-student-delete-0001',expectedRecordRevision:created.recordRevision,deletedStudentGeneration:oldGeneration});
 assert.equal(deleted.success,true,JSON.stringify(deleted));
 return {s,deleted};
}
async function drain(request,deliver){
 let finished;
 const edge={rpc:async(s,l,b)=>{
  if(b.command==='pending')return [{id:'a'.repeat(64),payload:JSON.stringify(request)}];
  if(b.command==='claim')return true;
  if(b.command==='finish'){finished=b.values;return true;}
  throw Error('unexpected command');
 }};
 const result=await createCloudflareDelivery({edge,diagnostics:()=>{}}).drain(A,'records',deliver);
 return {result,finished};
}
test('actual signed GS tombstone ACK completes cancelled local recreation without changing original tombstone',async()=>{
 const {s,deleted}=setup();
 const request={action:'managed_records',collection:'students_directory',operation:'delete',id,syncProtocol:2,operationId:'cancel-local-recreation-0001',expectedRecordRevision:deleted.recordRevision,deletedStudentGeneration:newGeneration};
 const before=s.call({action:'managed_records',collection:'students_directory',operation:'read',syncProtocol:2}).records[id];
 const {result,finished}=await drain(request,r=>s.call(r));
 assert.equal(result.processed,1);assert.equal(finished.state,'completed');
 assert.equal(finished.result.record._syncOperationId,'first-student-delete-0001');
 assert.deepEqual(s.call({action:'managed_records',collection:'students_directory',operation:'read',syncProtocol:2}).records[id],before);
});
test('tombstone shortcut rejects writes, foreign/mismatched records, and unbound/newer revisions',async()=>{
 const {deleted}=setup();
 const request={action:'managed_records',collection:'students_directory',operation:'delete',id,syncProtocol:2,operationId:'cancel-local-recreation-0001',expectedRecordRevision:deleted.recordRevision};
 for(const variant of ['write','unbound','older','live','foreign','wrong-id','missing-revision']){
  const r={...request},ack=JSON.parse(JSON.stringify(deleted));
  if(variant==='write')r.operation='write';
  if(variant==='unbound')r.expectedRecordRevision='';
  if(variant==='older')r.expectedRecordRevision='older';
  if(variant==='live')ack.record._syncDeleted=false;
  if(variant==='foreign')ack.record.schoolId='vs-'+'f'.repeat(32);
  if(variant==='wrong-id')ack.record.id='another-student';
  if(variant==='missing-revision')delete ack.record._syncRevision;
  const {finished}=await drain(r,async()=>ack);
  assert.equal(finished.state,'retry',variant);assert.equal(finished.failureCode,'ACK_UNVERIFIED',variant);
 }
});

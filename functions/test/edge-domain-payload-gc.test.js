'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createCloudflareDelivery}=require('../cloudflare-delivery');
const {deliveryId}=require('../live-domain-delivery');
const {storage,A}=require('./helpers/managed-storage');
const request=(id='config',op='settings-operation-00001')=>({action:'managed_records',collection:'fee_settings',operation:'write',id,syncProtocol:2,operationId:op,expectedRecordRevision:'',data:{schoolId:A,name:id,amount:100}});
function setup(original,gc=true){
 const id=original.action==='managed_records_batch'?'b'.repeat(64):deliveryId(A,original),commands=[];
 const row={id,payload:JSON.stringify(original),response:null,state:'pending',due:0};
 const edge={rpc:async(s,l,b)=>{
  assert.equal(s,A);assert.equal(l,'records');commands.push(b);
  if(b.command==='pending')return row.state==='pending'?[row]:[];
  if(b.command==='claim')return true;
  if(b.command==='finish'){row.state=b.values.state;row.response=b.values;if(b.values.payloadPurged===true)row.payload='';return true;}
  if(b.command==='status')return row;
  if(b.command==='enqueue')return {};
  throw Error('Unexpected '+b.command);
 }};
 return {row,commands,delivery:createCloudflareDelivery({edge,payloadGcEnabled:gc,diagnostics:()=>{}})};
}
test('actual signed Apps Script proof permits domain request/result GC and verified status rehydrates from school Drive',async()=>{
 const s=storage({lifecycle:true,bundle:true}),r=request(),f=setup(r),calls=[];
 const deliver=async body=>{calls.push(body);return s.call(body);};
 assert.equal((await f.delivery.drain(A,'records',deliver)).processed,1);
 assert.equal(f.row.payload,'');assert.equal(f.row.response.payloadPurged,true);assert.equal(f.row.response.result.record,null);assert.equal(f.row.response.identity.operationId,r.operationId);assert.equal(f.row.response.identity.data,undefined);assert.equal(JSON.stringify(f.row.response).includes('amount'),false);
 const originalRevision=f.row.response.result.recordRevision;
 const status=await f.delivery.status(A,'records',f.row.id,deliver);assert.equal(status.driveState,'verified');assert.equal(status.record.amount,100);assert.equal(status.record._syncRevision,originalRevision);assert.equal(calls.at(-1).operation,'read');
 // The same lost-ACK operation reuses the immutable receipt after payload GC.
 assert.equal((await f.delivery.record(A,r,deliver)).recordRevision,originalRevision);
 const changed=s.call({...r,operationId:'settings-operation-00002',expectedRecordRevision:originalRevision,data:{...r.data,amount:200}});assert.equal(changed.success,true);
 await assert.rejects(f.delivery.status(A,'records',f.row.id,deliver),e=>e.code==='RECORD_REVISION_CONFLICT');
});
test('GC remains off by default and never clears an unreviewed collection',async()=>{
 for(const [r,gc]of [[request(),false],[{...request(),collection:'unreviewed_records'},true]]){
  const f=setup(r,gc),canonical={...r.data,_syncRevision:'drive-real',_syncOperationId:r.operationId};
  await f.delivery.drain(A,'records',async()=>({success:true,schoolId:A,syncProtocol:2,recordRevision:'drive-real',record:canonical}));
  assert.notEqual(f.row.payload,'');assert.equal(f.row.response.payloadPurged,undefined);assert.deepEqual(f.row.response.result.record,canonical);
 }
});
test('missing canonical proof requires signed point read and wrong content cannot purge staged work',async()=>{
 const r=request(),f=setup(r),calls=[];
 await f.delivery.drain(A,'records',async body=>{calls.push(body);return body.operation==='read'?{success:true,schoolId:A,syncProtocol:2,pointRead:true,records:{config:{...r.data,amount:999,_syncRevision:'drive-real',_syncOperationId:r.operationId}}}:{success:true,schoolId:A,syncProtocol:2,recordRevision:'drive-real'};});
 assert.equal(calls.length,2);assert.equal(f.row.state,'retry');assert.notEqual(f.row.payload,'');assert.equal(f.row.response.payloadPurged,undefined);assert.equal(f.row.response.failureCode,'DOMAIN_CONTENT_UNVERIFIED');
});
test('all-success domain batch scrubs every proof together while a failed batch retains all payloads',async()=>{
 const operations=[request('first','batch-operation-00001'),request('second','batch-operation-00002')];
 for(const failed of [false,true]){
  const f=setup({action:'managed_records_batch',operations});
  await f.delivery.drain(A,'records',async body=>({success:true,schoolId:A,syncProtocol:2,recordWriteBatchVersion:1,acknowledgements:body.operations.map((r,index)=>failed&&index===1?{success:false,operationId:r.operationId,code:'SCRIPT_RECORD_REVISION_CONFLICT'}:{success:true,operationId:r.operationId,recordRevision:'drive-'+index,record:{...r.data,_syncRevision:'drive-'+index,_syncOperationId:r.operationId}})}));
  assert.equal(f.row.state,'completed');
  if(failed){assert.notEqual(f.row.payload,'');assert.equal(f.row.response.payloadPurged,undefined);assert.equal(f.row.response.result.acknowledgements[0].record.amount,100);}
  else {assert.equal(f.row.payload,'');assert.equal(f.row.response.payloadPurged,true);assert(f.row.response.result.acknowledgements.every(ack=>ack.record===null&&ack.recordSource));}
 }
});
test('canonical GS proof clears person, document, backup and school-config payloads without admitting tentative projections',async()=>{
 const {createLiveDomainDelivery}=require('../live-domain-delivery');
 for(const collection of ['students_directory','teachers_directory','documents','backups','school_config']){
  const s=storage({lifecycle:true,bundle:true});
  let data={schoolId:A,name:'School data'};
  if(collection==='students_directory')data={schoolId:A,name:'Synthetic student',class:'Class 1',rollNo:'2',mobileStableId:'p-'+'c'.repeat(32)};
  if(collection==='teachers_directory')data={schoolId:A,name:'Synthetic teacher',teacherId:'T-0001'};
  if(collection==='documents')data={schoolId:A,name:'Card',documentRevision:'document-one',fileUrl:'https://drive.google.com/file/d/test/view'};
  const r={...request('one','generic-collection-create-0001'),collection,data},f=setup(r);
  const sent=async body=>s.call(body);
  assert.equal((await f.delivery.drain(A,'records',sent)).processed,1,collection);
  assert.equal(f.row.payload,'',collection);assert.equal(f.row.response.result.record,null,collection);
  const restored=await f.delivery.status(A,'records',f.row.id,sent);assert.equal(restored.record.name,data.name);assert.equal(restored.record._syncOperationId,r.operationId);
  assert.equal(createLiveDomainDelivery({}).handles(r),false,'GC permission cannot expand pre-Drive projection permission');
 }
});
test('student and versioned-document deletions purge only after verified canonical tombstones',async()=>{
 for(const collection of ['students_directory','documents']){
  const s=storage({lifecycle:true,bundle:true}),data=collection==='students_directory'?{schoolId:A,name:'Synthetic student',class:'Class 1',rollNo:'2',mobileStableId:'p-'+'c'.repeat(32)}:{schoolId:A,name:'Card',documentRevision:'document-one'};
  const created=s.call({...request('one','deletion-parent-create-0001'),collection,data});assert.equal(created.success,true);
  const deletion={...request('one','canonical-delete-operation-0001'),collection,operation:'delete',expectedRecordRevision:created.recordRevision,...(collection==='documents'?{expectedRevision:'document-one'}:{})};delete deletion.data;
  const f=setup(deletion),sent=async body=>s.call(body);
  assert.equal((await f.delivery.drain(A,'records',sent)).processed,1,collection);assert.equal(f.row.payload,'',collection);
  const restored=await f.delivery.status(A,'records',f.row.id,sent);assert.equal(restored.record._syncDeleted,true);assert.equal(restored.record._syncOperationId,deletion.operationId);
 }
});

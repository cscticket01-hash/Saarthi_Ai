'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const {storage,A,B}=require('./helpers/managed-storage');
function setup(collection='students_directory') {
 const f=storage();f.props.set('VS_RECYCLE_VERSION','1');
 const first=f.call({action:'managed_records',operation:'write',collection,id:'row',syncProtocol:2,operationId:'create_operation_0001',expectedRecordRevision:'',data:{schoolId:A,name:'Original',capturedAt:123}});
 assert.equal(first.success,true);
 const deletion={action:'managed_records',operation:'delete',collection,id:'row',syncProtocol:2,operationId:'delete_operation_0001',expectedRecordRevision:first.recordRevision};
 const deleted=f.call(deletion);assert.equal(deleted.success,true);
 const tomb=f.call({action:'managed_records',operation:'read',collection,syncProtocol:2}).records.row;
 return {f,collection,deletion,deleted,tomb};
}
function request(t,operation='restore') {return {action:'managed_recycle',operation,fileId:t.tomb._syncRecycleFileId,operationId:'restore_operation_0001',expectedRecordRevision:t.deleted.recordRevision};}
function afterWindow(t,run) {
 const RealDate=t.f.context.Date;
 t.f.context.Date=class extends RealDate {static now(){return t.tomb._syncRecycleUntil+1;}};
 try{return run();}finally{t.f.context.Date=RealDate;}
}
test('recycle defaults off and never changes existing school delete behavior',()=>{
 const f=storage();assert.equal(f.call({action:'managed_health'}).recycleVersion,0);
 assert.equal(f.call({action:'managed_recycle',operation:'restore',fileId:'none',operationId:'restore_operation_0001',expectedRecordRevision:''}).success,false);
});
test('versioned deletion retains verified original snapshot; same-operation retry retains its identity',()=>{
 const t=setup();const s=JSON.parse(t.f.all.get(t.tomb._syncRecycleFileId).text);
 assert.equal(s.data.name,'Original');assert.equal(s.data.capturedAt,123);assert.equal(s.recoverUntil-s.deletedAt,86400000);
 assert.equal(t.f.call(t.deletion).recordRevision,t.deleted.recordRevision);
 assert.equal(t.f.call({action:'managed_records',operation:'read',collection:t.collection}).records.row,undefined);
});
test('authorized restore preserves original timestamp, changes revision and survives lost ACK retry',()=>{
 const t=setup(),b=request(t);const first=t.f.call(b);assert.equal(first.success,true);assert.notEqual(first.recordRevision,t.deleted.recordRevision);
 assert.equal(t.f.call(b).recordRevision,first.recordRevision);
 assert.equal(t.f.call({...b,expectedRecordRevision:'changed'}).success,false);
 const row=t.f.call({action:'managed_records',operation:'read',collection:t.collection,syncProtocol:2}).records.row;
 assert.equal(row.name,'Original');assert.equal(row.capturedAt,123);assert.equal(row._syncDeleted,undefined);
 assert.equal(t.f.all.get(t.tomb._syncRecycleFileId).trash,undefined);
});
test('stale deletion/restore cannot overwrite restored newer edits',()=>{
 const t=setup();const restored=t.f.call(request(t));
 const edit=t.f.call({action:'managed_records',operation:'write',collection:t.collection,id:'row',syncProtocol:2,operationId:'edit_operation_00001',expectedRecordRevision:restored.recordRevision,data:{schoolId:A,name:'Newer'}});
 assert.equal(edit.success,true);assert.equal(t.f.call(request(t)).success,false);assert.equal(t.f.call(t.deletion).success,false);
 assert.equal(t.f.call({action:'managed_records',operation:'read',collection:t.collection}).records.row.name,'Newer');
});
test('foreign and tampered snapshot fail closed without altering tombstone',()=>{
 const t=setup(),b=request(t);
 const foreign=t.f.roots[B].createFile('foreign.json',t.f.all.get(b.fileId).text,'application/json');
 assert.equal(t.f.call({...b,fileId:foreign.getId()}).success,false);
 const own=t.f.all.get(b.fileId),original=own.text;const data=JSON.parse(original);data.schoolId=B;own.text=JSON.stringify(data);
 assert.equal(t.f.call(b).success,false);own.text=original;
 assert.equal(t.f.call({...b,expectedRecordRevision:'wrong'}).success,false);
 assert.equal(t.f.call({action:'managed_records',operation:'read',collection:t.collection,syncProtocol:2}).records.row._syncDeleted,true);
});
test('retention prevents early purge and expired restore; snapshot survives eligible purge',()=>{
 const t=setup();assert.equal(t.f.call(request(t,'purge')).success,false);
 afterWindow(t,()=>{
  assert.throws(()=>t.f.context.VS_managedRecycle(request(t)),/expired/);
  const purged=t.f.context.VS_managedRecycle(request(t,'purge'));assert.equal(purged.retainedSnapshot,true);assert.equal(purged.purged,false);
 });
 assert.equal(t.f.all.get(t.tomb._syncRecycleFileId).trash,undefined);
});
test('financial audit snapshot cannot be purged after the restore window',()=>{
 const t=setup('fee_payments');afterWindow(t,()=>assert.equal(t.f.context.VS_managedRecycle(request(t,'purge')).retainedAudit,true));
 assert.equal(t.f.all.get(t.tomb._syncRecycleFileId).trash,undefined);
});

test('failed snapshot verification preserves original row and permits safe retry',()=>{
 const f=storage();f.props.set('VS_RECYCLE_VERSION','1');
 const first=f.call({action:'managed_records',operation:'write',collection:'students_directory',id:'row',syncProtocol:2,operationId:'create_operation_0001',expectedRecordRevision:'',data:{schoolId:A,name:'Original'}});
 const snapshot=f.context.VS_recycleSnapshot;f.context.VS_recycleSnapshot=()=>{throw new Error('Controlled snapshot failure');};
 const deletion={action:'managed_records',operation:'delete',collection:'students_directory',id:'row',syncProtocol:2,operationId:'delete_operation_0001',expectedRecordRevision:first.recordRevision};
 assert.equal(f.call(deletion).success,false);
 assert.equal(f.call({action:'managed_records',operation:'read',collection:'students_directory'}).records.row.name,'Original');
 f.context.VS_recycleSnapshot=snapshot;assert.equal(f.call(deletion).success,true);
});
test('same-school snapshot content tampering cannot restore altered financial values',()=>{
 const t=setup('fee_payments'),file=t.f.all.get(t.tomb._syncRecycleFileId),s=JSON.parse(file.text);s.data.amount=999999;file.text=JSON.stringify(s);
 assert.equal(t.f.call(request(t)).success,false);
});
test('document binary stays recoverable for 24 hours, restores without upload and eligible purge retains tombstone',()=>{
 const crypto=require('node:crypto'),f=storage();f.props.set('VS_RECYCLE_VERSION','1');
 const id='row',revision='document-v1',key=crypto.createHash('sha256').update(id+':'+revision).digest('hex');
 const upload=f.call({action:'managed_upload',name:'Own.pdf',mime:'application/pdf',base64:Buffer.from('%PDF-1.4\n%%EOF').toString('base64'),uploadKey:key});
 const write=f.call({action:'managed_records',operation:'write',collection:'documents',id,syncProtocol:2,operationId:'create_operation_0001',expectedRecordRevision:'',expectedRevision:'',data:{schoolId:A,fileId:upload.fileId,documentRevision:revision}});
 const deletion={action:'managed_records',operation:'delete',collection:'documents',id,syncProtocol:2,operationId:'delete_operation_0001',expectedRecordRevision:write.recordRevision,expectedRevision:revision};
 const deleted=f.call(deletion);assert.equal(deleted.fileCleanup,'retained-recycle');assert.equal(f.all.get(upload.fileId).trash,undefined);
 const tomb=f.call({action:'managed_records',operation:'read',collection:'documents',syncProtocol:2}).records.row;
 const t={f,tomb,deleted};assert.equal(f.call(request(t)).success,true);assert.equal(f.all.get(upload.fileId).trash,undefined);
 const live=f.call({action:'managed_records',operation:'read',collection:'documents',syncProtocol:2}).records.row;
 const again=f.call({...deletion,operationId:'delete_operation_0002',expectedRecordRevision:live._syncRevision});
 const second={f,deleted:again,tomb:f.call({action:'managed_records',operation:'read',collection:'documents',syncProtocol:2}).records.row};
 afterWindow(second,()=>assert.equal(f.context.VS_managedRecycle(request(second,'purge')).purged,true));
 assert.equal(f.all.get(upload.fileId).trash,true);
 assert.equal(f.call({action:'managed_records',operation:'read',collection:'documents',syncProtocol:2}).records.row._syncDeleted,true);
 assert.equal(f.all.get(second.tomb._syncRecycleFileId).trash,undefined);
});

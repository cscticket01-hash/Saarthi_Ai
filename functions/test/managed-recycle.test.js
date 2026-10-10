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
test('owner TEST recycle opt-in verifies existing root and refuses original or foreign schools',()=>{
 const f=storage();assert.throws(()=>f.context.VS_enableTestRecycle(),/TEST recycle activation/);
 assert.equal(f.props.has('VS_RECYCLE_VERSION'),false);
 const school='vs-db8afb01a3be46a983c8284714d06e5d';f.props.set('VS_MANAGED_SCHOOL_ID',school);
 assert.throws(()=>f.context.VS_enableTestRecycle(),/root mismatch/);
 assert.equal(f.props.has('VS_RECYCLE_VERSION'),false);
 f.roots[A].getDescription=()=> 'VIDYA_MANAGED_SCHOOL:'+school;
 assert.equal(f.context.VS_enableTestRecycle().existingStorageRetained,true);
 assert.equal(f.props.get('VS_RECYCLE_VERSION'),'1');
 assert.equal(f.props.get('VS_MANAGED_ROOT_ID'),'rootA');
});
test('recycle inventory verifies snapshots and derives expiry without purging audit data',()=>{
 const t=setup();
 const read=()=>t.f.call({action:'managed_recycle',operation:'list',collection:t.collection,after:''});
 const r=read();assert.equal(r.success,true);assert.equal(r.entries.length,1);
 assert.equal(r.entries[0].name,'Original');assert.equal(r.entries[0].status,'recoverable');
 assert.equal(r.entries[0].deletedRevision,t.deleted.recordRevision);assert.equal(r.partial,false);
 assert.equal(afterWindow(t,()=>t.f.context.VS_managedRecycle({operation:'list',collection:t.collection,after:''})).entries[0].status,'expired');
 assert.equal(t.f.all.get(t.tomb._syncRecycleFileId).isTrashed(),false);
 t.f.all.get(t.tomb._syncRecycleFileId).text='corrupted';
 assert.equal(read().entries[0].status,'needsReview');
});
test('recycle inventory excludes foreign snapshots and rejects invalid collections/cursors',()=>{
 const t=setup();t.f.all.get(t.tomb._syncRecycleFileId).description='VIDYA_RECYCLE:'+B+':wrong';
 assert.equal(t.f.call({action:'managed_recycle',operation:'list',collection:t.collection,after:''}).entries[0].status,'needsReview');
 assert.equal(t.f.call({action:'managed_recycle',operation:'list',collection:'unknown',after:''}).success,false);
 assert.equal(t.f.call({action:'managed_recycle',operation:'list',collection:t.collection,after:42}).success,false);
});
test('recycle inventory pages at most 25 verified snapshots without skipping retained entries',()=>{
 const t=setup();
 for(let n=0;n<26;n++){
  const id='row-'+String(n).padStart(3,'0');
  const w=t.f.call({action:'managed_records',operation:'write',collection:t.collection,id,syncProtocol:2,operationId:'inventory_create_'+id,expectedRecordRevision:'',data:{schoolId:A,name:id}});
  assert.equal(w.success,true);
  assert.equal(t.f.call({action:'managed_records',operation:'delete',collection:t.collection,id,syncProtocol:2,operationId:'inventory_delete_'+id,expectedRecordRevision:w.recordRevision}).success,true);
 }
 const first=t.f.call({action:'managed_recycle',operation:'list',collection:t.collection,after:''});
 assert.equal(first.entries.length,25);assert.equal(first.partial,true);
 const second=t.f.call({action:'managed_recycle',operation:'list',collection:t.collection,after:first.nextAfter});
 assert.equal(second.entries.length,2);assert.equal(second.partial,false);
 assert.equal(new Set([...first.entries,...second.entries].map(x=>x.id)).size,27);
});
test('expiry scheduler is TEST-only, idempotent and never purges financial snapshots',()=>{
 const t=setup('fee_payments');let created=0;const triggers=[];
 t.f.context.ScriptApp={getProjectTriggers:()=>triggers,newTrigger:name=>({timeBased(){return this;},everyHours(n){assert.equal(n,1);return this;},create(){created++;triggers.push({getHandlerFunction:()=>name});}})};
 assert.throws(()=>t.f.context.VS_installTestRecycleExpiryScheduler(),/TEST recycle/);
 // Authorization guard is tested separately from the actual school's synthetic identity.
 t.f.props.set('VS_MANAGED_SCHOOL_ID','vs-db8afb01a3be46a983c8284714d06e5d');
 t.f.context.VS_installTestRecycleExpiryScheduler();t.f.context.VS_installTestRecycleExpiryScheduler();assert.equal(created,1);
 t.f.props.set('VS_MANAGED_SCHOOL_ID',A);
 t.f.context.VS_requireTestRecycleScheduler=()=>({getProperties:()=>Object.fromEntries(t.f.props),getProperty:k=>t.f.props.get(k),setProperty:(k,v)=>t.f.props.set(k,v)});
 const result=afterWindow(t,()=>t.f.context.VS_testRecycleExpiryTick());
 assert.equal(result.expired,1);assert.equal(result.destructive,false);
 assert.equal(t.f.all.get(t.tomb._syncRecycleFileId).isTrashed(),false);
});
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

test('opt-in recycle rejects unversioned deletion instead of bypassing revision protection',()=>{
 const f=storage();f.props.set('VS_RECYCLE_VERSION','1');
 f.call({action:'managed_records',operation:'write',collection:'fee_payments',id:'row',data:{schoolId:A,amount:500}});
 assert.equal(f.call({action:'managed_records',operation:'delete',collection:'fee_payments',id:'row'}).success,false);
 assert.equal(f.call({action:'managed_records',operation:'read',collection:'fee_payments'}).records.row.amount,500);
});

test('UTF-8 snapshot byte limit fails before deletion and retains the large original',()=>{
 const f=storage();f.props.set('VS_RECYCLE_VERSION','1');
 const name='अ'.repeat(210000);
 const write=f.call({action:'managed_records',operation:'write',collection:'students_directory',id:'large',syncProtocol:2,operationId:'create_operation_0001',expectedRecordRevision:'',data:{schoolId:A,name}});
 assert.equal(write.success,true);
 assert.equal(f.call({action:'managed_records',operation:'delete',collection:'students_directory',id:'large',syncProtocol:2,operationId:'delete_operation_0001',expectedRecordRevision:write.recordRevision}).success,false);
 assert.equal(f.call({action:'managed_records',operation:'read',collection:'students_directory'}).records.large.name,name);
});

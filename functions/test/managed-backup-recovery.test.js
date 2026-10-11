'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {storage,A}=require('./helpers/managed-storage');
const TEST='vs-db8afb01a3be46a983c8284714d06e5d';
function setup(){const f=storage();f.props.set('VS_MANAGED_SCHOOL_ID',TEST);f.roots[A].getDescription=()=> 'VIDYA_MANAGED_SCHOOL:'+TEST;f.context.VS_enableTestBackupRecovery();return f;}
function write(f,id,collection='school_notices',expected=''){return f.context.VS_managedRecord({operation:'write',collection,id,syncProtocol:2,operationId:'backup_create_operation_'+id,expectedRecordRevision:expected,data:{schoolId:TEST,syntheticTest:true,title:'Retained',capturedAt:123}});}
function erase(f,id,collection='school_notices'){const store=f.context.VS_managedSheet(collection),row=f.context.VS_sheetItem(store,id).row;store.sheet.getRange(row,1,1,33).setValues([Array(33).fill('')]);}
function read(f,collection='school_notices',knownRevision){return f.context.VS_managedRecord({operation:'read',collection,syncProtocol:2,knownRevision});}
test('automatic TEST recovery retains durable revision, operation and timestamp from verified Drive backup',()=>{
 const f=setup(),ack=write(f,'restore');const backup=f.context.VS_createVerifiedRecordBackup();assert.equal(backup.verified,true);assert.equal(backup.documentBinariesIncluded,false);
 const original=read(f).records.restore,head=f.props.get('VS_RECORD_REV_school_notices');erase(f,'restore');
 const recovered=read(f,'school_notices',head);assert.notEqual(recovered.unchanged,true);assert.equal(recovered.records.restore._syncRevision,ack.recordRevision);
 assert.equal(JSON.stringify(recovered.records.restore),JSON.stringify(original));
 assert.equal(JSON.parse(f.props.get('VS_LAST_RECORD_RECOVERY')).restored,1);
 assert.equal(f.context.VS_managedFile(backup.fileId).isTrashed(),false);
});
test('new accepted cloud writes invalidate older automatic recovery evidence',()=>{
 const f=setup();write(f,'old');f.context.VS_createVerifiedRecordBackup();write(f,'new');erase(f,'old');
 assert.equal(read(f).records.old,undefined);assert.equal(read(f).records.new.title,'Retained');
});
test('unchanged hourly delta checkpoint still detects missing backed-up rows',()=>{
 const f=setup();write(f,'standby');f.context.VS_createVerifiedRecordBackup();const head=f.props.get('VS_RECORD_REV_school_notices');erase(f,'standby');
 const result=f.context.VS_managedDelta({collections:['school_notices'],knownRevisions:{school_notices:head}});
 assert.notEqual(result.changes.school_notices.unchanged,true);assert.equal(result.changes.school_notices.records.standby.title,'Retained');
});
test('owner recovery rehearsal injects only its fresh backed-up synthetic row',()=>{
 const f=setup();const result=f.context.VS_testMissingRecordRecoveryRehearsal();assert.equal(result.success,true);assert.equal(result.operationIdentityPreserved,true);assert.equal(result.originalSchoolTouched,false);
});
test('backup releases collection locks before Drive copy and rejects a concurrently changed capture',()=>{
 const f=setup();write(f,'lock-check');const prior=f.context.VS_createVerifiedRecordBackup();let held=false,changeOnRelease=false;
 f.context.LockService={getScriptLock:()=>({waitLock(){assert.equal(held,false);held=true;},releaseLock(){held=false;if(changeOnRelease){changeOnRelease=false;f.props.set('VS_RECORD_REV_school_notices','new-cloud-generation');}}})};
 const folder=f.context.VS_managedFolder(f.context.VS_managedRoot(),'Backups'),create=folder.createFile;
 folder.createFile=function(...args){assert.equal(held,false,'Drive copy must not hold the school sync lock');return create.apply(this,args);};
 assert.equal(f.context.VS_createVerifiedRecordBackup().verified,true);
 const latest=f.props.get('VS_LAST_VERIFIED_RECORD_BACKUP');changeOnRelease=true;
 assert.throws(()=>f.context.VS_createVerifiedRecordBackup(),/Backup changed during capture/);
 assert.equal(f.props.get('VS_LAST_VERIFIED_RECORD_BACKUP'),latest);assert.notEqual(prior.fileId,latest);
});
test('one delta request verifies its Drive backup once and a later record request rechecks integrity',()=>{
 const f=setup();write(f,'notice');write(f,'pupil','students_directory');const backup=f.context.VS_createVerifiedRecordBackup();const file=f.all.get(backup.fileId),blob=file.getBlob;let reads=0;
 file.getBlob=function(){reads++;return blob.apply(this,arguments);};
 f.context.VS_managedDelta({collections:['school_notices','students_directory'],knownRevisions:{}});assert.equal(reads,1);
 file.text='corrupted later';assert.equal(read(f).records.notice.title,'Retained');assert.equal(reads,2);
 assert.equal(JSON.parse(f.props.get('VS_LAST_RECORD_RECOVERY')).code,'BACKUP_INTEGRITY_UNVERIFIED');
});
test('financial and document rows never recover automatically and queues are outside the cloud backup',()=>{
 const f=setup();write(f,'fee','fee_payments');write(f,'document','documents');const backup=f.context.VS_createVerifiedRecordBackup();
 erase(f,'fee','fee_payments');erase(f,'document','documents');assert.equal(read(f,'fee_payments').records.fee,undefined);assert.equal(read(f,'documents').records.document,undefined);
 assert.equal(f.context.VS_verifiedRecordBackup(backup.fileId).records._windows_firebase_outbox,undefined);
});
test('corrupt backup disables repair without starving unrelated cloud reads',()=>{
 const f=setup();write(f,'lost');write(f,'available');const backup=f.context.VS_createVerifiedRecordBackup();erase(f,'lost');f.all.get(backup.fileId).text='corrupt';
 const result=read(f);assert.equal(result.records.lost,undefined);assert.equal(result.records.available.title,'Retained');
 assert.equal(JSON.parse(f.props.get('VS_LAST_RECORD_RECOVERY')).code,'BACKUP_INTEGRITY_UNVERIFIED');
});
test('TEST authorization is default-off and cannot enable recovery on original/foreign roots',()=>{
 const f=storage();assert.equal(f.context.VS_testBackupRecoveryEnabled(),false);assert.throws(()=>f.context.VS_enableTestBackupRecovery(),/TEST backup/);
 f.props.set('VS_MANAGED_SCHOOL_ID',TEST);assert.throws(()=>f.context.VS_enableTestBackupRecovery(),/root mismatch/);assert.equal(f.context.VS_testBackupRecoveryEnabled(),false);
});
test('verified backup preserves deletion tombstones and restores them without resurrecting deleted data',()=>{
 const f=setup();const ack=write(f,'deleted');f.context.VS_managedRecord({operation:'delete',collection:'school_notices',id:'deleted',syncProtocol:2,operationId:'backup_delete_operation_0001',expectedRecordRevision:ack.recordRevision});
 const before=read(f).records.deleted;f.context.VS_createVerifiedRecordBackup();erase(f,'deleted');const after=read(f).records.deleted;
 assert.equal(after._syncDeleted,true);assert.equal(JSON.stringify(after),JSON.stringify(before));
});

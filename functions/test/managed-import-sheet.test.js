'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {storage,A,B}=require('./helpers/managed-storage');
const setup=s=>s.call({action:'managed_import_sheet_setup',confirmCreate:true});
const write=(s,id,data,revision='',op=('op'+id).padEnd(20,'x'))=>s.call({action:'managed_records',operation:'write',collection:'students_directory',syncProtocol:2,id,operationId:op,expectedRecordRevision:revision,data:{schoolId:A,...data}});
test('designated Import workbook requires consent and reuses school-bound source with versioned headers',()=>{
 const s=storage();assert.equal(s.call({action:'managed_import_sheet_setup'}).success,false);const a=setup(s),b=setup(s);assert.equal(a.success,true);assert.equal(a.sheetId,b.sheetId);assert.equal(s.books.size,1);assert.equal(a.headerVersion,1);
 const tab=s.books.get(a.sheetId).getSheetByName('Student Import v1');tab.getRange(2,1,1,7).setValues([[A,'S1','Test','VI','',12,'']]);const read=s.call({action:'managed_import_sheet_read'});assert.equal(read.rows[0].rollNo,'12');assert.equal(read.rows[0].section,'');assert.equal(read.rows[0].expectedRevision,null);assert.notEqual(read.fingerprint,a.fingerprint);
 tab.getRange(1,1,1,1).setValues([['wrong']]);assert.equal(s.call({action:'managed_import_sheet_read'}).success,false);
});
test('wrong school marker, moved source and oversized import fail without changing managed records',()=>{
 for(const change of ['marker','parent','size']){const s=storage(),a=setup(s),file=s.all.get(a.sheetId),tab=s.books.get(a.sheetId).getSheetByName('Student Import v1');if(change==='marker')file.setDescription('VIDYA_STUDENT_IMPORT:v1:'+B);if(change==='parent')file.moveTo(s.roots[B]);if(change==='size')tab.getRange(102,1,1,7).setValues([[A,'S','x','VI','',1,'']]);assert.equal(s.call({action:'managed_import_sheet_read'}).success,false);assert.equal(s.props.get('VS_MANAGED_SCHOOL_ID'),A);}
});
test('canonical student writes enforce new/changed occupied slots inside ScriptLock',()=>{
 const s=storage();let locked=false,checks=0;const original=s.context.VS_studentUnique;
 s.context.LockService={getScriptLock:()=>({waitLock(){assert.equal(locked,false);locked=true;},releaseLock(){locked=false;}})};
 s.context.VS_studentUnique=(...args)=>{assert.equal(locked,true);checks++;return original(...args);};
 const a=write(s,'S1',{name:'A',studentClass:'VI',section:'',rollNo:1});assert.equal(a.success,true);
 const duplicate=write(s,'S2',{name:'B',class:'VI',section:'',rollNo:'1'});assert.equal(duplicate.success,false);assert.match(duplicate.message,/class\/section\/roll conflict/);
 assert.equal(write(s,'S2',{name:'B',class:'VI',section:'B',rollNo:'1'}).success,true);
 assert.equal(write(s,'S1',{name:'Changed',studentClass:'VI',section:'',rollNo:'1'},a.recordRevision,'different-operation123').success,true);assert.equal(locked,false);assert.equal(checks,4);
});
test('tombstones release slots without resurrecting identity and legacy unmeasured slots report partial scope',()=>{
 const s=storage(),a=write(s,'S1',{name:'A',class:'VI',rollNo:1});assert.equal(a.success,true);
 const deleted=s.call({action:'managed_records',operation:'delete',collection:'students_directory',syncProtocol:2,id:'S1',operationId:'delete-operation12345',expectedRecordRevision:a.recordRevision});assert.equal(deleted.success,true);
 assert.equal(write(s,'S2',{name:'B',class:'VI',rollNo:1}).success,true);assert.equal(write(s,'S1',{name:'Resurrect',class:'VI',rollNo:2},deleted.recordRevision).success,false);
 assert.equal(write(s,'legacy',{name:'Old'},'','legacy-operation12345').studentUniquenessScope,'partial-legacy');
});
test('recycle restore cannot recreate a student into another active student slot',()=>{
 const s=storage();s.props.set('VS_RECYCLE_VERSION','1');const a=write(s,'S1',{name:'Original',class:'VI',rollNo:1});const deleted=s.call({action:'managed_records',operation:'delete',collection:'students_directory',syncProtocol:2,id:'S1',operationId:'recycle-delete-123456',expectedRecordRevision:a.recordRevision});
 const tomb=s.call({action:'managed_records',operation:'read',collection:'students_directory',syncProtocol:2}).records.S1;assert.equal(write(s,'S2',{name:'Replacement Slot',class:'VI',rollNo:1}).success,true);
 const result=s.call({action:'managed_recycle',operation:'restore',fileId:tomb._syncRecycleFileId,operationId:'recycle-restore123456',expectedRecordRevision:deleted.recordRevision});assert.equal(result.success,false);assert.match(result.message,/class\/section\/roll conflict/);assert.equal(s.call({action:'managed_records',operation:'read',collection:'students_directory',syncProtocol:2}).records.S1._syncDeleted,true);
});

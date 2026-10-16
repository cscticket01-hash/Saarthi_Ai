'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {storage,A,B}=require('./helpers/managed-storage');
const S='Class 1_Roll_1',G='p-'+'1'.repeat(64),N='p-'+'2'.repeat(64);
const write=(s,collection,id,data,base='',op='lifecycle-operation-0001')=>s.call({action:'managed_records',operation:'write',collection,id,syncProtocol:2,operationId:op,expectedRecordRevision:base,data:{schoolId:A,...data}});
const read=(s,collection)=>s.call({action:'managed_records',operation:'read',collection,syncProtocol:2});
const student=s=>write(s,'students_directory',S,{name:'Synthetic pupil',class:'Class 1',rollNo:'1',mobileStableId:G});
const erase=(s,col,id)=>{const store=s.context.VS_managedSheet(col),item=s.context.VS_sheetItem(store,id);store.sheet.getRange(item.row,1,1,33).setValues([Array(33).fill('')]);};
const recover=(s,col,id,data)=>s.call({action:'managed_records',operation:'recover',collection:col,id,syncProtocol:2,operationId:'lifecycle-recover-0001',expectedRecordRevision:data._syncRevision,data});
test('production Sheet policy stores only Sheets and no record JSON, even with historical backup preference',()=>{
 const s=storage({lifecycle:true,recordBackups:true,bundle:true});assert.equal(student(s).success,true);
 assert.equal([...s.all.values()].some(f=>f.mime==='application/json'),false);
 assert.equal(s.call({action:'managed_health'}).sheetLifecycleVersion,1);
 const state=s.books.get(s.props.get('VS_SYNC_STATE_SHEET_ID')).getSheetByName('students_directory');
 assert.equal(JSON.stringify(state.getRange(1,1,state.getLastRow(),2).getValues()).includes('Synthetic pupil'),false);
});
test('missing row recovers only the exact locally verified revision and rejects edits, stale content and foreign school',()=>{
 const s=storage({lifecycle:true});student(s);const original=read(s,'students_directory').records[S];erase(s,'students_directory',S);
 const missing=read(s,'students_directory');assert.equal(missing.missingRecords[0].id,S);
 assert.equal(recover(s,'students_directory',S,{...original,name:'Changed'}).success,false);
 assert.equal(recover(s,'students_directory',S,{...original,schoolId:B}).success,false);
 assert.equal(recover(s,'students_directory',S,original).success,true);
 assert.deepEqual(read(s,'students_directory').records[S],original);
});
test('manually trashed school workbook is restored by the existing verified ID, without rebinding or duplicate workbook',()=>{
 const s=storage({lifecycle:true});student(s);const id=s.props.get('VS_MANAGED_SHEET_ID'),size=s.books.size;s.all.get(id).setTrashed(true);
 assert.equal(read(s,'students_directory').success,true);assert.equal(s.all.get(id).isTrashed(),false);assert.equal(s.books.size,size);assert.equal(s.props.get('VS_MANAGED_SHEET_ID'),id);
});
test('permanently missing workbook is recreated only with verified school sync state; local content restores its rows',()=>{
 const s=storage({lifecycle:true});student(s);const original=read(s,'students_directory').records[S],id=s.props.get('VS_MANAGED_SHEET_ID');
 const get=s.context.DriveApp.getFileById;s.context.DriveApp.getFileById=x=>{if(x===id)throw Error('No item with the given ID');return get(x);};
 const missing=read(s,'students_directory');assert.equal(missing.success,true);assert.notEqual(s.props.get('VS_MANAGED_SHEET_ID'),id);assert.equal(missing.missingRecords[0].id,S);
 assert.equal(recover(s,'students_directory',S,original).success,true);
});
test('permission error never rebinds or recreates a workbook',()=>{
 const s=storage({lifecycle:true});student(s);const id=s.props.get('VS_MANAGED_SHEET_ID'),size=s.books.size,get=s.context.DriveApp.getFileById;
 s.context.DriveApp.getFileById=x=>{if(x===id)throw Error('Access denied');return get(x);};assert.equal(read(s,'students_directory').success,false);assert.equal(s.books.size,size);assert.equal(s.props.get('VS_MANAGED_SHEET_ID'),id);
});
test('explicit deletion removes linked rows; new occupant can reuse the slot while stale devices cannot overwrite it',()=>{
 const s=storage({lifecycle:true}),first=student(s);
 assert.equal(write(s,'fee_payments','fee',{studentId:S,personId:G,amount:100}).success,true);
 assert.equal(write(s,'fee_payments','other',{studentId:'other',personId:'other-person',amount:200},'','lifecycle-other-op-0001').success,true);
 const deleted=s.call({action:'managed_records',operation:'delete',collection:'students_directory',id:S,syncProtocol:2,operationId:'lifecycle-delete-0001',expectedRecordRevision:first.recordRevision});assert.equal(deleted.success,true,JSON.stringify(deleted));
 assert.equal(read(s,'fee_payments').records.fee._syncDeleted,true);assert.equal(read(s,'fee_payments').records.fee.amount,undefined);assert.equal(read(s,'fee_payments').records.other.amount,200);
 assert.equal(write(s,'students_directory',S,{name:'New pupil',class:'Class 1',rollNo:'1',mobileStableId:N,replacesStudentGeneration:G},first.recordRevision,'lifecycle-readd-0001').success,true);
 assert.equal(write(s,'students_directory',S,{name:'Old offline pupil',mobileStableId:G},first.recordRevision,'lifecycle-stale-0001').success,false);
 assert.equal(write(s,'fee_payments','stale-child',{studentId:S,personId:G,amount:300},'','lifecycle-child-0001').success,false);
 assert.equal(read(s,'students_directory').records[S].mobileStableId,N);
});
test('lost deletion ACK and a missing row never resurrect deleted student payload',()=>{
 const s=storage({lifecycle:true}),a=student(s),before=read(s,'students_directory').records[S];const op={action:'managed_records',operation:'delete',collection:'students_directory',id:S,syncProtocol:2,operationId:'lifecycle-delete-0001',expectedRecordRevision:a.recordRevision};
 const deleted=s.call(op);assert.equal(deleted.success,true);assert.equal(s.call(op).recordRevision,deleted.recordRevision);erase(s,'students_directory',S);
 assert.equal(read(s,'students_directory').records[S]._syncDeleted,true);assert.equal(recover(s,'students_directory',S,before).success,false);
});
test('large multilingual record no longer commits then fails on an unrelated JSON backup limit',()=>{
 const s=storage({lifecycle:true,recordBackups:true});assert.equal(write(s,'school_notices','unicode',{title:'Synthetic',body:'ক'.repeat(360000)}).success,true);
});
test('explicit generation-bound delete supersedes same-pupil edits but never deletes the next occupant',()=>{
 const s=storage({lifecycle:true}),a=student(s);
 const edited=write(s,'students_directory',S,{name:'Later old-pupil edit',class:'Class 1',rollNo:'1',mobileStableId:G},a.recordRevision,'lifecycle-edit-0001');assert.equal(edited.success,true);
 const op={action:'managed_records',operation:'delete',collection:'students_directory',id:S,syncProtocol:2,operationId:'lifecycle-delete-0001',expectedRecordRevision:a.recordRevision,deletedStudentGeneration:G};
 const d=s.call(op);assert.equal(d.success,true);
 assert.equal(write(s,'students_directory',S,{name:'New',mobileStableId:N},d.recordRevision,'lifecycle-new-0001').success,true);
 assert.equal(s.call(op).success,false);assert.equal(read(s,'students_directory').records[S].mobileStableId,N);
});
test('legacy canonical rows receive bulk revision proofs before their first upgraded write',()=>{
 const s=storage();student(s);const before=read(s,'students_directory').records[S];s.props.set('VS_SHEET_LIFECYCLE','on');
 assert.equal(read(s,'students_directory').records[S].name,before.name);erase(s,'students_directory',S);
 assert.equal(recover(s,'students_directory',S,before).success,true);
});

'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {storage,A}=require('./helpers/managed-storage');
const write=(s,id,data,revision='',op='student-view-operation01')=>s.call({action:'managed_records',operation:'write',collection:'students_directory',syncProtocol:2,id,operationId:op,expectedRecordRevision:revision,data:{schoolId:A,...data}});
const tab=s=>s.books.get(s.props.get('VS_MANAGED_SHEET_ID')).getSheetByName('students_directory');
test('readable student columns derive from canonical row without changing CAS or JSON',()=>{
 const s=storage(),a=write(s,'S1',{name:'দিলীপ',parentName:'Parent',class:'1',rollNo:5,contact:'012345',dateOfBirth:{__vsTimestamp:'2018-01-01T00:00:00.000Z'},address:'=IMPORTXML("foreign")'});
 assert.equal(a.success,true);const t=tab(s),v=t.getRange(2,34,1,14).getValues()[0];assert.equal(v[0],'দিলীপ');assert.equal(v[4],'012345');assert.equal(v[12],'2018-01-01T00:00:00.000Z');assert.equal(v[7],"'=IMPORTXML(\"foreign\")");
 const read=s.call({action:'managed_records',operation:'read',collection:'students_directory',syncProtocol:2});assert.equal(read.records.S1.name,'দিলীপ');assert.equal(read.records.S1._syncRevision,a.recordRevision);assert.equal(read.records.S1.address,'=IMPORTXML("foreign")');
 const b=write(s,'S1',{name:'Updated',class:'1',rollNo:5},a.recordRevision,'student-view-operation02');assert.equal(b.success,true);assert.equal(t.getRange(2,34,1,1).getValues()[0][0],'Updated');
 const del=s.call({action:'managed_records',operation:'delete',collection:'students_directory',syncProtocol:2,id:'S1',operationId:'student-view-delete01',expectedRecordRevision:b.recordRevision});assert.equal(del.success,true);assert.ok(t.getRange(2,34,1,14).getValues()[0].every(x=>x===''));assert.equal(s.call({action:'managed_records',operation:'read',collection:'students_directory',syncProtocol:2}).records.S1._syncDeleted,true);
});
test('reads backfill existing rows; view collisions preserve owner cells and do not break sync',()=>{
 const s=storage(),original=s.context.VS_studentReadable;s.context.VS_studentReadable=()=>{};const a=write(s,'old',{name:'Old',class:'1',rollNo:1});s.context.VS_studentReadable=original;
 const t=tab(s);assert.equal(t.getRange(2,34,1,1).getValues()[0][0],'');const read=s.call({action:'managed_records',operation:'read',collection:'students_directory',syncProtocol:2});assert.equal(read.records.old._syncRevision,a.recordRevision);assert.equal(t.getRange(2,34,1,1).getValues()[0][0],'Old');
 t.getRange(1,34,1,1).setValues([['Owner Notes']]);t.getRange(2,34,1,1).setValues([['Keep me']]);const b=write(s,'old',{name:'New',class:'1',rollNo:1},a.recordRevision,'student-view-operation02');assert.equal(b.success,true);assert.equal(t.getRange(2,34,1,1).getValues()[0][0],'Keep me');assert.match(s.props.get('VS_STUDENT_READABLE_STATUS'),/blocked/);assert.equal(s.call({action:'managed_records',operation:'read',collection:'students_directory',syncProtocol:2}).records.old.name,'New');
});
test('existing rows backfill in batches of 100 with explicit partial status and stable canonical revisions',()=>{
 const s=storage(),project=s.context.VS_studentReadable;s.context.VS_studentReadable=()=>{};
 for(let n=0;n<101;n++)assert.equal(write(s,'S'+n,{name:'Student '+n},'',('row-operation'+n).padEnd(20,'x')).success,true);
 s.context.VS_studentReadable=project;const t=tab(s),read=()=>s.call({action:'managed_records',operation:'read',collection:'students_directory',syncProtocol:2});
 const before=s.context.VS_sheetRecords(s.context.VS_managedSheet('students_directory'));
 assert.equal(read().success,true);assert.equal(t.getRange(101,34,1,1).getValues()[0][0],'Student 99');assert.equal(t.getRange(102,34,1,1).getValues()[0][0],'');assert.match(s.props.get('VS_STUDENT_READABLE_STATUS'),/backfill pending: 1/);
 const after=read();assert.equal(t.getRange(102,34,1,1).getValues()[0][0],'Student 100');assert.equal(s.props.get('VS_STUDENT_READABLE_STATUS'),'available');assert.deepEqual(JSON.parse(JSON.stringify(after.records)),JSON.parse(JSON.stringify(before)));
});
test('reviewed version-2 document writes support later owner updates and stable delete replay',()=>{
 const s=storage();const write=(generation,base,record,operation)=>s.call({action:'managed_records',operation:'write',collection:'documents',id:'D1',syncProtocol:2,operationId:operation,expectedRecordRevision:record,expectedRevision:base,data:{schoolId:A,studentId:'S1',documentRevision:generation}});
 const first=write('generation-1','','','document-write-operation1');assert.equal(first.success,true);
 const second=write('generation-2','generation-1',first.recordRevision,'document-write-operation2');assert.equal(second.success,true);
 assert.equal(write('stale','generation-1',first.recordRevision,'document-write-operation3').success,false);
 const request={action:'managed_records',operation:'delete',collection:'documents',id:'D1',syncProtocol:2,operationId:'document-delete-operation1',expectedRecordRevision:second.recordRevision,expectedRevision:'generation-2'};
 const deleted=s.call(request);assert.equal(deleted.success,true);assert.equal(s.call(request).recordRevision,deleted.recordRevision);
 assert.equal(s.call({action:'managed_records',operation:'read',collection:'documents',syncProtocol:2}).records.D1._syncDeleted,true);
});

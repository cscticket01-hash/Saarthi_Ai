'use strict';
const {test}=require('node:test'),assert=require('node:assert/strict');
const {storage,A,B}=require('./helpers/managed-storage');
function write(f,col,id,data,extra={}){const result=f.call({action:'managed_records',collection:col,operation:'write',id,data:{schoolId:A,...data},...extra});assert.equal(result.success,true,JSON.stringify(result));return result;}
function read(f,col){const result=f.call({action:'managed_records',collection:col,operation:'read',syncProtocol:2});assert.equal(result.success,true);return result.records;}
function finish(f,rollback=false){let state=f.context.VS_organizedStorageStatus();for(let n=0;n<200&&state.phase!==(rollback?'rolledBack':'complete');n++)state=rollback?f.context.VS_rollbackOrganizedStorageMigration():f.context.VS_stepOrganizedStorageMigration();assert.equal(state.phase,rollback?'rolledBack':'complete');return state;}
test('organized layout preserves every collection, Unicode/decimal data, revision/operation IDs and tombstones; partitions verified roles without guessing',()=>{
 const f=storage();for(const col of f.collections)write(f,col,'record',{name:'বিদ্যালয় =SAFE',amount:125.75,nested:{custom:'retained'}});
 write(f,'teachers_directory','teacher',{role:'teacher',name:'Teacher'});write(f,'teachers_directory','staff',{role:'other_staff',name:'Staff'});
 write(f,'attendance_records','student',{role:'student'});write(f,'attendance_records','staff',{role:'staff'});
 write(f,'students_directory','removed',{name:'Retain deletion'});assert.equal(f.call({action:'managed_records',collection:'students_directory',operation:'delete',id:'removed'}).success,true);
 const before={};for(const col of f.collections)before[col]=read(f,col);
 const root=f.roots[A].getId();f.context.VS_beginOrganizedStorageMigration();finish(f);
 assert.equal(f.roots[A].getId(),root);for(const col of f.collections)assert.deepEqual(read(f,col),before[col]);
 const state=f.context.VS_layoutState('teachers_directory'),store=f.context.VS_layoutStore(state);
 assert(f.context.VS_sheetItem(store.partitions[0],'teacher'));assert(f.context.VS_sheetItem(store.partitions[1],'staff'));assert(f.context.VS_sheetItem(store.partitions[2],'record'));
 assert.equal(f.props.get('VS_SHEET_MIGRATED_students_directory'),'1');assert(read(f,'students_directory').removed._syncDeleted);
 assert.equal([...f.books.values()].length,18); // original plus 17 organized workbooks
});
test('bounded copy keeps legacy authoritative, reconciles mid-migration edits, retries an interrupted row write and never duplicates logical records',()=>{
 const f=storage();for(let n=0;n<65;n++)write(f,'students_directory','p'+String(n).padStart(2,'0'),{name:'Original '+n});
 f.context.VS_beginOrganizedStorageMigration();f.context.VS_stepOrganizedStorageMigration();assert.equal(f.context.VS_layoutState('students_directory').phase,'copying');
 const store=f.context.VS_layoutStore(f.context.VS_layoutState('students_directory')),original=f.context.VS_sheetPut;let failed=false;
 f.context.VS_sheetPut=(s,item)=>{original(s,item);if(s===store||!failed&&item.id==='p30'){failed=true;throw Error('injected interruption');}};
 assert.throws(()=>f.context.VS_stepOrganizedStorageMigration(),/interruption/);f.context.VS_sheetPut=original;
 write(f,'students_directory','p01',{name:'Edited during copy'});write(f,'students_directory','new',{name:'New during copy'});
 finish(f);assert.equal(Object.keys(read(f,'students_directory')).length,66);assert.equal(read(f,'students_directory').p01.name,'Edited during copy');
 const state=f.context.VS_layoutState('students_directory');assert.equal(state.count,66);assert.equal(state.hash,f.context.VS_layoutHash(read(f,'students_directory')));
});
test('rollback replays post-activation writes and tombstones into retained legacy store; lost ACK operation remains idempotent',()=>{
 const f=storage();write(f,'school_notices','notice',{title:'Before'});f.context.VS_beginOrganizedStorageMigration();finish(f);
 const extra={syncProtocol:2,operationId:'same-operation-1234567890',expectedRecordRevision:''};const ack=write(f,'fee_settings','Class_1__2026-2027',{fees:{Tuition:150.75}},extra);
 const retry=write(f,'fee_settings','Class_1__2026-2027',{fees:{Tuition:150.75}},extra);assert.equal(retry.recordRevision,ack.recordRevision);
 assert.equal(f.call({action:'managed_records',collection:'school_notices',operation:'delete',id:'notice'}).success,true);
 const before={};for(const col of f.collections)before[col]=read(f,col);finish(f,true);
 for(const col of f.collections)assert.deepEqual(read(f,col),before[col]);
 assert.equal(write(f,'fee_settings','Class_1__2026-2027',{fees:{Tuition:150.75}},extra).recordRevision,ack.recordRevision);
 assert.equal(read(f,'school_notices').notice._syncDeleted,true);
});
test('binary migration verifies exact backups, preserves file IDs/URLs, resumes move crash, and upload retry reuses moved originals; rollback restores parent',()=>{
 const f=storage(),upload={action:'managed_upload',name:'Photo_unique.jpg',mime:'image/jpeg',base64:Buffer.from('binary-original').toString('base64'),uploadKey:'own-revision'};
 const first=f.call(upload);assert(first.success);const file=f.all.get(first.fileId),originalParent=file.parent.getId();
 write(f,'students_directory','pupil',{name:'Pupil',photoUrl:first.fileUrl});const foreign=f.roots[B].createFile('foreign.pdf','keep','application/pdf');
 f.context.VS_beginOrganizedStorageMigration();let state;do{state=f.context.VS_stepOrganizedStorageMigration();}while(state.phase==='records');
 const move=file.moveTo;let crashed=false;file.moveTo=function(target){const result=move.call(this,target);if(!crashed){crashed=true;throw Error('move crash');}return result;};
 assert.throws(()=>f.context.VS_stepOrganizedStorageMigration(),/move crash/);file.moveTo=move;finish(f);
 assert.equal(file.parent.getName(),'Student_Photos');assert.equal(f.call(upload).fileId,first.fileId);assert.equal(read(f,'students_directory').pupil.photoUrl,first.fileUrl);
 assert.equal(foreign.parent,f.roots[B]);assert.equal(foreign.trash,undefined);finish(f,true);assert.equal(file.parent.getId(),originalParent);assert.equal(file.text,'binary-original');
});
test('tampered snapshot blocks activation and foreign target ancestry blocks rollback before file movement',()=>{
 const f=storage();write(f,'students_directory','p',{name:'Keep'});f.context.VS_beginOrganizedStorageMigration();f.context.VS_stepOrganizedStorageMigration();
 const state=f.context.VS_layoutState('students_directory'),backup=f.all.get(state.backup.id);backup.text='{}';
 // Active collections also need their pre-activation recovery backup checked on rollback.
 assert.throws(()=>f.context.VS_rollbackOrganizedStorageMigration(),/Backup changed/);
 assert.equal(read(f,'students_directory').p.name,'Keep');
 assert.throws(()=>f.context.VS_layoutOwnFolder(f.roots[B]),/Foreign/);
});
test('role change preserves one logical record across partitions; activated tabs missing or foreign are rejected without replacement',()=>{
 const f=storage();write(f,'teachers_directory','person',{role:'teacher',name:'Person'});f.context.VS_beginOrganizedStorageMigration();finish(f);
 write(f,'teachers_directory','person',{role:'staff',name:'Person'});assert.equal(Object.keys(read(f,'teachers_directory')).length,1);
 const state=f.context.VS_layoutState('teachers_directory'),store=f.context.VS_layoutStore(state);assert(f.context.VS_sheetItem(store.partitions[0],'person').layoutRedirect);assert(f.context.VS_sheetItem(store.partitions[1],'person'));
 f.all.get(state.targets[1].id).setDescription('VIDYA_LAYOUT:'+B+':'+state.targets[1].name);assert.equal(f.call({action:'managed_records',collection:'teachers_directory',operation:'read'}).success,false);
});
test('partition move interrupted after target write still reads newest value and repeats the original operation ACK without duplicates',()=>{
 const f=storage();write(f,'teachers_directory','person',{role:'teacher',name:'Before'});f.context.VS_beginOrganizedStorageMigration();finish(f);
 const original=f.context.VS_sheetPut;let failed=false;
 f.context.VS_sheetPut=(store,item)=>{original(store,item);if(!store.partitions&&item.layoutPrevious&&!failed){failed=true;throw Error('partition move crash');}};
 const body={action:'managed_records',collection:'teachers_directory',operation:'write',id:'person',syncProtocol:2,operationId:'role-change-operation-12345',expectedRecordRevision:read(f,'teachers_directory').person._syncRevision,data:{schoolId:A,role:'staff',name:'After'}};
 assert.equal(f.call(body).success,false);f.context.VS_sheetPut=original;
 assert.equal(read(f,'teachers_directory').person.name,'After');const retried=f.call(body);assert(retried.success);assert.equal(Object.keys(read(f,'teachers_directory')).length,1);
 finish(f,true);assert.equal(read(f,'teachers_directory').person.name,'After');
});
test('prototype-like stable record IDs remain exact through migration and rollback',()=>{
 const f=storage();for(const id of ['constructor','__proto__','toString'])write(f,'students_directory',id,{name:id});
 f.context.VS_beginOrganizedStorageMigration();finish(f);assert.deepEqual(Object.keys(read(f,'students_directory')).sort(),['__proto__','constructor','toString']);finish(f,true);assert.equal(Object.keys(read(f,'students_directory')).length,3);
});
test('workbook move interruption recovers the persisted creation ID; unmarked create-timeout orphan blocks duplicate creation',()=>{
 const f=storage(),original=f.context.SpreadsheetApp.create;let crashed=false;
 f.context.SpreadsheetApp.create=name=>{const book=original(name),file=f.all.get(book.getId()),move=file.moveTo;file.moveTo=function(target){move.call(this,target);if(!crashed){crashed=true;throw Error('workbook move crash');}return this;};return book;};
 // Fixture creates within root, so force the initial creation through its move recovery path.
 const p=f.props,base=f.roots[A],foreign=f.roots[B];
 f.context.SpreadsheetApp.create=name=>{const book=original(name),file=f.all.get(book.getId());file.moveTo(foreign);const move=file.moveTo;file.moveTo=function(target){move.call(this,target);if(!crashed){crashed=true;throw Error('workbook move crash');}return this;};return book;};
 assert.throws(()=>f.context.VS_layoutBook('01_Students'),/move crash/);const id=p.get('VS_LAYOUT_BOOK_01_Students');assert(id);assert.equal(f.context.VS_layoutBook('01_Students'),id);assert.equal(f.books.size,1);assert.equal(f.all.get(id).parent,base);
 const second=storage();second.context.SpreadsheetApp.create=name=>{original.call(null,name);throw Error('not used');};
 const filename='01_Students — '+A;second.roots[A].createFile(filename,'','application/vnd.google-apps.spreadsheet');assert.throws(()=>second.context.VS_layoutBook('01_Students'),/Unverified/);assert.equal(second.books.size,0);
});

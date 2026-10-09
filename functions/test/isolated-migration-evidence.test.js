'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const source=fs.readFileSync('../.github/scripts/isolated_migration_owner.gs','utf8');
const school='vs-db8afb01a3be46a983c8284714d06e5d';
function fixture(){
 const original=JSON.stringify({collections:[{collection:'school_notices',count:1,hash:'old'}],binaryCount:1,binaryBytes:142});
 const props=new Map([['VS_MANAGED_SCHOOL_ID',school],['VS_TEST_MIGRATION_BASELINE',original]]);
 const logs=[];
 let preview={collections:[{collection:'school_notices',count:2,hash:'current',sourcePhase:'active'}],binaryCount:1,binaryBytes:142};
 const context=vm.createContext({PropertiesService:{getScriptProperties:()=>({getProperty:k=>props.get(k)||null,setProperty:(k,v)=>props.set(k,v)})},VS_managedRoot:()=>({}),VS_previewOrganizedStorageMigration:()=>preview,VS_organizedStorageStatus:()=>({phase:'files',collectionCursor:25,binaryCursor:0}),Logger:{log:s=>logs.push(JSON.parse(s))}});
 vm.runInContext(source,context);
 return {context,props,logs,original,preview,setPreview:p=>{preview=p;}};
}
test('TEST migration diagnosis preserves old baseline and reports concurrent sync differences',()=>{
 const f=fixture();f.context.VS_TEST_migrationDiagnostic();
 assert.equal(f.props.get('VS_TEST_MIGRATION_BASELINE'),f.original);
 assert.deepEqual(f.logs[0].differences,[{collection:'school_notices',beforeCount:1,afterCount:2,sourcePhase:'active'}]);
 assert.equal(f.props.size,2);
});
test('post-sync checkpoint remains separate and cannot silently replace a prior checkpoint',()=>{
 const f=fixture();f.context.VS_TEST_checkpointCurrent();
 assert.equal(f.props.get('VS_TEST_MIGRATION_BASELINE'),f.original);
 const saved=f.props.get('VS_TEST_POSTSYNC_CHECKPOINT');
 assert.throws(()=>f.context.VS_TEST_checkpointCurrent(),/already retained/);
 assert.equal(f.props.get('VS_TEST_POSTSYNC_CHECKPOINT'),saved);
});
test('checkpoint verification requires exact field hash even when record count is unchanged',()=>{
 const f=fixture();f.context.VS_TEST_checkpointCurrent();
 f.setPreview({...f.preview,collections:[{collection:'school_notices',count:2,hash:'tampered'}]});
 assert.throws(()=>f.context.VS_TEST_verifyCurrent(),/integrity mismatch/);
 assert.equal(f.logs.some(l=>l.event==='TEST_postsync_integrity'),false);
});
test('checkpoint verification rejects binary size changes and missing checkpoints',()=>{
 const f=fixture();assert.throws(()=>f.context.VS_TEST_verifyCurrent(),/checkpoint required/);
 f.context.VS_TEST_checkpointCurrent();f.setPreview({...f.preview,binaryBytes:143});
 assert.throws(()=>f.context.VS_TEST_verifyCurrent(),/integrity mismatch/);
});
test('unchanged current checkpoint verifies while retaining original mismatch evidence',()=>{
 const f=fixture();f.context.VS_TEST_checkpointCurrent();f.context.VS_TEST_verifyCurrent();
 assert.equal(f.logs[1].status,'PASS');
 assert.equal(f.props.get('VS_TEST_MIGRATION_BASELINE'),f.original);
 assert.throws(()=>f.context.VS_TEST_verifyMigration(),/integrity mismatch/);
});
test('owner test helpers reject a foreign school before reading storage',()=>{
 const f=fixture();f.props.set('VS_MANAGED_SCHOOL_ID','vs-foreign');
 assert.throws(()=>f.context.VS_TEST_checkpointCurrent(),/Isolated TEST school required/);
 assert.throws(()=>f.context.VS_TEST_migrationDiagnostic(),/Isolated TEST school required/);
 assert.equal(f.props.has('VS_TEST_POSTSYNC_CHECKPOINT'),false);
});

function seedFixture(){
 const f=fixture();let released=0;
 f.context.LockService={getScriptLock:()=>({waitLock:()=>{},releaseLock:()=>released++})};
 f.context.VS_managedSheet=collection=>collection;
 const rows=[['students_directory','student'],['teachers_directory','teacher'],['teachers_directory','staff'],['attendance_logs','student'],['teacher_attendance','teacher'],['teacher_attendance','staff'],['fee_ledger',''],['fee_settings',''],['school_expenses',''],['exams',''],['exam_results',''],['teacher_salary',''],['school_notices',''],['school_config',''],['school_calendar',''],['documents',''],['scanner_devices','']];
 const records={};rows.forEach((r,n)=>{(records[r[0]]||={})['synthetic-migration-category-'+String(n+1).padStart(2,'0')]={schoolId:school,syntheticTest:true,name:'Synthetic TEST category '+(n+1),role:r[1],category:n+1,content:'Integrity fixture = literal JSON, not a formula'};});
 f.context.VS_sheetRecords=c=>records[c];return {...f,records,released:()=>released};
}
test('all 17 synthetic category contents are verified read-only',()=>{
 const f=seedFixture();f.context.VS_TEST_verifySeedFixtures();
 assert.equal(f.logs[0].categories,17);assert.equal(f.logs[0].writesPerformed,0);
 assert.equal(f.props.size,2);assert.equal(f.released(),1);
});
test('category content mutation fails and releases the migration lock',()=>{
 const f=seedFixture();f.records.documents['synthetic-migration-category-16'].content='changed';
 assert.throws(()=>f.context.VS_TEST_verifySeedFixtures(),/content mismatch: 16/);
 assert.equal(f.logs.length,0);assert.equal(f.released(),1);
});

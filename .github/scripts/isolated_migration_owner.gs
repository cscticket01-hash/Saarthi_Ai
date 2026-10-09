// Owner-editor TEST harness only. Never routed or deployed as a web action.
function VS_TEST_guard(){
 const p=PropertiesService.getScriptProperties();
 if(p.getProperty('VS_MANAGED_SCHOOL_ID')!=='vs-db8afb01a3be46a983c8284714d06e5d')throw new Error('Isolated TEST school required');
 VS_managedRoot();return p;
}
function VS_TEST_seedAndDryRun(){
 const p=VS_TEST_guard();if(p.getProperty('VS_TEST_MIGRATION_BASELINE')){Logger.log('TEST migration baseline already retained');return;}
 const rows=[['students_directory','student'],['teachers_directory','teacher'],['teachers_directory','staff'],['attendance_logs','student'],['teacher_attendance','teacher'],['teacher_attendance','staff'],['fee_ledger',''],['fee_settings',''],['school_expenses',''],['exams',''],['exam_results',''],['teacher_salary',''],['school_notices',''],['school_config',''],['school_calendar',''],['documents',''],['scanner_devices','']];
 rows.forEach((row,n)=>{const id='synthetic-migration-category-'+String(n+1).padStart(2,'0');const old=VS_managedRecord({operation:'read',collection:row[0],syncProtocol:2}).records[id];if(old){if(old.syntheticTest!==true)throw new Error('Existing record retained');return;}
  VS_managedRecord({operation:'write',collection:row[0],id:id,syncProtocol:2,operationId:'synthetic-migration-20261009-'+n,expectedRecordRevision:'',data:{schoolId:p.getProperty('VS_MANAGED_SCHOOL_ID'),syntheticTest:true,name:'Synthetic TEST category '+(n+1),role:row[1],category:n+1,content:'Integrity fixture = literal JSON, not a formula'}});
 });
 const baseline=VS_previewOrganizedStorageMigration();p.setProperty('VS_TEST_MIGRATION_BASELINE',JSON.stringify({collections:baseline.collections.map(c=>({collection:c.collection,count:c.count,hash:c.hash})),binaryCount:baseline.binaryCount,binaryBytes:baseline.binaryBytes}));
 Logger.log(JSON.stringify({event:'TEST_migration_dry_run',schoolId:baseline.schoolId,seededCategories:17,writesPerformed:baseline.writesPerformed,collections:baseline.collections.map(c=>({collection:c.collection,count:c.count})),binaryCount:baseline.binaryCount}));
 const started=VS_beginOrganizedStorageMigration();Logger.log(JSON.stringify({event:'TEST_migration_backup_started',phase:started.phase,migrationId:started.migrationId}));
}
function VS_TEST_migrationChunk(){VS_TEST_guard();const start=Date.now();let status=VS_organizedStorageStatus();let steps=0;while(status.phase!=='complete'&&steps<5&&Date.now()-start<180000){status=VS_stepOrganizedStorageMigration();steps++;}Logger.log(JSON.stringify({event:'TEST_migration_resume',phase:status.phase,collectionCursor:status.collectionCursor,binaryCursor:status.binaryCursor,steps:steps}));if(status.phase==='complete')VS_TEST_verifyMigration();}
function VS_TEST_verifyMigration(){
 const p=VS_TEST_guard(),baseline=JSON.parse(p.getProperty('VS_TEST_MIGRATION_BASELINE')||'null');if(!baseline)throw new Error('Retained TEST baseline required');
 const now=VS_previewOrganizedStorageMigration(),after=now.collections.map(c=>({collection:c.collection,count:c.count,hash:c.hash}));
 if(JSON.stringify(after)!==JSON.stringify(baseline.collections)||now.binaryCount!==baseline.binaryCount||now.binaryBytes!==baseline.binaryBytes)throw new Error('TEST migration integrity mismatch; all versions retained');
 Logger.log(JSON.stringify({event:'TEST_migration_integrity',status:'PASS',phase:VS_organizedStorageStatus().phase,collections:after.length,records:after.reduce((n,c)=>n+c.count,0),binaryCount:now.binaryCount,binaryBytes:now.binaryBytes}));
}
function VS_TEST_rollbackChunk(){VS_TEST_guard();const start=Date.now();let status=VS_organizedStorageStatus();let steps=0;while(status.phase!=='rolledBack'&&steps<5&&Date.now()-start<180000){status=VS_rollbackOrganizedStorageMigration();steps++;}Logger.log(JSON.stringify({event:'TEST_rollback_resume',phase:status.phase,collectionCursor:status.collectionCursor,binaryCursor:status.binaryCursor,steps:steps}));if(status.phase==='rolledBack')VS_TEST_verifyMigration();}

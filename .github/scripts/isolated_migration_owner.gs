// Owner-editor TEST harness only. Never routed or deployed as a web action.
function VS_TEST_guard(){
 const p=PropertiesService.getScriptProperties();
 if(p.getProperty('VS_MANAGED_SCHOOL_ID')!=='vs-db8afb01a3be46a983c8284714d06e5d')throw new Error('Isolated TEST school required');
 VS_managedRoot();return p;
}
function VS_TEST_ownership(){VS_TEST_guard();const root=VS_managedRoot();Logger.log(JSON.stringify({event:'TEST_root_ownership',schoolId:PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID'),rootId:root.getId(),rootName:root.getName(),ownerEmail:root.getOwner().getEmail(),marker:root.getDescription()}));}
function VS_TEST_seedCategories(){
 const p=VS_TEST_guard();if(p.getProperty('VS_TEST_MIGRATION_BASELINE')){Logger.log('TEST migration baseline already retained');return;}
 const rows=[['students_directory','student'],['teachers_directory','teacher'],['teachers_directory','staff'],['attendance_logs','student'],['teacher_attendance','teacher'],['teacher_attendance','staff'],['fee_ledger',''],['fee_settings',''],['school_expenses',''],['exams',''],['exam_results',''],['teacher_salary',''],['school_notices',''],['school_config',''],['school_calendar',''],['documents',''],['scanner_devices','']];
 rows.forEach((row,n)=>{const id='synthetic-migration-category-'+String(n+1).padStart(2,'0');const old=VS_managedRecord({operation:'read',collection:row[0],syncProtocol:2}).records[id];if(old){if(old.syntheticTest!==true)throw new Error('Existing record retained');return;}
  VS_managedRecord({operation:'write',collection:row[0],id:id,syncProtocol:2,operationId:'synthetic-migration-20261009-'+n,expectedRecordRevision:'',data:{schoolId:p.getProperty('VS_MANAGED_SCHOOL_ID'),syntheticTest:true,name:'Synthetic TEST category '+(n+1),role:row[1],category:n+1,content:'Integrity fixture = literal JSON, not a formula'}});
 });
 Logger.log(JSON.stringify({event:'TEST_migration_seed',schoolId:p.getProperty('VS_MANAGED_SCHOOL_ID'),seededCategories:17}));
}
function VS_TEST_seedAndDryRun(){
 const p=VS_TEST_guard();if(p.getProperty('VS_TEST_MIGRATION_BASELINE')){Logger.log('TEST migration baseline already retained');return;}
 VS_TEST_seedCategories();
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

// Read-only diagnosis. Never replaces the retained acceptance baseline.
function VS_TEST_migrationDiagnostic(){
 const p=VS_TEST_guard(),baseline=JSON.parse(p.getProperty('VS_TEST_MIGRATION_BASELINE')||'null');
 if(!baseline)throw new Error('Retained TEST baseline required');
 const now=VS_previewOrganizedStorageMigration(),status=VS_organizedStorageStatus();
 const differences=now.collections.filter(c=>{const before=baseline.collections.find(b=>b.collection===c.collection);return !before||before.count!==c.count||before.hash!==c.hash;}).map(c=>({collection:c.collection,beforeCount:(baseline.collections.find(b=>b.collection===c.collection)||{}).count,afterCount:c.count,sourcePhase:c.sourcePhase}));
 Logger.log(JSON.stringify({event:'TEST_migration_diagnostic',phase:status.phase,collectionCursor:status.collectionCursor,binaryCursor:status.binaryCursor,differences,beforeBinaryCount:baseline.binaryCount,afterBinaryCount:now.binaryCount,beforeBinaryBytes:baseline.binaryBytes,afterBinaryBytes:now.binaryBytes,baselinePreserved:true}));
}

// A separate checkpoint includes authorized sync writes after the original dry
// run. The original baseline is retained, and every current field is hashed.
function VS_TEST_checkpointCurrent(){
 const p=VS_TEST_guard();if(p.getProperty('VS_TEST_POSTSYNC_CHECKPOINT'))throw new Error('Checkpoint already retained; verify it instead');
 const now=VS_previewOrganizedStorageMigration();
 p.setProperty('VS_TEST_POSTSYNC_CHECKPOINT',JSON.stringify({collections:now.collections.map(c=>({collection:c.collection,count:c.count,hash:c.hash})),binaryCount:now.binaryCount,binaryBytes:now.binaryBytes}));
 Logger.log(JSON.stringify({event:'TEST_postsync_checkpoint',phase:VS_organizedStorageStatus().phase,collections:now.collections.length,records:now.collections.reduce((n,c)=>n+c.count,0),binaryCount:now.binaryCount,binaryBytes:now.binaryBytes,originalBaselinePreserved:true}));
}
function VS_TEST_verifyCurrent(){
 const p=VS_TEST_guard(),baseline=JSON.parse(p.getProperty('VS_TEST_POSTSYNC_CHECKPOINT')||'null');if(!baseline)throw new Error('Post-sync checkpoint required');
 const now=VS_previewOrganizedStorageMigration(),after=now.collections.map(c=>({collection:c.collection,count:c.count,hash:c.hash}));
 if(JSON.stringify(after)!==JSON.stringify(baseline.collections)||now.binaryCount!==baseline.binaryCount||now.binaryBytes!==baseline.binaryBytes)throw new Error('Current TEST checkpoint integrity mismatch; all versions retained');
 Logger.log(JSON.stringify({event:'TEST_postsync_integrity',status:'PASS',phase:VS_organizedStorageStatus().phase,collections:after.length,records:after.reduce((n,c)=>n+c.count,0),binaryCount:now.binaryCount,binaryBytes:now.binaryBytes,originalBaselinePreserved:true}));
}
function VS_TEST_resumeCurrent(){VS_TEST_guard();const status=VS_stepOrganizedStorageMigration();Logger.log(JSON.stringify({event:'TEST_current_resume',phase:status.phase,collectionCursor:status.collectionCursor,binaryCursor:status.binaryCursor}));if(status.phase==='complete')VS_TEST_verifyCurrent();}
function VS_TEST_rollbackCurrentChunk(){VS_TEST_guard();let status=VS_organizedStorageStatus();const start=Date.now();let steps=0;while(status.phase!=='rolledBack'&&steps<5&&Date.now()-start<180000){status=VS_rollbackOrganizedStorageMigration();steps++;}Logger.log(JSON.stringify({event:'TEST_current_rollback',phase:status.phase,collectionCursor:status.collectionCursor,binaryCursor:status.binaryCursor,steps}));if(status.phase==='rolledBack')VS_TEST_verifyCurrent();}

// Read-only verification of every original synthetic category after live sync
// writes, migration and rollback. Verify content, not just collection counts.
function VS_TEST_verifySeedFixtures(){
 const p=VS_TEST_guard(),lock=LockService.getScriptLock();lock.waitLock(30000);
 try{
  const rows=[['students_directory','student'],['teachers_directory','teacher'],['teachers_directory','staff'],['attendance_logs','student'],['teacher_attendance','teacher'],['teacher_attendance','staff'],['fee_ledger',''],['fee_settings',''],['school_expenses',''],['exams',''],['exam_results',''],['teacher_salary',''],['school_notices',''],['school_config',''],['school_calendar',''],['documents',''],['scanner_devices','']];
  const context={school:p.getProperty('VS_MANAGED_SCHOOL_ID')},cache=Object.create(null);
  rows.forEach((row,n)=>{
   if(!cache[row[0]])cache[row[0]]=VS_sheetRecords(VS_managedSheet(row[0],context));
   const item=cache[row[0]]['synthetic-migration-category-'+String(n+1).padStart(2,'0')];
   if(!item||item.schoolId!==context.school||item.syntheticTest!==true||item.name!=='Synthetic TEST category '+(n+1)||item.role!==row[1]||item.category!==n+1||item.content!=='Integrity fixture = literal JSON, not a formula')throw new Error('Synthetic category content mismatch: '+(n+1));
  });
  Logger.log(JSON.stringify({event:'TEST_seed_fixture_integrity',status:'PASS',categories:rows.length,phase:VS_organizedStorageStatus().phase,writesPerformed:0}));
 }finally{lock.releaseLock();}
}

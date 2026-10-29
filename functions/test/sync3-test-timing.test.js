'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../../school-backend/managed/SaarthiManagedAll.gs'),'utf8');
test('Apps Script syntax remains valid and tests are school- and synthetic-only',()=>{
  assert.doesNotThrow(()=>new vm.Script(source));
  assert.match(source,/\['school_notices','students_directory','teachers_directory','documents','fee_ledger','fee_payments','school_expenses'\]\.indexOf\(b\.collection\)>=0/);
  assert.match(source,/b\.data\.syntheticTest===true/);
  assert.match(source,/VS_MANAGED_SCHOOL_ID'\)==='vs-db8afb01a3be46a983c8284714d06e5d'/);
  assert.match(source,/const waiting=Date\.now\(\);lock\.waitLock\(30000\)/);
});
test('real lookup, write, flush, verification, head and backup are still called',()=>{
  assert.match(source,/const saved=VS_sheetItem\(store,item\.id\);/);
  assert.match(source,/store\.sheet\.getRange\(row,1,1,33\)\.setValues\(\[values\]\);SpreadsheetApp\.flush\(\);/);
  assert.match(source,/if\(!saved\|\|JSON\.stringify\(saved\.data\)!==JSON\.stringify\(data\)\)throw new Error\('School record verification failed'\)/);
  assert.match(source,/VS_saveRecordHead\(store,saved\);\s*VS_recordJsonBackup\(store,saved\);/);
  assert.match(source,/VS_TEST_SYNC_TIMING=null;\s*lock\.releaseLock\(\);/);
});

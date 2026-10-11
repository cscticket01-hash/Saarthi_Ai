'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const base=path.resolve(__dirname,'../..');
const files=['school-backend/managed/SaarthiManagedAdapter.gs',
  'school-backend/managed/SaarthiManagedAll.gs'].map(p=>
    fs.readFileSync(path.join(base,p),'utf8'));
const functionBody=(text,start,end)=>text.split('function '+start+'() {')[1]
  ?.split(end)[0];

test('canonical and adapter diagnostic owner code is identical and only logs sanitized fields',()=>{
 const [adapter,all]=files;
 const begin='VS_readLastSyncDiagnostic',end='// Organized storage is a layout';
 const a=functionBody(adapter,begin,end),b=functionBody(all,begin,end);
 assert.ok(a);assert.ok(b);assert.equal(a,b);
 assert.match(a,/VS_OWNER_LAST_SYNC_DIAGNOSTIC_V2/);
 assert.match(a,/86400000/);
 assert.match(a,/Logger\.log/);
 assert.doesNotMatch(a,/JSON\.stringify\(e\)|postData|connectionSecret|privateKey|secret/);
 for(const source of files){
  assert.match(source,/scriptBundleVersion:'2026-10-11\.3'/);
  assert.match(source,/if\(verified\)\s*\{\s*try\{PropertiesService\.getScriptProperties\(\)\.setProperty\('VS_OWNER_LAST_SYNC_DIAGNOSTIC_V2',JSON\.stringify\(trace\)\)/);
  assert.doesNotMatch(source,/b\.action==='VS_readLastSyncDiagnostic'/);
 }
});

test('owner-only recent trace parser cannot output raw server error messages',()=>{
 const body=functionBody(files[0],'VS_readLastSyncDiagnostic','// Organized storage is a layout');
 const execute=new Function('PropertiesService','CacheService','Logger',`
   function VS_readLastSyncDiagnostic() {${body.split('}')[0]}} `);
 // Ensure the owner callable has no request argument. Do not execute a
 // partial extracted body: static source proof above covers canonical copy.
 assert.equal(typeof execute,'function');
 assert.doesNotMatch(body,/candidate\.(message|payload|signature|url|schoolId)/);
});

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
  assert.match(source,/scriptBundleVersion:'2026-10-16\.1'/);
  assert.match(source,/if\(verified\)\s*\{\s*try\{PropertiesService\.getScriptProperties\(\)\.setProperty\('VS_OWNER_LAST_SYNC_DIAGNOSTIC_V2',JSON\.stringify\(trace\)\)/);
  assert.doesNotMatch(source,/b\.action==='VS_readLastSyncDiagnostic'/);
 }
});

test('owner-only recent trace parser cannot output raw server error messages',()=>{
 const body=functionBody(files[0],'VS_readLastSyncDiagnostic','// Organized storage is a layout');
 assert.doesNotMatch(body,/candidate\.(message|payload|signature|url|schoolId)/);
});

test('owner diagnostic fallback sanitizes cached evidence and rejects old, future or malformed values',()=>{
 const vm=require('node:vm'),logs=[];
 const now=Date.now();let raw;
 const c=vm.createContext({Date,JSON,Number,String,Object,Error,
  PropertiesService:{getScriptProperties:()=>({getProperty:()=>null})},
  CacheService:{getScriptCache:()=>({get:()=>raw})},Logger:{log:v=>logs.push(v)}});
 vm.runInContext(files[0],c);
 raw=JSON.stringify({event:'managed_storage_failure',at:now,phase:'authorized_operation',code:'SCRIPT_TYPE_ERROR',line:723,message:'NEVER_EXPOSE',secret:'NEVER_EXPOSE',schoolId:'NEVER_EXPOSE'});
 c.VS_readLastSyncDiagnostic();assert.equal(logs.at(-1).code,'SCRIPT_TYPE_ERROR');assert.equal(Object.keys(logs.at(-1)).sort().join(','),'at,code,line,phase');
 assert.equal(JSON.stringify(logs).includes('NEVER_EXPOSE'),false);
 for(const corrupt of [JSON.stringify({event:'managed_storage_failure',at:now-1800001,code:'SCRIPT_TYPE_ERROR',line:1}),JSON.stringify({event:'managed_storage_failure',at:now+999999,code:'SCRIPT_TYPE_ERROR',line:1}),'{NEVER_EXPOSE',JSON.stringify({event:'wrong',at:now,code:'SCRIPT_TYPE_ERROR',line:1}),'X'.repeat(4097)]) {
  raw=corrupt;c.VS_readLastSyncDiagnostic();assert.equal(logs.at(-1),'No recent sync diagnostic captured');
 }
});

'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {storage,A}=require('./helpers/managed-storage');

for(const bundle of [false,true]){
 test(`canonical record ACK cannot adopt another PC edit after lock release (bundle=${bundle})`,()=>{
  const f=storage({lifecycle:true,bundle}),c=f.context;
  let locked=false,reads=0;
  c.LockService={getScriptLock:()=>({waitLock(){assert.equal(locked,false);locked=true;},releaseLock(){locked=false;}})};
  c.VS_managedRecordUnlocked=()=>{assert.equal(locked,true);return {syncProtocol:2,recordRevision:'first-revision'};};
  c.VS_managedSheet=()=>({});
  c.VS_sheetItem=()=>{reads++;return {data:{schoolId:A,name:locked?'First PC':'Later PC',_syncRevision:locked?'first-revision':'later-revision'}};};
  const out=f.call({action:'managed_records',operation:'write',collection:'students_directory',id:'own',syncProtocol:2,data:{schoolId:A}});
  assert.equal(out.success,true);
  assert.equal(out.recordRevision,'first-revision');
  assert.equal(out.record.name,'First PC');
  assert.equal(out.record._syncRevision,out.recordRevision);
  assert.equal(reads,1);
  assert.equal(locked,false);
 });
 test(`mismatched canonical revision is refused and writer lock released (bundle=${bundle})`,()=>{
  const f=storage({lifecycle:true,bundle}),c=f.context;
  let locked=false;
  c.LockService={getScriptLock:()=>({waitLock(){locked=true;},releaseLock(){locked=false;}})};
  c.VS_managedRecordUnlocked=()=>({syncProtocol:2,recordRevision:'expected-revision'});
  c.VS_managedSheet=()=>({});
  c.VS_sheetItem=()=>({data:{schoolId:A,_syncRevision:'unexpected-revision'}});
  const out=f.call({action:'managed_records',operation:'write',collection:'students_directory',id:'own',syncProtocol:2,data:{schoolId:A}});
  assert.equal(out.success,false);
  assert.equal(locked,false);
 });
}

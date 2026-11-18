'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync(require('node:path').join(__dirname,'../../school-backend/managed/SaarthiManagedAdapter.gs'),'utf8');
const start=source.indexOf('function VS_managedRecord(b) {'),end=source.indexOf('// Capability-gated field edits.',start);
function fixture(){
 let locked=false,lookups=0; const contexts=[];
 const c={VS_BACKUP_READ_CACHE:null,VS_TEST_SYNC_TIMING:null,
 LockService:{getScriptLock:()=>({waitLock(){assert.equal(locked,false);locked=true;},releaseLock(){locked=false;}})},
 VS_managedRecordUnlocked(b,ctx){assert.equal(locked,true);contexts.push(ctx);ctx.verifiedWorkbook={};return {recordRevision:'rev'};},
 VS_sheetLifecycleEnabled:()=>true,
 VS_managedSheet(collection,ctx){assert.equal(locked,true);assert.equal(ctx,contexts.at(-1));assert.ok(ctx.verifiedWorkbook);return {};},
 VS_sheetItem(){lookups++;return {data:{_syncRevision:'rev',schoolId:'school'}};}};
 vm.createContext(c);vm.runInContext(source.slice(start,end),c);
 return {c,contexts,lookups:()=>lookups,locked:()=>locked};
}
test('write context is same-request only and final canonical read remains under lock',()=>{
 const f=fixture();for(let i=0;i<2;i++)assert.equal(f.c.VS_managedRecord({operation:'write',collection:'students_directory',id:'one'}).record._syncRevision,'rev');
 assert.notEqual(f.contexts[0],f.contexts[1]);assert.equal(f.lookups(),2);assert.equal(f.locked(),false);
});
test('final read revision mismatch still rejects and releases lock',()=>{
 const f=fixture();f.c.VS_sheetItem=()=>({data:{_syncRevision:'other'}});
 assert.throws(()=>f.c.VS_managedRecord({operation:'write',collection:'teachers_directory',id:'one'}),/verification failed/);assert.equal(f.locked(),false);
});

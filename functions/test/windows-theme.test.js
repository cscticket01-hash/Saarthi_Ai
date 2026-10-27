'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {fixture}=require('./helpers/managed-school-broker');
test('only developer saves RGB; school session cannot bypass all-PC lock barrier',async()=>{
 const f=fixture();
 const initial=await f.call({action:'developer/managed/theme/get'},'developer');
 assert.equal(initial.theme.revision,'default');
 await assert.rejects(f.call({action:'developer/managed/theme/save',theme:{schemaVersion:1,red:255,green:0,blue:50,expectedRevision:'default'}}),e=>e.status===403);
 const saved=await f.call({action:'developer/managed/theme/save',theme:{schemaVersion:1,red:255,green:0,blue:50,expectedRevision:'default'}},'developer');
 assert.equal(saved.theme.red,255);
 const session=await f.call({action:'managed/session',appearance:true});assert.equal(session.windowsTheme.revision,'default');
 await assert.rejects(f.call({action:'developer/managed/theme/save',theme:{schemaVersion:1,red:1,green:2,blue:3,expectedRevision:'default'}},'developer'),e=>e.status===409);
 for(const v of [-1,256,1.2,'4'])await assert.rejects(f.call({action:'developer/managed/theme/save',theme:{schemaVersion:1,red:v,green:0,blue:0,expectedRevision:saved.theme.revision}},'developer'),e=>e.status===400);
 assert.equal((await f.call({action:'managed/session',appearance:true})).windowsTheme.red,0);
 assert.equal((await f.call({action:'managed/session'})).windowsTheme,undefined);
 assert.equal(f.sent.length,0);
});

const {createWindowsTheme}=require('../windows-theme');
for(const count of [1,2,5])test(`${count} PCs: colour waits for every lock, then survives staggered unlock`,async()=>{
 const f=fixture();let clock=100000;const themes=createWindowsTheme({db:f.db,now:()=>clock});
 const ids=Array.from({length:count},(_,i)=>'pc'+i), school='school-test';
 for(const id of ids)await themes.schoolState(school,id,false,ids);
 const first=await themes.save({schemaVersion:1,red:40,green:70,blue:200,expectedRevision:'default'},'dev');
 for(const id of ids.slice(0,-1))assert.equal((await themes.schoolState(school,id,true,ids)).revision,'default');
 assert.equal((await themes.schoolState(school,ids.at(-1),true,ids)).revision,first.revision);
 for(const id of ids)assert.equal((await themes.schoolState(school,id,false,ids)).revision,first.revision);
 const next=await themes.save({schemaVersion:1,red:200,green:70,blue:40,expectedRevision:first.revision},'dev');
 for(const id of ids)assert.equal((await themes.schoolState(school,id,false,ids)).revision,first.revision);
 // Unknown newly admitted PC and stale lock confirmations must block adoption.
 for(const id of ids)await themes.schoolState(school,id,true,ids);
 assert.equal((await themes.schoolState(school,ids[0],false,ids)).revision,next.revision);
});
test('unconfirmed, stale or foreign PC cannot satisfy the barrier',async()=>{
 const f=fixture();let clock=100000;const t=createWindowsTheme({db:f.db,now:()=>clock}),ids=['a','b'];
 await t.schoolState('s','a',true,ids);clock+=66000;
 await t.save({schemaVersion:1,red:1,green:2,blue:3,expectedRevision:'default'},'dev');
 assert.equal((await t.schoolState('s','b',true,ids)).revision,'default');
 assert.notEqual((await t.schoolState('s','a',true,ids)).revision,'default');
 await assert.rejects(t.schoolState('s','foreign',true,ids));
 await assert.rejects(t.schoolState('s','a','true',ids));
 assert.equal((await t.schoolState('other','a',false,ids)).revision,'default');
});
test('theme lock API requires registered PC proof and isolates schools',async()=>{
 const rows=new Map();let tail=Promise.resolve();
 const deviceStore={transaction(school,work){const result=tail.then(async()=>{const change=await work(rows.has(school)?structuredClone(rows.get(school)):null);rows.set(school,structuredClone(change.state));return change.result;});tail=result.catch(()=>{});return result;}};
 const f=fixture(undefined,{deviceManagementEnabled:true,deviceStore});
 const headers={authorization:'Bearer A','x-vidya-device-id':'1'.repeat(32),'x-vidya-device-credential':require('node:crypto').randomBytes(32).toString('base64url')};
 const call=body=>f.handle({method:'POST',headers,body});
 await call({action:'managed/device/register',deviceName:'Test PC',deviceOs:'Windows'});
 await assert.rejects(f.call({action:'managed/theme/state',locked:true}),e=>e.code==='DEVICE_PROOF_REQUIRED');
 await assert.rejects(call({action:'managed/theme/state',schoolId:require('./helpers/managed-school-broker').B,locked:true}),e=>e.status===403);
 const saved=await f.call({action:'developer/managed/theme/save',theme:{schemaVersion:1,red:4,green:5,blue:6,expectedRevision:'default'}},'developer');
 assert.equal((await call({action:'managed/theme/state',locked:false})).windowsTheme.revision,'default');
 assert.equal((await call({action:'managed/theme/state',locked:true})).windowsTheme.revision,saved.theme.revision);
 assert.equal((await call({action:'managed/theme/state',locked:false})).windowsTheme.revision,saved.theme.revision);
 assert.equal(f.sent.length,0);
});

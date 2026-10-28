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
test('upgrade preserves existing published colour and subsequent saves stay pending',async()=>{
 const f=fixture(), t=createWindowsTheme({db:f.db});
 const baseline={schemaVersion:1,red:60,green:90,blue:120,revision:'existing'};
 f.docs.set('platform_configuration/windows_theme',baseline);
 assert.deepEqual(await t.readSchool('school'),baseline);
 const next=await t.save({...baseline,red:200,expectedRevision:'existing'},'dev');
 assert.deepEqual(await t.readSchool('school'),baseline);
 assert.deepEqual(await t.schoolState('school','a',false,['a','b']),baseline);
 await t.schoolState('school','a',true,['a','b']);
 assert.equal((await t.schoolState('school','b',true,['a','b'])).revision,next.revision);
});
test('activation re-reads PC admission inside its transaction',async()=>{
 const f=fixture(),t=createWindowsTheme({db:f.db}),school='school';
 await t.schoolState(school,'a',false,['a']);
 await t.save({schemaVersion:1,red:10,green:20,blue:30,expectedRevision:'default'},'dev');
 f.docs.set('managed_pc_registries/'+school,{devices:{a:{deviceIdentity:'a',status:'active',os:'Windows'},b:{deviceIdentity:'b',status:'active',os:'Windows'}}});
 assert.equal((await t.schoolState(school,'a',true,['a'])).revision,'default');
 assert.notEqual((await t.schoolState(school,'b',true,['a','b'])).revision,'default');
 f.docs.get('managed_pc_registries/'+school).devices.a.status='revoked';
 await assert.rejects(t.schoolState(school,'a',true,['a','b']),e=>e.status===403);
});

test('all six presets survive publication, school barrier and unlock; invalid presets are rejected',async()=>{
 const {theme}=require('../windows-theme');
 const f=fixture(), t=createWindowsTheme({db:f.db});let revision='default';
 for(const presetId of ['neon-teal','electric-blue','mint-light','sunset-ember','aurora-violet','emerald-gold']){
  const saved=await t.save({schemaVersion:1,red:20,green:100,blue:180,presetId,expectedRevision:revision},'dev');
  assert.equal(saved.presetId,presetId);
  assert.equal((await t.schoolState('school','pc',false,['pc'])).revision,revision);
  await t.schoolState('school','pc',true,['pc']);
  assert.equal((await t.schoolState('school','pc',false,['pc'])).presetId,presetId);
  revision=saved.revision;
 }
 assert.throws(()=>theme({schemaVersion:1,red:0,green:0,blue:0,presetId:'unknown'}),e=>e.status===400);
 const custom=await t.save({schemaVersion:1,red:1,green:2,blue:3,presetId:null,expectedRevision:revision},'dev');
 assert.equal(custom.presetId,undefined);
});

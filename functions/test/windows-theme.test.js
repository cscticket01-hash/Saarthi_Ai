'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {fixture}=require('./helpers/managed-school-broker');
test('only developer saves RGB; school receives published theme at next session',async()=>{
 const f=fixture();
 const initial=await f.call({action:'developer/managed/theme/get'},'developer');
 assert.equal(initial.theme.revision,'default');
 await assert.rejects(f.call({action:'developer/managed/theme/save',theme:{schemaVersion:1,red:255,green:0,blue:50,expectedRevision:'default'}}),e=>e.status===403);
 const saved=await f.call({action:'developer/managed/theme/save',theme:{schemaVersion:1,red:255,green:0,blue:50,expectedRevision:'default'}},'developer');
 assert.equal(saved.theme.red,255);
 const session=await f.call({action:'managed/session'});assert.deepEqual(session.windowsTheme,saved.theme);
 await assert.rejects(f.call({action:'developer/managed/theme/save',theme:{schemaVersion:1,red:1,green:2,blue:3,expectedRevision:'default'}},'developer'),e=>e.status===409);
 for(const v of [-1,256,1.2,'4'])await assert.rejects(f.call({action:'developer/managed/theme/save',theme:{schemaVersion:1,red:v,green:0,blue:0,expectedRevision:saved.theme.revision}},'developer'),e=>e.status===400);
 assert.equal((await f.call({action:'managed/session'})).windowsTheme.red,255);
 assert.equal(f.sent.length,0);
});

'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createLiveSync,liveGrant}=require('../live-sync');
const {fixture,A,B}=require('./helpers/managed-school-broker');
test('new live authority is closed by default and normal school authorization is required',async()=>{
 const commands=[],edge={enabled:()=>true,rpc:async(s,l,b)=>{commands.push({s,l,b});return {liveProtocol:1,schoolId:s,cursor:0};},liveGrant:()=>({liveProtocol:1})};
 const disabled=fixture(null,{cloudflareSync:edge});
 await assert.rejects(disabled.call({action:'managed/live/head',liveProtocol:1}),e=>e.status===412);
 const f=fixture(null,{cloudflareSync:edge,liveSyncSchools:[A]});
 await assert.rejects(f.call({action:'managed/live/head',schoolId:B,liveProtocol:1}),e=>e.status===403);
 await assert.rejects(f.call({action:'managed/live/head',liveProtocol:0}),e=>e.status===412);
 for(const operation of ['backupClaim','backupFinish','seedPage','seedSeal'])await assert.rejects(f.call({action:'managed/live/'+operation,liveProtocol:1}),e=>e.status===400);
 assert.equal(commands.length,0);
 assert.equal((await f.call({action:'managed/live/head',liveProtocol:1,command:'backupFinish'})).liveProtocol,1);
 assert.equal(commands[0].b.command,'head');
 f.docs.get('school_entitlements/'+A).blocked=true;
 await assert.rejects(f.call({action:'managed/live/head',liveProtocol:1}),e=>e.status===403);
});
test('migration refuses changed baseline and never marks incomplete data active',async()=>{
 const commands=[];let reads=0;
 const live=createLiveSync({schools:[A],edge:{enabled:()=>true,rpc:async(s,l,b)=>{commands.push(b.command);return {state:'seeding'};}}});
 await assert.rejects(live.prepare(A,'school_expenses',async()=>({success:true,schoolId:A,syncProtocol:2,records:{},collectionRevision:++reads===1?'before':'after',unchanged:true})),e=>e.code==='LIVE_BASELINE_CHANGED');
 assert.deepEqual(commands,['seedBegin']);
 await assert.rejects(live.prepare(A,'students_directory',async()=>{}),e=>e.status===412);
});
test('foreign baseline is rejected before any cloud authority writes',async()=>{
 let writes=0;const live=createLiveSync({schools:[A],edge:{enabled:()=>true,rpc:async()=>{writes++;}}});
 await assert.rejects(live.prepare(A,'school_expenses',async()=>({success:true,schoolId:B,syncProtocol:2,records:{},collectionRevision:'other'})),e=>e.code==='LIVE_BASELINE_UNVERIFIED');
 assert.equal(writes,0);
});
test('backup identity is verified and a fake cloud revision never becomes Drive verified',async()=>{
 const finished=[];const request={collection:'school_expenses',id:'one',operation:'write',operationId:'original-operation-0001'};
 const live=createLiveSync({schools:[A],now:()=>100000,edge:{enabled:()=>true,rpc:async(s,l,b)=>b.command==='backupClaim'?{job:{seq:1,claim:'owner',request}}:(finished.push(b),{accepted:true})}});
 for(const ack of [{success:true,schoolId:B,syncProtocol:2,recordRevision:'drive'},
  {success:true,schoolId:A,syncProtocol:2,recordRevision:'live-fake'},
  {success:true,schoolId:A,syncProtocol:2,recordRevision:'drive',record:{schoolId:A,id:'foreign',_syncOperationId:request.operationId}}]){
  assert.equal((await live.drain(A,async()=>ack)).processed,0);assert.equal(finished.at(-1).verified,false);
 }
 assert.equal((await live.drain(A,async()=>({success:true,schoolId:A,syncProtocol:2,recordRevision:'drive-verified',record:{schoolId:A,id:'one',_syncOperationId:request.operationId,_syncRevision:'drive-verified'}}))).processed,1);
 assert.equal(finished.at(-1).verified,true);
});
test('stream grants have distinct signing domain, short expiry and no token in the URL',()=>{
 const g=liveGrant({schoolId:A,uid:'admin',key:'test-secret'.repeat(5),endpoint:'https://worker.invalid',now:100000});
 assert.equal(g.endpoint,'wss://worker.invalid/live');assert.equal(g.expiresAt,160000);assert.equal(g.protocols[0],'vidya-live-v1');
 assert.equal(g.endpoint.includes('grant'),false);
 const claims=JSON.parse(Buffer.from(g.protocols[1].slice(6).split('.')[0],'base64url').toString());assert.equal(claims.schoolId,A);assert.equal(claims.uid,'admin');
});

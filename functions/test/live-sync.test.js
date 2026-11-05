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
 await assert.rejects(live.prepare(A,'school_expenses',async()=>({success:true,schoolId:A,syncProtocol:2,records:{},collectionRevision:++reads===1?'before':'after',...(reads>1?{unchanged:true}:{})})),e=>e.code==='LIVE_BASELINE_CHANGED');
 assert.deepEqual(commands,['seedBegin']);
 await assert.rejects(live.prepare(A,'backups',async()=>{}),e=>e.status===412);
});
test('foreign baseline is rejected before any cloud authority writes',async()=>{
 let writes=0;const live=createLiveSync({schools:[A],edge:{enabled:()=>true,rpc:async()=>{writes++;}}});
 await assert.rejects(live.prepare(A,'school_expenses',async()=>({success:true,schoolId:B,syncProtocol:2,records:{},collectionRevision:'other'})),e=>e.code==='LIVE_BASELINE_UNVERIFIED');
 assert.equal(writes,0);
});
test('backup identity is verified and a fake cloud revision never becomes Drive verified',async()=>{
 const finished=[];const request={collection:'school_expenses',id:'one',operation:'write',operationId:'original-operation-0001',data:{schoolId:A,title:'Saved'}};
 const live=createLiveSync({schools:[A],now:()=>100000,edge:{enabled:()=>true,rpc:async(s,l,b)=>b.command==='backupClaim'?{job:{seq:1,claim:'owner',request}}:(finished.push(b),{accepted:true})}});
 for(const ack of [{success:true,schoolId:B,syncProtocol:2,recordRevision:'drive'},
  {success:true,schoolId:A,syncProtocol:2,recordRevision:'live-fake'},
  {success:true,schoolId:A,syncProtocol:2,recordRevision:'drive',record:{schoolId:A,id:'foreign',_syncOperationId:request.operationId}}]){
  assert.equal((await live.drain(A,async()=>ack)).processed,0);assert.equal(finished.at(-1).verified,false);
 }
 assert.equal((await live.drain(A,async()=>({success:true,schoolId:A,syncProtocol:2,recordRevision:'drive-verified',record:{schoolId:A,id:'one',title:'Wrong content',_syncOperationId:request.operationId,_syncRevision:'drive-verified'}}))).processed,0);
 assert.equal(finished.at(-1).verified,false);
 assert.equal((await live.drain(A,async()=>({success:true,schoolId:A,syncProtocol:2,recordRevision:'drive-verified',record:{schoolId:A,id:'one',title:'Saved',_syncOperationId:request.operationId,_syncRevision:'drive-verified'}}))).processed,1);
 assert.equal(finished.at(-1).verified,true);
});
test('stream grants have distinct signing domain, short expiry and no token in the URL',()=>{
 const g=liveGrant({schoolId:A,uid:'admin',key:'test-secret'.repeat(5),endpoint:'https://worker.invalid',now:100000});
 assert.equal(g.endpoint,'wss://worker.invalid/live');assert.equal(g.expiresAt,160000);assert.equal(g.protocols[0],'vidya-live-v1');
 assert.equal(g.endpoint.includes('grant'),false);
 const claims=JSON.parse(Buffer.from(g.protocols[1].slice(6).split('.')[0],'base64url').toString());assert.equal(claims.schoolId,A);assert.equal(claims.uid,'admin');
});

test('TEST school media preflight is licensed and does not create a live bundle or a Drive ACK',async()=>{
 const calls=[],digest='a'.repeat(64),fileId='b'.repeat(64);
 const media=[{kind:'idCard',id:fileId,uploadKey:'test-card-001',sha256:digest,
   sizeBytes:85*1024,mime:'application/pdf'}];
 const proof={bundleProtocol:1,schoolId:A,bundleId:'test-media-bundle-operation-0001',
   mediaReady:true,manifestHash:'c'.repeat(64),proofs:[{...media[0]}]};
 const edge={enabled:()=>true,rpc:async(s,l,b)=>{calls.push({s,l,b});return proof;}};
 const f=fixture(null,{cloudflareSync:edge,liveSyncSchools:[A]});
 const request={action:'managed/live/bundle-preflight',liveProtocol:1,
   bundleId:proof.bundleId,media};
 const result=await f.call(request);
 assert.equal(result.schoolId,A);assert.equal(result.mediaReady,true);
 assert.equal(result.manifestHash,proof.manifestHash);
 assert.equal(calls.length,1);
 assert.deepEqual(calls[0],{s:A,l:'live',b:{command:'bundlePrepare',bundleId:proof.bundleId,media,requireDrive:false}});
 await assert.rejects(f.call({...request,requireDrive:true}),e=>e.status===502);
 assert.equal(calls[1].b.requireDrive,true,'archive verification cannot be skipped at broker');
 const verifiedEdge={enabled:()=>true,rpc:async(s,l,b)=>({...proof,archiveReady:true,
   proofs:proof.proofs.map(item=>({...item,driveVerified:true,fileId:'verified-drive-card-0001'}))})};
 const verified=fixture(null,{cloudflareSync:verifiedEdge,liveSyncSchools:[A]});
 assert.equal((await verified.call({...request,requireDrive:true})).archiveReady,true);
 for(const mutation of [{liveProtocol:0},{bundleId:'x'},{media:[]},{media:[...media,...media,...media]}]){
  await assert.rejects(f.call({...request,...mutation}),e=>e.status===400||e.status===412);
 }
 assert.equal(calls.length,2,'invalid requests must not reach the Cloudflare owner');
 await assert.rejects(f.call({...request,schoolId:B}),e=>e.status===403);
 assert.equal(calls.length,2,'foreign school cannot inspect another school staging');
 f.docs.get('school_entitlements/'+A).blocked=true;
 await assert.rejects(f.call(request),e=>e.status===403);
 assert.equal(calls.length,2,'revoked school never receives a staged media proof');
});

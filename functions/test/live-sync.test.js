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

test('atomic person publish refuses unapproved, foreign and unmigrated school before any visible cloud write',async()=>{
 const calls=[],edge={enabled:()=>true,rpc:async(s,l,b)=>{
  calls.push({s,l,b});return {liveProtocol:1,schoolId:s};
 }};
 const disabled=fixture(null,{cloudflareSync:edge,liveSyncSchools:[A]});
 const f=fixture(null,{cloudflareSync:edge,liveSyncSchools:[A],atomicBundleTestSchools:[A]});
 const request={action:'managed/live/bundle-publish',liveProtocol:1,
  confirmIsolatedBundleTest:true,bundleId:'sync3-person-and-card-test-0001',
  mediaManifestHash:'a'.repeat(64),
  media:[{kind:'idCard',id:'b'.repeat(64),uploadKey:'person-card-test-1',
   sha256:'c'.repeat(64),sizeBytes:1024,mime:'application/pdf'}],
  operations:[{collection:'students_directory',id:'p1',operation:'write',
   operationId:'sync3-atomic-person-write-0001',expectedRevision:'',
   data:{schoolId:A,mobileStableId:'p-'+'e'.repeat(32)}},
  {collection:'documents',id:'card1',operation:'write',
   operationId:'sync3-atomic-card-write-0001',expectedRevision:'',
   data:{schoolId:A,studentId:'p1',personId:'p-'+'e'.repeat(32),ownerRole:'student'}}]};
 await assert.rejects(disabled.call(request),e=>e.status===412,
  'production default must reject even a client-confirmed TEST bundle');
 await assert.rejects(f.call({...request,confirmIsolatedBundleTest:false}),e=>e.status===400);
 await assert.rejects(f.call({...request,schoolId:B}),e=>e.status===403);
 await assert.rejects(f.call(request),e=>e.status===503,
  'native lifecycle group must have an active migration fence');
 assert.equal(calls.length,0,'no Cloudflare writes before migration proof');
 f.docs.get('school_entitlements/'+A).blocked=true;
 await assert.rejects(f.call(request),e=>e.status===403);
 assert.equal(calls.length,0);
});

test('published atomic media read is TEST-scoped, licensed and checks original Cloudflare byte hashes',async()=>{
 const bytes=Buffer.from('%PDF-1.7\\nA synthetic ID card\\n%%EOF','utf8');
 const id='b'.repeat(64),sha=require('node:crypto').createHash('sha256').update(bytes).digest('hex');
 const bundleId='media-read-published-test-0001',calls=[];
 const rpc=async(s,l,body)=>{
   calls.push({s,l,command:body.command});
   if(l==='live')return {bundleProtocol:1,schoolId:s,bundleId,
     kind:'idCard',id,sha256:sha,mime:'application/pdf',
     sizeBytes:bytes.length,archiveReady:true,fileId:'verified-drive-file-0001'};
   if(body.command==='bundleProof')return {version:1,schoolId:s,
     id,sha256:sha,mime:'application/pdf',sizeBytes:bytes.length,staged:true};
   if(body.command==='readPart')return {offset:0,sha256:sha,sizeBytes:bytes.length,
     base64:bytes.toString('base64')};
   throw Error('Unexpected media operation');
 };
 const edge={enabled:()=>true,rpc};
 const request={action:'managed/live/bundle-media',liveProtocol:1,bundleId,
   id,kind:'idCard'};
 const disabled=fixture(null,{cloudflareSync:edge,liveSyncSchools:[A]});
 await assert.rejects(disabled.call(request),e=>e.status===412);
 assert.equal(calls.length,0);
 const f=fixture(null,{cloudflareSync:edge,liveSyncSchools:[A],
   atomicBundleTestSchools:[A]});
 const delivered=await f.call(request);
 assert.equal(delivered.bundleProtocol,1);
 assert.equal(Buffer.from(delivered.base64,'base64').toString(),bytes.toString());
 assert.equal(delivered.archiveReady,true);
 assert.deepEqual(calls.map(c=>c.command),['bundleMedia','bundleProof','readPart']);
 await assert.rejects(f.call({...request,schoolId:B}),e=>e.status===403);
 await assert.rejects(f.call({...request,id:'bad'}),e=>e.status===400);
 assert.equal(calls.length,3);
 f.docs.get('school_entitlements/'+A).blocked=true;
 await assert.rejects(f.call(request),e=>e.status===403);
 assert.equal(calls.length,3);
 const corrupted=fixture(null,{cloudflareSync:{enabled:()=>true,rpc:async(s,l,body)=>
   body.command==='bundleMedia'?await rpc(s,l,body):
   body.command==='bundleProof'?await rpc(s,l,body):
   {offset:0,sizeBytes:bytes.length,sha256:sha,
     base64:Buffer.from('changed payload').toString('base64')}
 },liveSyncSchools:[A],atomicBundleTestSchools:[A]});
 await assert.rejects(corrupted.call(request),e=>e.status===502);
});

test('Android atomic ID PDF only reaches the mobile session owner of its published bundle',async()=>{
 const bytes=Buffer.from('%PDF-1.7\\nOwn ID only\\n%%EOF','utf8');
 const sha=require('node:crypto').createHash('sha256').update(bytes).digest('hex');
 const bundleId='mobile-owner-bundle-00000001',id='d'.repeat(64);
 let identity='verified-pupil';
 const edge={enabled:()=>true,rpc:async(s,l,b)=>{
  if(b.command==='ownerBundle')return {bundleProtocol:1,schoolId:s,found:true,
    bundleId,id,sha256:sha,mime:'application/pdf',sizeBytes:bytes.length};
  if(b.command==='bundleMedia')return {bundleProtocol:1,schoolId:s,
    bundleId,id,kind:'idCard',sha256:sha,mime:'application/pdf',
    sizeBytes:bytes.length,ownerRole:'student',personId:identity,archiveReady:true};
  if(b.command==='bundleProof')return {version:1,schoolId:s,
    id,sha256:sha,mime:'application/pdf',sizeBytes:bytes.length,staged:true};
  if(b.command==='readPart')return {offset:0,sizeBytes:bytes.length,
    sha256:sha,base64:bytes.toString('base64')};
  throw Error('unexpected call: '+b.command);
 }};
 const f=fixture(null,{cloudflareSync:edge,liveSyncSchools:[A],atomicBundleTestSchools:[A]});
 const request={action:'managed/mobile',schoolId:A,
   request:{action:'mobile_atomic_idcard',sessionToken:'s'.repeat(64),
      deviceId:'device-for-valid-mobile-session-0001'}};
 const answer=await f.call(request);
 assert.equal(answer.available,true);
 assert.equal(answer.contentHash,sha);
 assert.equal(answer.documentRevision,'atomic-'+bundleId);
 assert.equal(Buffer.from(answer.base64,'base64').toString(),bytes.toString());
 identity='another-student';
 await assert.rejects(f.call(request),e=>e.status===403);
 await assert.rejects(f.call({...request,schoolId:B}),
   e=>e.status===412||e.status===403,
   'another school is denied by the pilot fence before any media read');
 f.docs.get('school_entitlements/'+A).blocked=true;
 await assert.rejects(f.call(request),e=>e.status===403);
 const off=fixture(null,{cloudflareSync:edge,liveSyncSchools:[A]});
 await assert.rejects(off.call(request),e=>e.status===412);
});

test('atomic document Drive backup waits for every staged file proof and enriches only after verification',async()=>{
 const sha='d'.repeat(64),id='b'.repeat(64),bundleId='atomic-document-drive-barrier-0001';
 const media=[{kind:'idCard',id,sha256:sha,sizeBytes:1024,mime:'application/pdf'}];
 const data={schoolId:A,studentId:'p1',personId:'p-stable',
   ownerRole:'student',bundleId,bundleManifestHash:'f'.repeat(64),
   bundleMedia:media,documentKind:'idCard'};
 let archived=false,delivered=0;
 const finishes=[],rpc=async(s,l,request)=>{
  if(request.command==='backupClaim')return {job:{seq:1,claim:'claim-once',
    request:{action:'managed_records',collection:'documents',id:'card-1',
      operation:'write',operationId:'atomic-card-backup-0001',syncProtocol:2,
      expectedRecordRevision:'',data:{...data,bundleMedia:media.map(f=>({...f}))}}}};
  if(request.command==='bundleArchive'){
   if(!archived)throw Object.assign(Error('Drive media unverified'),{status:412});
   return {bundleProtocol:1,schoolId:A,bundleId,
     mediaManifestHash:data.bundleManifestHash,archiveReady:true,
     files:[{...media[0],fileId:'drive-original-file-1'}]};
  }
  if(request.command==='backupFinish'){finishes.push(request);return {accepted:true};}
  throw Error('unexpected '+request.command);
 };
 const live=createLiveSync({edge:{enabled:()=>true,rpc},schools:[A],now:()=>100000});
 const deliver=async request=>{
  delivered++;
  assert.equal(request.data.fileId,'drive-original-file-1');
  assert.equal(request.data.bundleMedia[0].sha256,sha);
  return {success:true,schoolId:A,syncProtocol:2,recordRevision:'real-drive-revision',
   record:{...request.data,_syncOperationId:request.operationId,
     _syncRevision:'real-drive-revision'}};
 };
 assert.equal((await live.drain(A,deliver)).processed,0);
 assert.equal(delivered,0,'Never send unarchived file IDs to school Script');
 assert.equal(finishes.at(-1).verified,false);
 assert.equal(finishes.at(-1).review,false);
 archived=true;
 assert.equal((await live.drain(A,deliver)).processed,1);
 assert.equal(delivered,1);
 assert.equal(finishes.at(-1).verified,true);
 assert.equal(finishes.at(-1).archiveFiles[0].fileId,'drive-original-file-1');
 assert.equal(finishes.at(-1).driveRevision,'real-drive-revision');
});

test('isolated Windows file stage verifies SHA, same-school file owner and retains Drive as pending',async()=>{
 const {createHash}=require('node:crypto');
 const bytes=Buffer.from('%PDF-1.7\\nOriginal test card\\n%%EOF','utf8');
 const sha256=createHash('sha256').update(bytes).digest('hex');
 const uploadKey='atomic-windows-test-card-0001';
 const id=createHash('sha256').update(JSON.stringify([A,uploadKey])).digest('hex');
 const calls=[],edge={enabled:()=>true,rpc:async(s,l,b)=>{
  calls.push({s,l,b});
  if(b.command==='putSmall')return {id,state:'pending',
    manifest:{...b.manifest,received:bytes.length},response:null};
  if(b.command==='bundleProof')return {version:1,schoolId:s,id,uploadKey,
    sha256,sizeBytes:bytes.length,mime:'application/pdf',
    staged:true,driveVerified:false};
  throw Error('Unexpected edge operation '+b.command);
 }};
 const health=async(_url,opt)=>{
  const outer=JSON.parse(opt.body);
  return {ok:true,status:200,text:async()=>JSON.stringify({
    success:true,schoolId:outer.schoolId,storageReady:true,
    uploadResumableVersion:1,
  })};
 };
 const f=fixture(health,{cloudflareSync:edge,liveSyncSchools:[A],
   atomicBundleTestSchools:[A],cloudflareAllDataEnabled:true,
   cloudflareAtomicSmallFiles:true});
 const request={action:'managed/live/bundle-stage',liveProtocol:1,
   schoolId:A,kind:'idCard',mime:'application/pdf',name:'id.pdf',uploadKey,
   sha256,sizeBytes:bytes.length,base64:bytes.toString('base64')};
 const result=await f.call(request);
 assert.equal(result.success,true);assert.equal(result.cloudflareAccepted,true);
 assert.equal(result.mediaReady,true);assert.equal(result.driveVerified,false);
 assert.equal(result.media.id,id);assert.equal(result.media.sha256,sha256);
 assert.equal(result.fileId,undefined,'No fake Drive ID');
 assert.deepEqual(calls.map(x=>x.b.command),['putSmall','bundleProof']);
 await assert.rejects(f.call({...request,schoolId:B}),e=>[403,412].includes(e.status));
 const number=calls.length;
 await assert.rejects(f.call({...request,sha256:'f'.repeat(64)}),e=>e.status===409);
 await assert.rejects(f.call({...request,name:'../bad.pdf'}),e=>e.status===400);
 assert.equal(calls.length,number,'Rejected manifests never reach Cloudflare');
 f.docs.get('school_entitlements/'+A).blocked=true;
 await assert.rejects(f.call(request),e=>e.status===403);
 const off=fixture(health,{cloudflareSync:edge,liveSyncSchools:[A]});
 await assert.rejects(off.call(request),e=>e.status===412);
});

test('atomic bundle receipt is scoped to the school and original wire fingerprint',async()=>{
 const bundleId='atomic-receipt-exact-wire-0001',operationId='original-atomic-receipt-operation-0001';
 const operations=[
  {collection:'students_directory',id:'student-1',operation:'write',
   operationId,expectedRevision:'',data:{schoolId:A,mobileStableId:'p-'+ '8'.repeat(32)}},
  {collection:'documents',id:'id-1',operation:'write',
   operationId:'original-atomic-card-operation-0001',expectedRevision:'',
   data:{schoolId:A,studentId:'student-1',personId:'p-'+ '8'.repeat(32)}}];
 const media=[{kind:'idCard',id:'b'.repeat(64),sha256:'a'.repeat(64),
   uploadKey:'original-card-stage-0001',sizeBytes:512,mime:'application/pdf'}];
 const backed=operations.map(op=>({collection:op.collection,id:op.id,
   operationId:op.operationId,recordRevision:'live-1',
   backupState:'pending',driveVerified:false}));
 let rpcCount=0;
 const edge={enabled:()=>true,rpc:async(s,l,b)=>{
   assert.equal(s,A);assert.equal(l,'live');
   assert.equal(b.command,'bundleReceipt');rpcCount++;
   return {found:true,bundleProtocol:1,schoolId:s,cloudState:'committed',
     mediaReady:true,driveVerified:false,backups:backed,
     receipt:{schoolId:s,bundleId,cloudState:'committed',mediaReady:true,
       acknowledgements:backed.map(x=>({operationId:x.operationId,recordRevision:x.recordRevision}))}};
 }};
 const f=fixture(null,{cloudflareSync:edge,liveSyncSchools:[A],
   atomicBundleTestSchools:[A]});
 const request={action:'managed/live/bundle-receipt',liveProtocol:1,
   bundleId,media,operations,mediaManifestHash:'f'.repeat(64)};
 const res=await f.call(request);
 assert.equal(res.success,true);assert.equal(res.found,true);
 assert.equal(res.driveVerified,false);assert.equal(rpcCount,1);
 await assert.rejects(f.call({...request,schoolId:B}),e=>e.status===403||e.status===412);
 await assert.rejects(f.call({...request,bundleId:'bad'}),e=>e.status===400);
 assert.equal(rpcCount,1);
 f.docs.get('school_entitlements/'+A).blocked=true;
 await assert.rejects(f.call(request),e=>e.status===403);
 assert.equal(rpcCount,1);
});

test('TEST atomic portrait rejects forged JPEG and MIME before starting a school upload',async()=>{
 const {createHash}=require('node:crypto');
 const calls=[];
 const edge={enabled:()=>true,rpc:async(s,l,b)=>{
   calls.push({s,l,command:b.command});
   return {};
 }};
 const f=fixture(null,{cloudflareSync:edge,liveSyncSchools:[A],
   atomicBundleTestSchools:[A],cloudflareAllDataEnabled:true,
   cloudflareAtomicSmallFiles:true});
 async function rejectsPhoto(bytes,mime,name,expected=400){
   const request={
     action:'managed/live/bundle-stage',liveProtocol:1,schoolId:A,
     kind:'photo',uploadKey:'atomic-photo-invalid-container-0001',
     name,mime,sizeBytes:bytes.length,
     sha256:createHash('sha256').update(bytes).digest('hex'),
     base64:bytes.toString('base64'),
   };
   await assert.rejects(f.call(request),e=>e.status===expected);
 }
 await rejectsPhoto(Buffer.alloc(64,11),'image/jpeg','face.jpg');
 const abbreviated=Buffer.alloc(64,0);
 abbreviated.set([0xff,0xd8,0xff,0xe1],0);
 await rejectsPhoto(abbreviated,'image/jpeg','face.jpg');
 const basic=Buffer.alloc(64,0);
 basic.set([0xff,0xd8,0xff,0xe1],0);
 basic.set([0xff,0xd9],basic.length-2);
 await rejectsPhoto(basic,'image/jpeg','face.png');
 await rejectsPhoto(basic,'image/png','face.png');
 const oversized=Buffer.alloc(40*1024+1,0);
 oversized.set([0xff,0xd8,0xff,0xe1],0);
 oversized.set([0xff,0xd9],oversized.length-2);
 await rejectsPhoto(oversized,'image/jpeg','face.jpg');
 assert.equal(calls.length,0,'Rejected photo never reaches Cloudflare');
});

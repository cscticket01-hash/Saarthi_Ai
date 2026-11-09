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
test('Delete Everywhere backup never clears Cloudflare before signed Drive AND Firebase proof',async()=>{
 const req={action:'managed_records',collection:'students_directory',id:'one',
   operation:'delete',syncProtocol:2,operationId:'original-delete-op-0001',
   expectedRecordRevision:'source-revision',deleteEverywhereVersion:1};
 const record={schoolId:A,id:'one',_syncDeleted:true,
   _syncRevision:'verified-drive-delete-revision',
   _syncOperationId:req.operationId,_syncErasePlan:{complete:true}};
 for(const missing of ['drive','firebase','erase-plan','none']){
  const finished=[];
  const live=createLiveSync({schools:[A],now:()=>100000,edge:{
    enabled:()=>true,
    rpc:async (school,lane,body)=>body.command==='backupClaim'
      ?{job:{seq:1,claim:'owner',request:req}}:
       (finished.push(body),{accepted:true})
  }});
  const ack={success:true,schoolId:A,syncProtocol:2,
    recordRevision:record._syncRevision,deleteEverywhereVersion:1,
    driveDeletionComplete:true,firebaseDeletionComplete:true,record:{...record}};
  if(missing==='drive')ack.driveDeletionComplete=false;
  if(missing==='firebase')ack.firebaseDeletionComplete=false;
  if(missing==='erase-plan')ack.record._syncErasePlan={complete:false};
  if(missing==='none'){delete ack.driveDeletionComplete;delete ack.firebaseDeletionComplete;}
  const deliver=async body=>body.operation==='read'
    ?{success:true,schoolId:A,syncProtocol:2,pointRead:true,records:{one:{...record}}}
    :ack;
  const result=await live.drain(A,deliver);
  assert.equal(result.processed,0,missing);
  assert.equal(finished.at(-1).verified,false,missing);
 }
 const finished=[];
 const live=createLiveSync({schools:[A],now:()=>100000,edge:{
   enabled:()=>true,
   rpc:async (school,lane,body)=>body.command==='backupClaim'
     ?{job:{seq:1,claim:'owner',request:req}}:
      (finished.push(body),{accepted:true})
 }});
 let reads=0;
 const ack={success:true,schoolId:A,syncProtocol:2,
   recordRevision:record._syncRevision,deleteEverywhereVersion:1,
   driveDeletionComplete:true,firebaseDeletionComplete:true,record};
 const deliver=async body=>{
  if(body.operation==='read'){
    reads++;
    return {success:true,schoolId:A,syncProtocol:2,pointRead:true,
      records:{one:{...record}}};
  }
  return ack;
 };
 assert.equal((await live.drain(A,deliver)).processed,1);
 assert.equal(reads,1,'A separate exact signed tombstone readback is mandatory');
 assert.equal(finished.at(-1).verified,true);
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
 // A forged success ACK alone is insufficient; an exact Sheets point read is mandatory.
 let pointReads=0;
 const ack={success:true,schoolId:A,syncProtocol:2,recordRevision:'drive-verified',
   record:{schoolId:A,id:'one',title:'Saved',
     _syncOperationId:request.operationId,_syncRevision:'drive-verified'}};
 assert.equal((await live.drain(A,async()=>ack)).processed,0,
   'ACK containing a record cannot substitute for a Drive read');
 assert.equal(finished.at(-1).verified,false);
 const falseRead=async b=>{
   if(b.operation==='read')return {success:true,schoolId:A,syncProtocol:2,
     pointRead:true,records:{one:{...ack.record,title:'Other school edit'}}};
   return ack;
 };
 assert.equal((await live.drain(A,falseRead)).processed,0,
   'A valid ACK with different signed Drive content stays pending');
 assert.equal(finished.at(-1).verified,false);
 const deliver=async b=>{
   if(b.operation==='read'){
     pointReads++;
     assert.equal(b.id,'one');
     return {success:true,schoolId:A,syncProtocol:2,pointRead:true,
       records:{one:{...ack.record}}};
   }
   return ack;
 };
 assert.equal((await live.drain(A,deliver)).processed,1);
 assert.equal(pointReads,1);
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

test('actual Windows exam_center_results is admitted by signed broker but cannot bypass migration gate',async()=>{
 const calls=[],f=fixture(null,{
   cloudflareSync:{enabled:()=>true,rpc:async(s,l,b)=>{
     calls.push({s,l,b});throw Error('Unmigrated business write reached Cloudflare');
   }},liveSyncSchools:[A],atomicBundleTestSchools:[A]});
 const bundleId='windows-exam-drive-original-0001',docId='SHEET-student-test-0001';
 const media=[{kind:'marksheet',id:'a'.repeat(64),uploadKey:'exam-original-0001',
   sha256:'b'.repeat(64),sizeBytes:1024,mime:'application/pdf'}];
 for(const collection of ['exam_center_results','exam_results']){
  const request={action:'managed/live/bundle-publish',liveProtocol:1,
   confirmIsolatedBundleTest:true,bundleId,mediaManifestHash:'c'.repeat(64),
   media,operations:[
    {collection,id:'exam-one_student-test',operation:'write',
     operationId:'sync3-real-exam-parent-op-00001',expectedRevision:'',
     data:{schoolId:A,studentId:'student-test',personId:'p-1111',
       marksheetDocumentId:docId,marks:{Maths:98}}},
    {collection:'documents',id:docId,operation:'write',
     operationId:'sync3-real-marksheet-doc-op-0001',expectedRevision:'',
     data:{schoolId:A,studentId:'student-test',personId:'p-1111',
       documentKind:'marksheet',examResultId:'exam-one_student-test',
       contentHash:'b'.repeat(64),mimeType:'application/pdf'}},
   ]};
  await assert.rejects(f.call(request),e=>e.status===503&&
    e.code==='LIVE_MIGRATION_NOT_ACTIVE',
    collection+' must pass broker type admission, then require verified Drive baseline');
 }
 assert.equal(calls.length,0,'Never touch Cloudflare before a verified source baseline');
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

test('signed mobile portrait reads the original same-person Cloudflare file only',async()=>{
 const bytes=Buffer.from([0xff,0xd8,0xff,0xe0,0x00,0x10,0x4a,0x46,
   0x49,0x46,0x00,0x01,0x00,0x01,0x00,0x00,0x00,0x00,0xff,0xd9]);
 const sha=require('node:crypto').createHash('sha256').update(bytes).digest('hex');
 const bundleId='mobile-original-portrait-bundle-000001',id='f'.repeat(64);
 let fileOwner='verified-pupil',noPhoto=false;const calls=[];
 const edge={enabled:()=>true,rpc:async(s,l,b)=>{
   calls.push(b.command);
   if(b.command==='ownerBundle')return {bundleProtocol:1,schoolId:s,
     found:true,bundleId,id:'e'.repeat(64),noPhoto,
     portrait:{id,sha256:sha,mime:'image/jpeg',sizeBytes:bytes.length}};
   if(b.command==='bundleMedia')return {bundleProtocol:1,schoolId:s,
     bundleId,id,kind:'photo',sha256:sha,mime:'image/jpeg',
     sizeBytes:bytes.length,ownerRole:'student',personId:fileOwner};
   if(b.command==='bundleProof')return {version:1,schoolId:s,id,
     sha256:sha,mime:'image/jpeg',sizeBytes:bytes.length,staged:true};
   if(b.command==='readPart')return {offset:0,sizeBytes:bytes.length,
     sha256:sha,base64:bytes.toString('base64')};
   throw Error('unexpected portrait operation '+b.command);
 }};
 const f=fixture(null,{cloudflareSync:edge,liveSyncSchools:[A],
   atomicBundleTestSchools:[A]});
 const req={action:'managed/mobile',schoolId:A,
   request:{action:'mobile_atomic_portrait',sessionToken:'s'.repeat(64),
     deviceId:'school-mobile-original-portrait-device-01'}};
 const result=await f.call(req);
 assert.equal(result.available,true);
 assert.equal(result.mobileAtomicPortrait,true);
 assert.equal(result.contentHash,sha);
 assert.equal(result.ownerRole,'student');
 assert.equal(Buffer.from(result.base64,'base64').toString('hex'),bytes.toString('hex'));
 const before=calls.length;
 noPhoto=true;
 const empty=await f.call(req);
 assert.equal(empty.available,false);
 assert.deepEqual(calls.slice(before),['ownerBundle'],
   'A photo-free ID must not disclose or fetch old photo bytes');
 noPhoto=false;fileOwner='foreign-pupil-generation';
 await assert.rejects(f.call(req),e=>e.status===403);
 await assert.rejects(f.call({...req,schoolId:B}),
   e=>e.status===412||e.status===403);
 const disabled=fixture(null,{cloudflareSync:edge,liveSyncSchools:[A]});
 await assert.rejects(disabled.call(req),e=>e.status===412);
});

test('expired Cloudflare original portrait falls back to exact signed Drive bytes, never a forged archive',async()=>{
 const {createHash}=require('node:crypto');
 const bytes=Buffer.from([0xff,0xd8,0xff,0xe0,0x00,0x10,0x4a,0x46,
   0x49,0x46,0x00,0x01,0x00,0x01,0x00,0x00,0x00,0x00,0xff,0xd9]);
 const sha=createHash('sha256').update(bytes).digest('hex');
 const bundleId='verified-archive-student-portrait-0001',id='c'.repeat(64);
 const image={kind:'photo',id,sha256:sha,sizeBytes:bytes.length,
   mime:'image/jpeg',fileId:'verifiedOriginalSchoolPhoto01'};
 const portrait={id,sha256:sha,sizeBytes:bytes.length,mime:'image/jpeg'};
 let archived=true,revokeAfterArchive=false,archiveRead=false;
 const rpc=async(s,l,b)=>{
   if(b.command==='ownerBundle')return {bundleProtocol:1,schoolId:s,
     found:!revokeAfterArchive||!archiveRead,bundleId,portrait,noPhoto:false};
   if(b.command==='bundleMedia')return {bundleProtocol:1,schoolId:s,
     bundleId,id,kind:'photo',sha256:sha,mime:'image/jpeg',
     sizeBytes:bytes.length,ownerRole:'student',personId:'verified-pupil'};
   if(b.command==='bundleProof')
     throw Object.assign(Error('Cloudflare bytes expired'),{status:404});
   if(b.command==='bundleArchive'){
     archiveRead=true;
     return {bundleProtocol:1,schoolId:s,
     bundleId,archiveReady:archived,files:[{kind:'idCard',id:'d'.repeat(64),
       sha256:'e'.repeat(64),mime:'application/pdf',sizeBytes:100},
       image]};
   }
   throw Error('Unexpected original school media call '+b.command);
 };
 const fetchImpl=async(_url,opt)=>{
   const envelope=JSON.parse(opt.body),payload=JSON.parse(envelope.payload);
   const result=payload.action==='managed_file'
      ?{success:true,schoolId:A,mime:'image/jpeg',base64:bytes.toString('base64')}
      :{success:true,schoolId:A,role:'student',personId:'verified-pupil'};
   return {ok:true,status:200,text:async()=>JSON.stringify(result)};
 };
 const f=fixture(fetchImpl,{cloudflareSync:{enabled:()=>true,rpc},
   liveSyncSchools:[A],atomicBundleTestSchools:[A]});
 const req={action:'managed/mobile',schoolId:A,
   request:{action:'mobile_atomic_portrait',sessionToken:'s'.repeat(64),
     deviceId:'school-portrait-archive-device-001'}};
 const success=await f.call(req);
 assert.equal(success.available,true);
 assert.equal(success.archiveReady,true);
 assert.equal(success.fileId,image.fileId);
 assert.equal(Buffer.from(success.base64,'base64').toString('hex'),bytes.toString('hex'));
 archived=false;archiveRead=false;
 await assert.rejects(f.call(req),e=>e.status===503);
 archived=true;revokeAfterArchive=true;archiveRead=false;
 await assert.rejects(f.call(req),e=>e.status===409);
});

test('atomic document Drive backup waits for every staged file proof and enriches only after verification',async()=>{
 const bytes=Buffer.alloc(1024,32);
 bytes.write('%PDF-1.7',0,'ascii');
 bytes.write('%%EOF',bytes.length-5,'ascii');
 const sha=require('node:crypto').createHash('sha256').update(bytes).digest('hex');
 const id='b'.repeat(64),bundleId='atomic-document-drive-barrier-0001';
 const media=[{kind:'idCard',id,sha256:sha,sizeBytes:1024,mime:'application/pdf'}];
 const data={schoolId:A,studentId:'p1',personId:'p-stable',
   ownerRole:'student',bundleId,bundleManifestHash:'f'.repeat(64),
   bundleMedia:media,documentKind:'idCard'};
 let archived=false,delivered=0,pointReads=0,fileReads=0;
 let savedRecord=null;
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
  if(request.operation==='read'){
   pointReads++;
   assert.equal(request.id,'card-1');
   return {success:true,schoolId:A,syncProtocol:2,pointRead:true,
     records:{'card-1':savedRecord}};
  }
  delivered++;
  assert.equal(request.data.fileId,'drive-original-file-1');
  assert.equal(request.data.bundleMedia[0].sha256,sha);
  savedRecord={...request.data,_syncOperationId:request.operationId,
   _syncRevision:'real-drive-revision'};
  return {success:true,schoolId:A,syncProtocol:2,
   recordRevision:'real-drive-revision',record:savedRecord};
 };
 const readFile=async fileId=>{
   fileReads++;assert.equal(fileId,'drive-original-file-1');
   return {success:true,schoolId:A,mime:'application/pdf',
     base64:bytes.toString('base64')};
 };
 assert.equal((await live.drain(A,deliver,readFile)).processed,0);
 assert.equal(delivered,0,'Never send unarchived file IDs to school Script');
 assert.equal(finishes.at(-1).verified,false);
 assert.equal(finishes.at(-1).review,false);
 archived=true;
 assert.equal((await live.drain(A,deliver,readFile)).processed,1);
 assert.equal(delivered,1);
 assert.equal(pointReads,1,'Always require signed exact Sheets point read');
 assert.equal(fileReads,1,'Read actual original PDF bytes back from Drive');
 assert.equal(finishes.at(-1).verified,true);
 assert.equal(finishes.at(-1).archiveFiles[0].fileId,'drive-original-file-1');
 assert.equal(finishes.at(-1).driveRevision,'real-drive-revision');
});

test('Drive file readback refuses forged ACK, mismatched PDF bytes or another school without deleting original queue',async()=>{
 const bytes=Buffer.alloc(4096,32);
 bytes.write('%PDF-1.7',0,'ascii');
 bytes.write('%%EOF',bytes.length-5,'ascii');
 const sha=require('node:crypto').createHash('sha256').update(bytes).digest('hex');
 const bundleId='archive-reject-unverified-original-0001';
 const media=[{kind:'marksheet',id:'c'.repeat(64),sha256:sha,
   mime:'application/pdf',sizeBytes:bytes.length}];
 const document={schoolId:A,documentId:'SHEET-review-1',documentKind:'marksheet',
   bundleId,bundleManifestHash:'a'.repeat(64),bundleMedia:media,
   contentHash:sha,studentId:'student-1',personId:'p-stable',
   ownerRole:'student',examResultId:'exam-1'};
 for(const alteration of ['absent-reader','foreign-school','wrong-mime','wrong-hash','truncated','bad-base64']){
  const finishes=[],calls=[];
  const rpc=async(s,l,b)=>{
   if(b.command==='backupClaim')return {job:{seq:17,claim:'original-review-claim',
      request:{action:'managed_records',collection:'documents',operation:'write',
        id:'SHEET-review-1',operationId:'exam-original-revision-0001',
        syncProtocol:2,expectedRecordRevision:'',data:{...document}}}};
   if(b.command==='bundleArchive')return {schoolId:A,bundleProtocol:1,
     bundleId,archiveReady:true,mediaManifestHash:document.bundleManifestHash,
     files:[{...media[0],fileId:'school-drive-mark-1'}]};
   if(b.command==='backupFinish'){finishes.push(b);return {accepted:true};}
   throw Error('Unexpected command: '+b.command);
  };
  const live=createLiveSync({schools:[A],now:()=>100000,
   edge:{enabled:()=>true,rpc}});
  const reader=async id=>{
   calls.push('file:'+id);
   const returned=alteration==='wrong-hash'?Buffer.from(bytes):bytes;
   if(alteration==='wrong-hash')returned[80]^=0xff;
   return {success:true,schoolId:alteration==='foreign-school'?B:A,
     mime:alteration==='wrong-mime'?'image/png':'application/pdf',
     base64:alteration==='bad-base64'?'!!!!':
       alteration==='truncated'?returned.subarray(0,-3).toString('base64'):
         returned.toString('base64')};
  };
  const deliver=async body=>{calls.push('write');throw Error('Metadata must remain pending');};
  const result=await live.drain(A,deliver,
    alteration==='absent-reader'?undefined:reader);
  assert.equal(result.processed,0,alteration);
  assert.equal(finishes.at(-1).verified,false,alteration);
  assert.deepEqual(calls,alteration==='absent-reader'?[]:['file:school-drive-mark-1'],
    'No Sheet write on unverified Drive media');
 }
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


test('isolated receipt/marksheet stage has independent 30/150 KiB PDF limits and authentic proof',async()=>{
 const {createHash}=require('node:crypto');
 const health=async(_url,opt)=>{
   const outer=JSON.parse(opt.body);
   return {ok:true,status:200,text:async()=>JSON.stringify({
     success:true,schoolId:outer.schoolId,storageReady:true,
     uploadResumableVersion:1,
   })};
 };
 for(const [kind,max] of [['receipt',30*1024],['marksheet',150*1024]]){
   const bytes=Buffer.alloc(max,32);
   bytes.write('%PDF-1.7',0,'ascii');
   bytes.write('%%EOF',max-5,'ascii');
   const sha256=createHash('sha256').update(bytes).digest('hex');
   const uploadKey='test-atomic-'+kind+'-pdf-boundary-0001';
   const id=createHash('sha256').update(JSON.stringify([A,uploadKey])).digest('hex');
   const calls=[];
   const edge={enabled:()=>true,rpc:async(s,l,b)=>{
     calls.push(b.command);
     if(b.command==='putSmall')return {id,state:'pending',
       manifest:{...b.manifest,received:bytes.length},response:null};
     if(b.command==='bundleProof')return {version:1,schoolId:s,id,uploadKey,
       sha256,sizeBytes:bytes.length,mime:'application/pdf',
       staged:true,driveVerified:false};
     throw Error('Unexpected TEST file operation '+b.command);
   }};
   const f=fixture(health,{cloudflareSync:edge,liveSyncSchools:[A],
     atomicBundleTestSchools:[A],cloudflareAllDataEnabled:true,
     cloudflareAtomicSmallFiles:true});
   const request={action:'managed/live/bundle-stage',liveProtocol:1,
     schoolId:A,kind,mime:'application/pdf',name:kind+'.pdf',uploadKey,
     sha256,sizeBytes:bytes.length,base64:bytes.toString('base64')};
   const receipt=await f.call(request);
   assert.equal(receipt.success,true);
   assert.equal(receipt.media.kind,kind);
   assert.equal(receipt.media.sizeBytes,max);
   assert.equal(receipt.media.sha256,sha256);
   assert.equal(receipt.driveVerified,false);
   assert.equal(receipt.fileId,undefined);
   assert.deepEqual(calls,['putSmall','bundleProof']);
   const oversized=Buffer.alloc(max+1,32);
   oversized.write('%PDF-1.7',0,'ascii');
   oversized.write('%%EOF',max-4,'ascii');
   const larger={...request,base64:oversized.toString('base64'),
     sizeBytes:oversized.length,
     sha256:createHash('sha256').update(oversized).digest('hex')};
   await assert.rejects(f.call(larger),e=>e.status===400);
   await assert.rejects(f.call({...request,name:'bad.png'}),e=>e.status===400);
   await assert.rejects(f.call({...request,kind:'photo'}),e=>e.status===400);
   await assert.rejects(f.call({...request,schoolId:B}),e=>[403,412].includes(e.status));
   assert.deepEqual(calls,['putSmall','bundleProof'],
     'Rejected PDF must never stage an unverified Cloudflare file');
 }
});


test('mobile financial PDF only reaches exact signed student generation and document ID',async()=>{
 const {createHash}=require('node:crypto');
 const bytes=Buffer.from('%PDF-1.7\nOriginal student financial PDF\n%%EOF');
 const sha=createHash('sha256').update(bytes).digest('hex');
 const bundleId='mobile-financial-own-verified-bundle-0001',id='e'.repeat(64);
 let fileOwner='verified-pupil',kind='receipt',documentId='FEE-own';
 const calls=[];
 const edge={enabled:()=>true,rpc:async(s,l,b)=>{
   calls.push(b.command);
   if(b.command==='ownerFinancialBundle'){
     assert.equal(b.role,kind==='receipt'?'feeReceipt':'marksheet');
     assert.equal(b.documentId,documentId);
     return {bundleProtocol:1,schoolId:s,found:true,
       documentId,bundleId,id,kind,sha256:sha,mime:'application/pdf',sizeBytes:bytes.length};
   }
   if(b.command==='bundleMedia')return {bundleProtocol:1,schoolId:s,
     bundleId,id,kind,sha256:sha,mime:'application/pdf',
     sizeBytes:bytes.length,ownerRole:kind==='receipt'?'feeReceipt':'marksheet',
     personId:fileOwner,archiveReady:false};
   if(b.command==='bundleProof')return {version:1,schoolId:s,
     id,sha256:sha,mime:'application/pdf',sizeBytes:bytes.length,staged:true};
   if(b.command==='readPart')return {offset:0,sizeBytes:bytes.length,
     sha256:sha,base64:bytes.toString('base64')};
   throw Error('Unexpected financial media operation '+b.command);
 }};
 const f=fixture(null,{cloudflareSync:edge,liveSyncSchools:[A],
   atomicBundleTestSchools:[A]});
 const request={action:'managed/mobile',schoolId:A,
   request:{action:'mobile_atomic_document',sessionToken:'s'.repeat(64),
     deviceId:'mobile-financial-session-device-0001',kind,documentId}};
 const result=await f.call(request);
 assert.equal(result.available,true);assert.equal(result.mobileAtomicDocument,true);
 assert.equal(result.documentId,documentId);assert.equal(result.contentHash,sha);
 assert.equal(result.documentRevision,'atomic-'+bundleId);
 assert.equal(Buffer.from(result.base64,'base64').toString(),bytes.toString());
 kind='marksheet';documentId='SHEET-own';
 const marksheet=await f.call({...request,request:{...request.request,kind,documentId}});
 assert.equal(marksheet.kind,'marksheet');
 assert.equal(marksheet.contentHash,sha);
 fileOwner='foreign-generation';
 await assert.rejects(f.call({...request,request:{...request.request,kind,documentId}}),
   e=>e.status===403);
 const callsBefore=calls.length;
 await assert.rejects(f.call({...request,schoolId:B}),e=>[403,412].includes(e.status));
 await assert.rejects(f.call({...request,request:{...request.request,
   kind:'receipt',documentId:'../foreign'}}),e=>e.status===400);
 assert.equal(calls.length,callsBefore,'Rejected identities never fetch file bytes');
 // Use a fresh broker cache for the revoked entitlement rather than
 // relying on a previously granted in-memory session/lease to expire.
 kind='receipt';documentId='FEE-own';fileOwner='verified-pupil';
 const blocked=fixture(null,{cloudflareSync:edge,liveSyncSchools:[A],
   atomicBundleTestSchools:[A]});
 blocked.docs.get('school_entitlements/'+A).blocked=true;
 await assert.rejects(blocked.call(request),e=>e.status===403);
});


test('signed 150 KiB published marksheet is read in full, not truncated by old 120k base64 cap',async()=>{
 const {createHash}=require('node:crypto');
 const bytes=Buffer.alloc(150*1024,32);
 bytes.write('%PDF-1.7',0,'ascii');
 bytes.write('%%EOF',bytes.length-5,'ascii');
 const sha256=createHash('sha256').update(bytes).digest('hex');
 const bundleId='full-marksheet-signed-original-0001';
 const id='f'.repeat(64),documentId='SHEET-original-full-0001';
 const edge={enabled:()=>true,rpc:async(s,l,b)=>{
   if(b.command==='ownerFinancialBundle')return{
     bundleProtocol:1,schoolId:s,found:true,bundleId,documentId,
     kind:'marksheet',id,sha256,mime:'application/pdf',
     sizeBytes:bytes.length};
   if(b.command==='bundleMedia')return{
     bundleProtocol:1,schoolId:s,bundleId,kind:'marksheet',
     id,sha256,sizeBytes:bytes.length,mime:'application/pdf',
     ownerRole:'marksheet',personId:'verified-pupil'};
   if(b.command==='bundleProof')return{
     version:1,schoolId:s,staged:true,id,sha256,
     mime:'application/pdf',sizeBytes:bytes.length};
   if(b.command==='readPart')return{
     offset:0,sizeBytes:bytes.length,sha256,base64:bytes.toString('base64')};
   throw Error('Unexpected original school file action: '+b.command);
 }};
 const f=fixture(null,{cloudflareSync:edge,liveSyncSchools:[A],
   atomicBundleTestSchools:[A]});
 const result=await f.call({action:'managed/mobile',schoolId:A,
   request:{action:'mobile_atomic_document',kind:'marksheet',documentId,
     sessionToken:'s'.repeat(64),deviceId:'original-student-device-0001'}});
 assert.equal(result.success,true);
 assert.equal(result.available,true);
 assert.equal(result.contentHash,sha256);
 assert.equal(result.sizeBytes,150*1024);
 assert.equal(result.base64.length,204800);
 assert.equal(Buffer.from(result.base64,'base64').compare(bytes),0);
});

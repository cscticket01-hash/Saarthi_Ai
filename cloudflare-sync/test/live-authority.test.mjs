import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {createHash,createHmac} from 'node:crypto';
import {createRequire} from 'node:module';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
const require=createRequire(import.meta.url);
const {canonical}=require('../../functions/live-sync-canonical');
const {liveGrant,createLiveSync}=require('../../functions/live-sync');
const {createCloudflareSync}=require('../../functions/cloudflare-sync');
const {storage}=require('../../functions/test/helpers/managed-storage');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32),key='isolated-live-authority-test-secret-00000001';
const mf=new Miniflare(convertV4MiniflareOptions({workers:[{name:'live-authority',modules:true,scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],outboundService:()=>new Response('{}',{status:503}),durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},bindings:{EDGE_KEY:key,LIVE_SYNC_TEST_SCHOOL_ID:A,BROKER_URL:'https://broker.invalid/school-cloud'}}]}));
after(()=>mf.dispose());
const edge=createCloudflareSync({url:'https://worker.invalid',key,schools:['*'],fetchImpl:(url,opt)=>mf.dispatchFetch(String(url),opt)});
const live=createLiveSync({edge,schools:[A]});
async function rpc(body,school=A){const raw=JSON.stringify({...body,schoolId:school,lane:'live'}),time=String(Date.now());const response=await mf.dispatchFetch('https://worker.invalid/internal',{method:'POST',headers:{'content-type':'application/json','x-vidya-time':time,'x-vidya-signature':createHmac('sha256',key).update(time+'\n'+raw).digest('hex')},body:raw});return {status:response.status,...await response.json()};}
async function seed(collection,records={}){const fingerprint=createHash('sha256').update(canonical(records)).digest('hex');assert.equal((await rpc({command:'seedBegin',collection,fingerprint,count:Object.keys(records).length,sourceRevision:'drive-baseline'})).status,200);if(Object.keys(records).length)assert.equal((await rpc({command:'seedPage',collection,fingerprint,rows:Object.entries(records).map(([id,data])=>({id,data}))})).status,200);assert.equal((await rpc({command:'seedSeal',collection,fingerprint})).status,200);}
const write=(id,expectedRevision='',data={amount:20})=>({command:'commit',collection:'school_expenses',id,operation:'write',operationId:'live-write-operation-'+id,expectedRevision,data:{schoolId:A,...data}});
test('verified seed is required; unsigned/foreign/unsupported authority is rejected',async()=>{
 assert.equal((await rpc(write('before-seed'))).status,412);
 assert.equal((await rpc({command:'head'},B)).status,412);
 assert.equal((await rpc({...write('student'),collection:'students_directory'})).status,412);
 const unsigned=await mf.dispatchFetch('https://worker.invalid/internal',{method:'POST',body:JSON.stringify({schoolId:A,lane:'live',command:'head'})});assert.equal(unsigned.status,401);
 await seed('school_expenses');
});
test('commit, live event, immutable operation receipt and backup job are durable together',async()=>{
 const request=write('expense-one'),first=await rpc(request);assert.equal(first.value.cloudState,'committed');assert.equal(first.value.backupState,'pending');assert.match(first.value.recordRevision,/^live-/);
 assert.deepEqual((await rpc(request)).value,first.value);
 assert.equal((await rpc({...request,data:{schoolId:A,amount:999}})).status,409);
 const read=await rpc({command:'read',collection:'school_expenses',id:'expense-one'});assert.equal(read.value.record.amount,20);
 const changes=await rpc({command:'changes',after:0});assert.equal(changes.value.events.length,1);assert.equal(changes.value.events[0].record.amount,20);
 assert.equal((await rpc({command:'stats'})).value.backups[0].count,1);
});
test('CAS race has one winner; unchanged saves do not create extra events or backup writes',async()=>{
 const before=(await rpc({command:'read',collection:'school_expenses',id:'expense-one'})).value.record;
 const results=await Promise.all([21,22].map(amount=>rpc({...write('expense-one',before._syncRevision,{amount}),operationId:'racing-operation-'+amount})));
 assert.deepEqual(results.map(r=>r.status).sort(),[200,409]);
 const winner=results.find(r=>r.status===200).value,head=(await rpc({command:'head'})).value.cursor;
 const same=await rpc({...write('expense-one',winner.recordRevision,{amount:winner.record.amount}),operationId:'unchanged-save-operation-0001'});
 assert.equal(same.value.unchanged,true);assert.equal(same.value.cursor,head);
 assert.equal((await rpc({command:'head'})).value.cursor,head);
});
test('patches alter only supplied fields; wrong school and sync metadata are rejected',async()=>{
 const before=(await rpc({command:'read',collection:'school_expenses',id:'expense-one'})).value.record;
 const patch={command:'commit',collection:'school_expenses',id:'expense-one',operation:'patch',operationId:'patch-operation-original-0001',expectedRevision:before._syncRevision,data:{schoolId:A,set:{note:'Only new field'},remove:[]}};
 const result=await rpc(patch);assert.equal(result.status,200);assert.equal(result.value.record.amount,before.amount);assert.equal(result.value.record.note,'Only new field');
 assert.equal((await rpc({...write('foreign'),data:{schoolId:B}})).status,403);
 assert.equal((await rpc({...write('forged'),data:{schoolId:A,_syncDeleted:true}})).status,400);
 assert.equal((await rpc({...patch,operationId:'patch-operation-invalid-0001',expectedRevision:result.value.recordRevision,data:{schoolId:A,set:{schoolId:B},remove:[]}})).status,400);
});
test('backup order is per record, independent keys advance, stale claims cannot certify backup',async()=>{
 await rpc(write('independent-expense'));
 const first=(await rpc({command:'backupClaim'})).value.job;assert.equal(first.request.expectedRecordRevision,'');
 const second=(await rpc({command:'backupClaim'})).value.job;assert.equal(second.request.id,'independent-expense');
 assert.equal((await rpc({command:'backupFinish',sequence:first.seq,claim:'wrong',verified:true,driveRevision:'fake'})).value.accepted,false);
 assert.equal((await rpc({command:'backupFinish',sequence:first.seq,claim:first.claim,verified:true,driveRevision:'cf-fake'})).status,400);
 assert.equal((await rpc({command:'backupFinish',sequence:first.seq,claim:first.claim,verified:true,driveRevision:'drive-first'})).value.accepted,true);
 const successor=(await rpc({command:'backupClaim'})).value.job;assert.equal(successor.request.id,'expense-one');assert.equal(successor.request.expectedRecordRevision,'drive-first');
 assert.equal((await rpc({command:'read',collection:'school_expenses',id:'expense-one'})).value.record.note,'Only new field');
 for(const job of [second,successor])assert.equal((await rpc({command:'backupFinish',sequence:job.seq,claim:job.claim,verified:true,driveRevision:'drive-'+job.seq})).value.accepted,true);
});
test('cursor pagination/receipts reject future positions; snapshot refuses a moving head',async()=>{
 const head=(await rpc({command:'head'})).value.cursor;
 assert.equal((await rpc({command:'changes',after:head+1})).status,409);
 assert.equal((await rpc({command:'received',device:'f'.repeat(64),cursor:head})).value.received,true);
 assert.equal((await rpc({command:'received',device:'f'.repeat(64),cursor:head+1})).status,400);
 const snapshot=await rpc({command:'snapshot',collection:'school_expenses',at:head});assert.equal(snapshot.value.records.length,2);
 await rpc(write('new-expense'));
 assert.equal((await rpc({command:'snapshot',collection:'school_expenses',at:head,after:'expense-one'})).status,409);
});
test('WebSocket grants are short-lived school-scoped wakeups; replay remains available without socket',async()=>{
 const grant=liveGrant({schoolId:A,uid:'admin-A',key,endpoint:'https://worker.invalid'});
 const response=await mf.dispatchFetch(grant.endpoint.replace('wss:','https:'),{headers:{Upgrade:'websocket','Sec-WebSocket-Protocol':grant.protocols.join(', ')}});
 assert.equal(response.status,101);const socket=response.webSocket;socket.accept();
 const hint=new Promise(resolve=>socket.addEventListener('message',e=>{const data=JSON.parse(e.data);if(data.cursor>0)resolve(data);},{once:true}));
 const committed=(await rpc(write('socket-expense'))).value;
 assert.equal((await hint).schoolId,A);socket.close();
 assert.ok((await rpc({command:'changes',after:committed.cursor-1})).value.events.some(e=>e.id==='socket-expense'));
 const foreign=liveGrant({schoolId:B,uid:'admin-B',key,endpoint:'https://worker.invalid'});
 assert.equal((await mf.dispatchFetch(foreign.endpoint.replace('wss:','https:'),{headers:{Upgrade:'websocket','Sec-WebSocket-Protocol':foreign.protocols.join(', ')}})).status,412);
 const expired=liveGrant({schoolId:A,uid:'admin-A',key,endpoint:'https://worker.invalid',now:Date.now()-120000});
 assert.equal((await mf.dispatchFetch(expired.endpoint.replace('wss:','https:'),{headers:{Upgrade:'websocket','Sec-WebSocket-Protocol':expired.protocols.join(', ')}})).status,401);
});
test('actual signed GS baseline and backup keep cloud and backup revisions separate',async()=>{
 for(let i=0;i<20;i++){const {job}=await live.command(A,{command:'backupClaim'});if(!job)break;await live.command(A,{command:'backupFinish',sequence:job.seq,claim:job.claim,verified:true,driveRevision:'test-drive-'+job.seq});}
 const gs=storage({lifecycle:true,bundle:true});
 await live.prepare(A,'school_calendar',body=>gs.call(body));
 const committed=await live.command(A,{...write('event-one'),collection:'school_calendar'});
 // Previous expense jobs deliberately remain in flight; finish them so the
 // calendar job is eventually selected without bypassing any owner ordering.
 for(let i=0;i<20;i++){
  const stats=await live.command(A,{command:'stats'});
  if(stats.backups.every(r=>r.state==='verified'))break;
  const {job}=await live.command(A,{command:'backupClaim'});if(!job)break;
  const ack=gs.call(job.request);assert.equal(ack.success,true,JSON.stringify(ack));
  await live.command(A,{command:'backupFinish',sequence:job.seq,claim:job.claim,verified:true,driveRevision:ack.recordRevision});
 }
 assert.match(committed.recordRevision,/^live-/);assert.equal(committed.backupState,'pending');
 const cloud=await live.read(A,'school_calendar','event-one',body=>gs.call(body));
 const backedUp=gs.call({action:'managed_records',collection:'school_calendar',operation:'read',syncProtocol:2}).records['event-one'];
 assert.ok(backedUp);assert.equal(backedUp.amount,20);assert.equal(cloud.record._syncRevision,committed.recordRevision);assert.notEqual(backedUp._syncRevision,cloud.record._syncRevision);
});
test('a rejected seed page rolls back every row and cannot activate a partial authority',async()=>{
 const collection='school_settings',records={one:{schoolId:A,value:'retained',_syncRevision:'drive-seed-one'},two:{schoolId:A,value:'second',_syncRevision:'drive-seed-two'}};
 const fingerprint=createHash('sha256').update(canonical(records)).digest('hex');
 await rpc({command:'seedBegin',collection,fingerprint,count:2,sourceRevision:'drive-settings'});
 const bad=await rpc({command:'seedPage',collection,fingerprint,rows:[{id:'one',data:records.one},{id:'two',data:{...records.two,schoolId:B}}]});assert.equal(bad.status,400);
 assert.equal((await rpc({command:'seedSeal',collection,fingerprint})).status,409);
 assert.equal((await rpc({command:'read',collection,id:'one'})).status,412);
 assert.equal((await rpc({command:'seedPage',collection,fingerprint,rows:Object.entries(records).map(([id,data])=>({id,data}))})).status,200);
 assert.equal((await rpc({command:'seedSeal',collection,fingerprint})).status,200);
 const ref=(await rpc({command:'read',collection,id:'one'})).value;assert.equal(ref.source,'drive');assert.equal(ref.record,null);assert.match(ref.payloadHash,/^[a-f0-9]{64}$/);
});
test('verified Drive handoff retains 24h cache without losing newer edits or Drive proof',async()=>{
 const gs=storage({lifecycle:true,bundle:true});
 // Use a fresh supported collection with a real signed school Drive baseline.
 await live.prepare(A,'school_notices',body=>gs.call(body));
 const after=(await live.command(A,{command:'head'})).cursor;
 const firstRequest={...write('handoff-record','',{title:'First'}),collection:'school_notices'};
 const first=await live.commit(A,firstRequest,body=>gs.call(body));
 const secondRequest={...firstRequest,operationId:'handoff-second-operation-0001',expectedRevision:first.recordRevision,data:{schoolId:A,title:'Second'}};
 const second=await live.commit(A,secondRequest,body=>gs.call(body));
 assert.equal((await live.drain(A,body=>gs.call(body))).processed,1);
 // The older verified backup must not delete the newer unbacked content.
 const pending=await live.command(A,{command:'read',collection:'school_notices',id:'handoff-record'});
 assert.equal(pending.source,'cloudflare');assert.equal(pending.record.title,'Second');
 const oldReplay=await live.command(A,{command:'commit',...firstRequest});
 assert.equal(oldReplay.record.title,'First');assert.equal(oldReplay.backupState,'verified');assert.equal(oldReplay.recordRevision,first.recordRevision);
 assert.equal((await live.drain(A,body=>gs.call(body))).processed,1);
 const reference=await live.command(A,{command:'read',collection:'school_notices',id:'handoff-record'});
 assert.equal(reference.record.title,'Second');assert.equal(reference.source,'cloudflare');assert.equal(reference.recordRevision,second.recordRevision);
 const stats=await live.command(A,{command:'stats'});assert.ok(stats.payloadCopies.records>0&&stats.payloadCopies.events>0&&stats.payloadCopies.backups>0);
 const retained=await rpc({command:'retention'});assert.equal(retained.value.retentionHours,24);assert.ok(retained.value.nextCleanupAt>Date.now());
 assert.equal((await rpc({command:'expireVerified'})).value.expired,0);
 assert.deepEqual((await live.command(A,{command:'stats'})).payloadCopies,stats.payloadCopies);
 const read=await live.read(A,'school_notices','handoff-record',body=>gs.call(body));
 assert.equal(read.record.title,'Second');assert.equal(read.record._syncRevision,second.recordRevision);
 // Replaying old events reads current Drive state, never resurrects "First".
 const replay=await live.replay(A,{command:'changes',after},body=>gs.call(body));
 assert.equal(replay.events.length,2);assert.ok(replay.events.every(e=>e.record.title==='Second'&&e.coalesced===true));
 const missing=async()=>({success:true,schoolId:A,syncProtocol:2,pointRead:true,records:{}});
 // The verified Cloudflare cache serves reads until its 24h expiry.
 assert.equal((await live.read(A,'school_notices','handoff-record',missing)).record.title,'Second');
 const foreign=async()=>({success:true,schoolId:A,syncProtocol:2,pointRead:true,records:{'handoff-record':{...read.record,schoolId:B}}});
 assert.equal((await live.read(A,'school_notices','handoff-record',foreign)).record.title,'Second');
 assert.deepEqual((await live.command(A,{command:'stats'})).payloadCopies,stats.payloadCopies);
 const cached={...secondRequest,operationId:'cached-edit-operation-0001',expectedRevision:second.recordRevision,cachedBaseline:read.record,data:{schoolId:A,title:'Third'}};
 const edited=await live.commit(A,cached,async()=>{throw Error('Exact verified cache must avoid another Drive read');});
 assert.equal(edited.record.title,'Third');assert.equal(edited.backupState,'pending');
 assert.equal((await live.drain(A,body=>gs.call(body))).processed,1);
 const changedCache={...cached,operationId:'tampered-cache-operation-0001',expectedRevision:edited.recordRevision,cachedBaseline:{...read.record,title:'Tampered'}};
 await assert.rejects(live.commit(A,{...changedCache,expectedRevision:second.recordRevision},missing),e=>e.status===409||e.code==='LIVE_REVISION_CONFLICT');
});
test('offline duplicate after cleanup retains Drive original without a new write; genuine differences stay conflicts',async()=>{
 // Seed a different record in the same real Drive instance for isolated proof.
 const gs=storage({lifecycle:true,bundle:true});
 const request={...write('offline-duplicate','',{title:'Existing original'}),collection:'school_notices'};
 const created=await live.commit(A,request,body=>gs.call(body));
 assert.equal((await live.drain(A,body=>gs.call(body))).processed,1);
 const before=(await live.command(A,{command:'head'})).cursor;
 const duplicate={...request,operationId:'offline-duplicate-operation-0001',createIntent:true};
 const repaired=await live.commit(A,duplicate,body=>gs.call(body));
 assert.equal(repaired.duplicate,true);assert.equal(repaired.resolution,'cloudRetained');assert.equal(repaired.recordRevision,created.recordRevision);assert.equal(repaired.record.title,'Existing original');
 assert.equal((await live.command(A,{command:'head'})).cursor,before);
 assert.equal((await live.drain(A,body=>gs.call(body))).processed,0);
 const cloud=await live.read(A,'school_notices','offline-duplicate',body=>gs.call(body));assert.equal(cloud.record.title,'Existing original');
 await assert.rejects(live.commit(A,{...duplicate,operationId:'different-offline-operation-0001',data:{schoolId:A,title:'Different entry'}},body=>gs.call(body)));
 assert.equal((await live.command(A,{command:'head'})).cursor,before);
 assert.ok((await live.command(A,{command:'stats'})).payloadCopies.records>0);
});

test('Sync3 metadata bundle commits all records atomically, replays without duplicates and never admits unverified PDF/media',async()=>{
 const operation=(id,revision='',amount=42)=>({
  collection:'school_expenses',id,operation:'write',
  operationId:'sync3-bundle-'+id+'-operation-0001',expectedRevision:revision,
  data:{schoolId:A,amount,description:'Synthetic isolated atomic bundle proof'}
 });
 const base={command:'bundleCommit',bundleId:'sync3-atomic-group-test-0001',
  operations:[operation('bundle-a'),operation('bundle-b','live-stale-revision')]};
 const headBefore=(await rpc({command:'head'})).value.cursor;
 // The second invalid CAS must roll back the first insert, event, job and receipt.
 assert.equal((await rpc(base)).status,409);
 assert.equal((await rpc({command:'head'})).value.cursor,headBefore);
 assert.equal((await rpc({command:'read',collection:'school_expenses',id:'bundle-a'})).value.source,'missing');
 assert.equal((await rpc({command:'operationReceipt',operationId:base.operations[0].operationId})).value.found,false);

 const request={...base,operations:[operation('bundle-a'),operation('bundle-b')]};
 const first=await rpc(request);
 assert.equal(first.status,200);
 assert.equal(first.value.cloudState,'committed');
 assert.equal(first.value.backupState,'pending');
 assert.equal(first.value.bundleProtocol,1);
 assert.equal(first.value.schoolId,A);
 assert.equal(first.value.acknowledgements.length,2);
 assert.ok(first.value.acknowledgements.every(v=>/^live-/.test(v.recordRevision)));
 assert.match(first.value.manifestHash,/^[a-f0-9]{64}$/);
 assert.equal((await rpc({command:'head'})).value.cursor,headBefore+2);
 assert.deepEqual((await rpc(request)).value,first.value,'exact original bundle replay');
 assert.equal((await rpc({command:'head'})).value.cursor,headBefore+2);
 assert.equal((await rpc({...request,operations:[operation('bundle-a','',999),operation('bundle-b')]})).status,409);
 assert.equal((await rpc({command:'head'})).value.cursor,headBefore+2);
 // Once a record operation was visible alone, it cannot be falsely declared
 // part of a later all-or-nothing bundle, even with an otherwise valid hash.
 const repack={...request,bundleId:'sync3-repackage-group-test-0001',
  operations:[operation('bundle-a'),operation('repack-new')]};
 assert.equal((await rpc(repack)).status,409);
 assert.equal((await rpc({command:'read',collection:'school_expenses',id:'repack-new'})).value.source,'missing');

 const foreign={...request,bundleId:'sync3-foreign-group-test-0001',
  operations:[operation('foreign-bundle-a'),{...operation('foreign-bundle-b'),data:{schoolId:B,amount:8}}]};
 assert.equal((await rpc(foreign)).status,403);
 assert.equal((await rpc({command:'read',collection:'school_expenses',id:'foreign-bundle-a'})).value.source,'missing');
 const missingFileStage={...request,bundleId:'sync3-media-group-test-0001',
  media:[{kind:'idCard',sizeBytes:85*1024,sha256:'a'.repeat(64)}]};
 assert.equal((await rpc(missingFileStage)).status,412);
 assert.equal((await rpc({...request,bundleId:'sync3-person-group-test-0001',
  operations:[{...operation('bundle-student-a'),collection:'students_directory'},operation('bundle-student-b')]})).status,412);
 assert.equal((await rpc({...request,bundleId:'sync3-payment-group-test-0001',
  operations:[{...operation('bundle-payment-a'),collection:'fee_payments'},operation('bundle-payment-b')]})).status,412);
 assert.equal((await rpc({command:'head'})).value.cursor,headBefore+2);
});

test('Sync 3 media preflight checks exact staged bytes and never exposes partial person bundles',async()=>{
 async function fileCommand(school,lane,body){
  const raw=JSON.stringify({...body,schoolId:school,lane}),time=String(Date.now());
  const response=await mf.dispatchFetch('https://worker.invalid/internal',{method:'POST',headers:{
   'content-type':'application/json','x-vidya-time':time,
   'x-vidya-signature':createHmac('sha256',key).update(time+'\n'+raw).digest('hex')},body:raw});
  return {status:response.status,...await response.json()};
 }
 async function stage(uploadKey,mime,bytes){
  const id=createHash('sha256').update(JSON.stringify([A,uploadKey])).digest('hex');
  const sha256=createHash('sha256').update(bytes).digest('hex');
  const manifest={uploadKey,sha256,sizeBytes:bytes.length,name:uploadKey,mime};
  const r=await fileCommand(A,'file-'+id,{command:'putSmall',id,manifest,base64:bytes.toString('base64')});
  assert.equal(r.status,200,JSON.stringify(r));
  return {id,uploadKey,sha256,sizeBytes:bytes.length,mime};
 }
 const pdf=Buffer.alloc(85*1024,32);
 pdf.write('%PDF-1.7',0,'ascii');pdf.write('%%EOF',pdf.length-5,'ascii');
 const card={kind:'idCard',...await stage('sync3-atomic-idcard-exact-85k-v1','application/pdf',pdf)};
 const body={command:'bundlePrepare',bundleId:'sync3-atomic-media-proof-0001',media:[card]};
 const before=(await rpc({command:'head'})).value.cursor;
 const first=await rpc(body);assert.equal(first.status,200,JSON.stringify(first));
 assert.equal(first.value.mediaReady,true);
 assert.equal(first.value.archiveReady,false);
 assert.equal(first.value.proofs[0].driveVerified,false);
 assert.equal((await rpc({...body,requireDrive:true})).status,412,
  'Cloudflare bytes cannot masquerade as a verified Google Drive upload');
 assert.equal(first.value.schoolId,A);
 assert.equal(first.value.proofs.length,1);
 assert.equal(first.value.proofs[0].sizeBytes,85*1024);
 assert.match(first.value.manifestHash,/^[a-f0-9]{64}$/);
 assert.deepEqual((await rpc(body)).value,first.value,'same verified files give deterministic proof');
 assert.equal((await rpc({command:'head'})).value.cursor,before,'preflight never publishes a record');

 const portrait=Buffer.alloc(40*1024,32);
 portrait.set([0xff,0xd8,0xff,0xe0],0);portrait.set([0xff,0xd9],portrait.length-2);
 const photo={kind:'photo',...await stage('sync3-atomic-photo-exact-40k-v1','image/jpeg',portrait)};
 const pair=await rpc({...body,media:[card,photo]});
 assert.equal(pair.status,200,JSON.stringify(pair));
 assert.equal(pair.value.proofs.length,2);
 assert.equal(pair.value.archiveReady,false);
 const corruptPhoto=await stage('sync3-invalid-jpeg-envelope-v1','image/jpeg',Buffer.alloc(80,32));
 assert.equal((await rpc({...body,media:[card,{kind:'photo',...corruptPhoto}]})).status,412,
  'Digest match alone cannot certify an invalid JPEG');
 assert.equal((await rpc({...body,media:[photo]})).status,412,'photo-only is never a card bundle');
 assert.equal((await rpc({...body,media:[card,card]})).status,409,'duplicate card is rejected');
 assert.equal((await rpc({...body,media:[card,{...photo,sha256:'a'.repeat(64)}]})).status,409,
  'forged digest cannot authorize staged media');
 assert.equal((await rpc({...body,media:[{...card,sizeBytes:85*1024+1}]})).status,413);
 assert.equal((await rpc({...body,media:[{...card,id:'a'.repeat(64)}]})).status,409);
 const over=Buffer.alloc(85*1024+1,32);
 over.write('%PDF-1.7',0,'ascii');over.write('%%EOF',over.length-5,'ascii');
 const tooBig={kind:'idCard',...await stage('sync3-oversize-idcard-85k-plus-one-v1','application/pdf',over)};
 assert.equal((await rpc({...body,media:[tooBig]})).status,413);
 const broken=Buffer.alloc(64,32);
 const invalid={kind:'idCard',...await stage('sync3-invalid-idcard-envelope-v1','application/pdf',broken)};
 assert.equal((await rpc({...body,media:[invalid]})).status,412,
  'a valid hash cannot turn fake PDF bytes into a valid card');
 assert.equal((await rpc({command:'bundleCommit',bundleId:'sync3-media-not-yet-committable-v1',
  operations:[{collection:'school_expenses',id:'not-committed-a',operation:'write',
   operationId:'sync3-block-partial-a-0001',expectedRevision:'',data:{schoolId:A,amount:2}},
   {collection:'school_expenses',id:'not-committed-b',operation:'write',
   operationId:'sync3-block-partial-b-0001',expectedRevision:'',data:{schoolId:A,amount:3}}],
  media:[card]})).status,412,'readiness is not an atomic person/file commit');
 // The original file lane is the sole Drive receipt owner. A matching,
 // verified completion is required before an archive-ready proof exists.
 const claim='sync3-drive-file-claim-0001';
 assert.equal((await fileCommand(A,'file-'+card.id,{command:'claim',id:card.id,
  claim,expires:Date.now()+120000})).value,true);
 const drive={success:true,schoolId:A,uploadResumableVersion:1,uploadKey:card.uploadKey,
  sha256:card.sha256,sizeBytes:card.sizeBytes,fileId:'synthetic-drive-id-card-0001',
  offset:card.sizeBytes,committed:true};
 assert.equal((await fileCommand(A,'file-'+card.id,{command:'finish',id:card.id,claim,
  values:{state:'completed',nextAttemptAt:0,result:drive}})).value,true);
 const archived=await rpc({...body,requireDrive:true});
 assert.equal(archived.status,200,JSON.stringify(archived));
 assert.equal(archived.value.archiveReady,true);
 assert.equal(archived.value.proofs[0].driveVerified,true);
 assert.equal(archived.value.proofs[0].fileId,drive.fileId);
 assert.equal((await rpc({...body,media:[card,photo],requireDrive:true})).status,412,
  'Unverified optional photo prevents a complete archive-ready bundle');
 assert.equal((await rpc({command:'head'})).value.cursor,before,'no partial bundle may reach peers');
});

test('Sync3 Cloudflare-first person and ID commit is atomic before Google Drive upload',async()=>{
 async function callLane(lane,body){
  const raw=JSON.stringify({...body,schoolId:A,lane}),time=String(Date.now());
  const r=await mf.dispatchFetch('https://worker.invalid/internal',{method:'POST',headers:{
   'content-type':'application/json','x-vidya-time':time,
   'x-vidya-signature':createHmac('sha256',key).update(time+'\n'+raw).digest('hex')},body:raw});
  return {status:r.status,...await r.json()};
 }
 await seed('students_directory');await seed('documents');
 const bytes=Buffer.alloc(1024,32);
 bytes.write('%PDF-1.7',0,'ascii');bytes.write('%%EOF',bytes.length-5,'ascii');
 const uploadKey='sync3-stage-first-idcard-file-0001';
 const id=createHash('sha256').update(JSON.stringify([A,uploadKey])).digest('hex');
 const sha256=createHash('sha256').update(bytes).digest('hex');
 const media=[{kind:'idCard',id,uploadKey,sha256,sizeBytes:bytes.length,mime:'application/pdf'}];
 const stage=await callLane('file-'+id,{command:'putSmall',id,
  manifest:{uploadKey,sha256,sizeBytes:bytes.length,mime:'application/pdf',name:'stage-card.pdf'},
  base64:bytes.toString('base64')});
 assert.equal(stage.status,200,JSON.stringify(stage));
 assert.equal(stage.value.state,'pending');
 const bundleId='sync3-cloudflare-before-drive-0001';
 const operations=[
  {collection:'students_directory',id:'student-stage-first',operation:'write',
   operationId:'sync3-stage-parent-operation-0001',expectedRevision:'',
   data:{schoolId:A,mobileStableId:'p-'+'8'.repeat(32),name:'Staged only'}},
  {collection:'documents',id:'card-stage-first',operation:'write',
   operationId:'sync3-stage-card-operation-0001',expectedRevision:'',
   data:{schoolId:A,personId:'p-'+'8'.repeat(32),studentId:'student-stage-first',
    ownerRole:'student',documentKind:'idCard',contentHash:sha256}},
 ];
 const mediaManifestHash=createHash('sha256').update(canonical({schoolId:A,bundleId,media})).digest('hex');
 const before=(await rpc({command:'head'})).value.cursor;
 assert.equal((await rpc({command:'bundlePrepare',bundleId,media,requireDrive:true})).status,412,
  'Unverified Drive must not receive an archive-ready claim');
 const commit=await rpc({command:'bundlePublish',bundleId,media,
   operations,mediaManifestHash});
 assert.equal(commit.status,200,JSON.stringify(commit));
 assert.equal(commit.value.cloudState,'committed');
 assert.equal(commit.value.mediaReady,true);
 assert.equal(commit.value.archiveReady,false);
 assert.equal(commit.value.backupState,'pending');
 const savedStatus=await rpc({command:'bundleReceipt',bundleId,media,
    operations,mediaManifestHash});
 assert.equal(savedStatus.status,200,JSON.stringify(savedStatus));
 assert.equal(savedStatus.value.found,true);
 assert.equal(savedStatus.value.cloudState,'committed');
 assert.equal(savedStatus.value.driveVerified,false);
 assert.deepEqual(savedStatus.value.backups.map(x=>x.backupState),['pending','pending']);
 assert.deepEqual(savedStatus.value.backups.map(x=>x.operationId),
    operations.map(x=>x.operationId));
 assert.equal((await rpc({command:'bundleArchive',bundleId})).status,412,
  'Drive metadata backup must wait for the actual file-lane Drive proof');
 assert.equal(commit.value.cursor,before+2);
 const doc=(await rpc({command:'read',collection:'documents',id:'card-stage-first'})).value.record;
 assert.equal(doc.bundleId,bundleId);
 assert.equal(doc.fileId,undefined,'Never invent a Drive fileId before verified ACK');
 assert.equal(doc.bundleMedia[0].sha256,sha256);
 assert.equal(doc.bundleMedia[0].fileId,undefined);
 assert.equal((await rpc({command:'head'})).value.cursor,before+2);
 assert.deepEqual((await rpc({command:'bundlePublish',bundleId,media,
   operations,mediaManifestHash})).value,commit.value,'Retry must not duplicate events');
 assert.equal((await rpc({command:'bundleMedia',bundleId,kind:'idCard',id})).value.sha256,sha256);
 const deleteCard=await rpc({command:'commit',collection:'documents',id:'card-stage-first',
   operation:'delete',operationId:'sync3-stage-card-delete-0001',
   expectedRevision:doc._syncRevision});
 assert.equal(deleteCard.status,200,JSON.stringify(deleteCard));
 assert.equal((await rpc({command:'bundleMedia',bundleId,kind:'idCard',id})).status,409,
   'A deleted ID card cannot keep its old media capability');
 assert.equal((await rpc({command:'ownerBundle',role:'student',
   personId:'p-'+'8'.repeat(32)})).value.found,false);
});

test('Sync3 archived person and document publish as one Ready transaction, never a partial peer event',async()=>{
 async function callLane(lane,body){
  const raw=JSON.stringify({...body,schoolId:A,lane}),time=String(Date.now());
  const response=await mf.dispatchFetch('https://worker.invalid/internal',{method:'POST',headers:{
   'content-type':'application/json','x-vidya-time':time,
   'x-vidya-signature':createHmac('sha256',key).update(time+'\n'+raw).digest('hex')},body:raw});
  return {status:response.status,...await response.json()};
 }
 await seed('students_directory');
 await seed('documents');
 const cardBytes=Buffer.alloc(1024,32);
 cardBytes.write('%PDF-1.7',0,'ascii');cardBytes.write('%%EOF',cardBytes.length-5,'ascii');
 const uploadKey='sync3-person-archive-idcard-0001';
 const id=createHash('sha256').update(JSON.stringify([A,uploadKey])).digest('hex');
 const sha256=createHash('sha256').update(cardBytes).digest('hex');
 const card={kind:'idCard',id,uploadKey,sha256,sizeBytes:cardBytes.length,mime:'application/pdf'};
 const lane='file-'+id;
 const staged=await callLane(lane,{command:'putSmall',id,
  manifest:{uploadKey,sha256,sizeBytes:cardBytes.length,mime:'application/pdf',name:'card.pdf'},
  base64:cardBytes.toString('base64')});
 assert.equal(staged.status,200,JSON.stringify(staged));
 const bundleId='sync3-verified-person-document-group-0001';
 const media=[card],mediaManifestHash=createHash('sha256').update(canonical({
  schoolId:A,bundleId,media})).digest('hex');
 const generation='p-'+'7'.repeat(32);
 const person={collection:'students_directory',id:'student-archive-1',operation:'write',
  operationId:'sync3-person-archive-write-0001',expectedRevision:'',
  data:{schoolId:A,mobileStableId:generation,name:'Verified Person'}};
 const document={collection:'documents',id:'card-archive-1',operation:'write',
  operationId:'sync3-document-archive-write-0001',expectedRevision:'',
  data:{schoolId:A,studentId:person.id,personId:generation,ownerRole:'student',
   type:'idCard',name:'Verified Card'}};
 const request={command:'bundlePublish',bundleId,mediaManifestHash,media,
  operations:[person,document]};
 const before=(await rpc({command:'head'})).value.cursor;
 assert.equal((await rpc({command:'head'})).value.cursor,before);
 const claim='sync3-bundle-verified-drive-claim-0001';
 assert.equal((await callLane(lane,{command:'claim',id,claim,expires:Date.now()+120000})).value,true);
 const fileId='verified-idcard-drive-file-0001';
 const finish=await callLane(lane,{command:'finish',id,claim,
  values:{state:'completed',nextAttemptAt:0,result:{success:true,schoolId:A,
   uploadResumableVersion:1,uploadKey,sha256,sizeBytes:cardBytes.length,
   fileId,committed:true,offset:cardBytes.length}}});
 assert.equal(finish.status,200,JSON.stringify(finish));
 assert.equal(finish.value,true);
 assert.equal((await rpc({...request,mediaManifestHash:'e'.repeat(64)})).status,409);
 assert.equal((await rpc({command:'head'})).value.cursor,before);
 // A document CAS conflict rolls back the already inserted person, owner
 // metadata, event and Drive backup job inside the same SQLite transaction.
 assert.equal((await rpc({...request,operations:[person,
  {...document,expectedRevision:'wrong-drive-revision'}]})).status,409);
 assert.equal((await rpc({command:'read',collection:'students_directory',id:person.id})).value.source,'missing');
 assert.equal((await rpc({command:'head'})).value.cursor,before);
 const first=await rpc(request);
 assert.equal(first.status,200,JSON.stringify(first));
 assert.equal(first.value.archiveReady,true);
 assert.equal(first.value.acknowledgements.length,2);
 assert.equal(first.value.files[0].fileId,fileId);
 const saved=(await rpc({command:'read',collection:'documents',id:document.id})).value.record;
 assert.equal(saved.bundleMedia[0].fileId,fileId);
 assert.equal(saved.bundleManifestHash,mediaManifestHash);
 assert.equal(saved.bundleId,bundleId,'document keeps the server-attested bundle lookup identity');
 const mediaCapability=await rpc({command:'bundleMedia',bundleId,kind:'idCard',id});
 assert.equal(mediaCapability.status,200);
 assert.equal(mediaCapability.value.sha256,sha256);
 assert.equal(mediaCapability.value.fileId,fileId);
 const archiveHandoff=await rpc({command:'bundleArchive',bundleId});
 assert.equal(archiveHandoff.status,200,JSON.stringify(archiveHandoff));
 assert.equal(archiveHandoff.value.archiveReady,true);
 assert.equal(archiveHandoff.value.files[0].fileId,fileId);
 assert.equal(archiveHandoff.value.mediaManifestHash,mediaManifestHash);
 const owner=await rpc({command:'ownerBundle',role:'student',personId:generation});
 assert.equal(owner.status,200);
 assert.equal(owner.value.found,true);
 assert.equal(owner.value.bundleId,bundleId);
 assert.equal(owner.value.sha256,sha256);
 assert.equal(owner.value.noPhoto,true);
 assert.equal((await rpc({command:'ownerBundle',role:'teacher',personId:generation})).value.found,false);
 assert.equal(mediaCapability.value.ownerRole,'student');
 assert.equal(mediaCapability.value.personId,generation);
 assert.equal((await rpc({command:'bundleMedia',bundleId,kind:'photo',id})).status,403);
 assert.equal((await rpc({command:'bundleMedia',bundleId:'missing-published-bundle-0001',kind:'idCard',id})).status,404);
 assert.equal((await rpc({command:'head'})).value.cursor,before+2);
 assert.deepEqual((await rpc(request)).value,first.value,'immutable replay does not need a new Drive write');
 assert.equal((await rpc({command:'head'})).value.cursor,before+2);
 assert.equal((await rpc({...request,operations:[person,
  {...document,data:{...document.data,name:'forged change'}}]})).status,409);
 assert.equal((await rpc({command:'head'})).value.cursor,before+2);
});


test('atomic replay pages never split a bundle at their byte budget or deliver a partial cursor',async()=>{
 const before=(await rpc({command:'head'})).value.cursor;
 const large={command:'commit',collection:'school_expenses',id:'budget-previous-record',
  operation:'write',operationId:'budget-previous-write-00001',expectedRevision:'',
  data:{schoolId:A,amount:1,description:'p'.repeat(220000)}};
 assert.equal((await rpc(large)).status,200);
 const op=id=>({collection:'school_expenses',id,operation:'write',
  operationId:'budget-atomic-'+id+'-0001',expectedRevision:'',
  data:{schoolId:A,amount:2,description:'q'.repeat(55000)}});
 const group={command:'bundleCommit',bundleId:'budget-atomic-bundle-id-0001',
  operations:[op('budget-bundle-first'),op('budget-bundle-second')]};
 const receipt=await rpc(group);
 assert.equal(receipt.status,200,JSON.stringify(receipt));
 assert.equal(receipt.value.cursor,before+3);
 const first=(await rpc({command:'changes',after:before})).value;
 assert.equal(first.events.length,1,'first page must stop before the entire 2-record bundle');
 assert.equal(first.cursor,before+1);
 assert.equal(first.more,true);
 const next=(await rpc({command:'changes',after:first.cursor})).value;
 assert.deepEqual(next.events.map(e=>e.id),['budget-bundle-first','budget-bundle-second']);
 assert.deepEqual(next.events.map(e=>e.bundleIndex),[0,1]);
 assert.deepEqual(next.events.map(e=>e.bundleSize),[2,2]);
 assert.ok(next.events.every(e=>e.bundleId===group.bundleId));
 assert.equal(next.cursor,before+3);
 assert.equal((await rpc({command:'changes',after:before+2})).status,409,
  'a previously broken peer cursor may not resume in the middle of a bundle');
 assert.deepEqual((await rpc(group)).value,receipt.value,'replay does not create new events');
 assert.equal((await rpc({command:'head'})).value.cursor,before+3);
});


test('one existing school file owner proves exact 30 KiB receipts and 150 KiB marksheets without visible bundles',async()=>{
 async function fileCall(lane,body){
   const raw=JSON.stringify({...body,schoolId:A,lane});
   const time=String(Date.now());
   const response=await mf.dispatchFetch('https://worker.invalid/internal',{
     method:'POST',headers:{
       'content-type':'application/json','x-vidya-time':time,
       'x-vidya-signature':createHmac('sha256',key)
         .update(time+'\n'+raw).digest('hex'),
     },body:raw,
   });
   return {status:response.status,...await response.json()};
 }
 const before=(await rpc({command:'head'})).value.cursor;
 for(const [kind,size] of [['receipt',30*1024],['marksheet',150*1024]]){
   const bytes=Buffer.alloc(size,32);
   bytes.write('%PDF-1.7',0,'ascii');
   bytes.write('%%EOF',size-5,'ascii');
   const uploadKey='isolated-'+kind+'-stage-original-0001';
   const id=createHash('sha256').update(JSON.stringify([A,uploadKey])).digest('hex');
   const sha256=createHash('sha256').update(bytes).digest('hex');
   const staged=await fileCall('file-'+id,{
     command:'putSmall',id,manifest:{
       uploadKey,sha256,sizeBytes:size,name:kind+'.pdf',
       mime:'application/pdf',
     },base64:bytes.toString('base64'),
   });
   assert.equal(staged.status,200,JSON.stringify(staged));
   const proof=await fileCall('file-'+id,{
     command:'bundleProof',id,requireDrive:false,
   });
   assert.equal(proof.status,200,JSON.stringify(proof));
   assert.equal(proof.value.staged,true);
   assert.equal(proof.value.sha256,sha256);
   assert.equal(proof.value.sizeBytes,size);
   assert.equal(proof.value.driveVerified,false);
   assert.equal(proof.value.fileId,undefined);
   const forbidden=await rpc({command:'bundlePrepare',
     bundleId:'isolated-'+kind+'-not-publishable-0001',
     media:[{kind,id,uploadKey,sha256,sizeBytes:size,mime:'application/pdf'}],
   });
   assert.notEqual(forbidden.status,200,
     'Staging a document alone must never make a business receipt/marksheet publishable');
 }
 assert.equal((await rpc({command:'head'})).value.cursor,before,
   'Temporary Cloudflare file staging cannot create a live record or Drive ACK');
});

test('fee payment, ledger and PDF share one original school DO commit; exam result and marksheet also atomic',async()=>{
 async function fileCall(lane,body){
  const raw=JSON.stringify({...body,schoolId:A,lane}),time=String(Date.now());
  const response=await mf.dispatchFetch('https://worker.invalid/internal',{
   method:'POST',headers:{'content-type':'application/json','x-vidya-time':time,
    'x-vidya-signature':createHmac('sha256',key).update(time+'\n'+raw).digest('hex')},body:raw});
  return {status:response.status,...await response.json()};
 }
 await seed('fee_payments');await seed('fee_ledger');await seed('exam_results');
 const studentId='student-stage-first',personId='p-'+'8'.repeat(32);
 for(const kind of ['receipt','marksheet']){
  const fee=kind==='receipt',size=fee?2048:4096;
  const bytes=Buffer.alloc(size,32);
  bytes.write('%PDF-1.7',0,'ascii');bytes.write('%%EOF',size-5,'ascii');
  const uploadKey='finance-atomic-'+kind+'-unique-0001',
   id=createHash('sha256').update(JSON.stringify([A,uploadKey])).digest('hex'),
   sha256=createHash('sha256').update(bytes).digest('hex');
  const media=[{kind,id,uploadKey,sha256,sizeBytes:size,mime:'application/pdf'}];
  const stage=await fileCall('file-'+id,{command:'putSmall',id,
   manifest:{uploadKey,sha256,sizeBytes:size,mime:'application/pdf',name:kind+'.pdf'},
   base64:bytes.toString('base64')});
  assert.equal(stage.status,200,JSON.stringify(stage));
  const bundleId='financial-school-atomic-'+kind+'-0001';
  const data={schoolId:A,studentId,personId};
  const docId=fee?'FEE-finance-atomic-001':'SHEET-exam-atomic-001';
  const parentId=fee?'finance-atomic-001':'exam-atomic-001';
  const head=fee?{collection:'fee_payments',id:parentId,operation:'write',
   operationId:'finance-original-payment-operation-0001',expectedRevision:'',
   data:{...data,paymentId:parentId,receiptDocumentId:docId,month:'2026-11',
    installmentAmount:50,totalPaid:50,expectedAmount:100}}:
   {collection:'exam_results',id:parentId,operation:'write',
    operationId:'finance-original-exam-operation-00001',expectedRevision:'',
    data:{...data,marksheetDocumentId:docId,score:98}};
  const ledger={collection:'fee_ledger',id:'ledger-finance-001',operation:'write',
    operationId:'finance-original-ledger-operation-0001',expectedRevision:'',
    data:{...data,month:'2026-11',lastPaymentId:parentId,totalPaid:50}};
  const doc={collection:'documents',id:docId,operation:'write',
    operationId:fee?'finance-original-receipt-operation-0001':'finance-original-marksheet-op-0001',
    expectedRevision:'',data:{...data,ownerRole:'student',
     documentKind:fee?'feeReceipt':'marksheet',documentId:docId,
     ...(fee?{}:{examResultId:parentId}),
     contentHash:sha256,mimeType:'application/pdf'}};
  const operations=fee?[head,ledger,doc]:[head,doc];
  const mediaManifestHash=createHash('sha256').update(canonical({
    schoolId:A,bundleId,media})).digest('hex');
  const before=(await rpc({command:'head'})).value.cursor;
  const gate=await rpc({command:'bundlePrepare',bundleId,media});
  assert.equal(gate.status,200,JSON.stringify(gate));
  assert.equal(gate.value.mediaReady,true);
  assert.equal(gate.value.archiveReady,false);
  const tampered=operations.map((op,i)=>i===operations.length-1?{...op,
    data:{...op.data,contentHash:'a'.repeat(64)}}:op);
  assert.equal((await rpc({command:'bundlePublish',bundleId,
    media,operations:tampered,mediaManifestHash})).status,409,
    'Wrong original PDF hash must not publish a financial record');
  assert.equal((await rpc({command:'head'})).value.cursor,before);
  const request={command:'bundlePublish',bundleId,media,operations,mediaManifestHash};
  const commit=await rpc(request);
  assert.equal(commit.status,200,JSON.stringify(commit));
  assert.equal(commit.value.cloudState,'committed');
  assert.equal(commit.value.mediaReady,true);
  assert.equal(commit.value.archiveReady,false);
  assert.equal(commit.value.acknowledgements.length,operations.length);
  assert.equal((await rpc({command:'head'})).value.cursor,before+operations.length);
  const group=(await rpc({command:'changes',after:before})).value.events;
  assert.deepEqual(group.map(x=>x.bundleIndex),operations.map((_,i)=>i));
  assert.deepEqual(group.map(x=>x.bundleSize),operations.map(()=>operations.length));
  const stored=(await rpc({command:'read',collection:'documents',id:docId})).value.record;
  assert.equal(stored.bundleId,bundleId);
  assert.equal(stored.bundleMedia[0].sha256,sha256);
  assert.equal(stored.fileId,undefined,'No fabricated Drive file ID');
  assert.equal((await rpc({command:'bundleMedia',bundleId,kind,id})).value.sha256,sha256);
  const recovered=await rpc({command:'bundleReceipt',bundleId,media,
    operations,mediaManifestHash});
  assert.equal(recovered.status,200,JSON.stringify(recovered));
  assert.equal(recovered.value.driveVerified,false);
  assert.equal(recovered.value.backups.length,operations.length);
  assert.deepEqual((await rpc(request)).value,commit.value,'Exact replay is immutable');
  assert.equal((await rpc({...request,operations:tampered})).status,409);
  assert.equal((await rpc({command:'bundlePublish',bundleId,media,operations,
    mediaManifestHash},B)).status,412,'Another school cannot borrow this staged PDF');
 }
});

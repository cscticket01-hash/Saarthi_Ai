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
 const cloud=await live.command(A,{command:'read',collection:'school_calendar',id:'event-one'});
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
 assert.equal((await rpc({command:'read',collection,id:'one'})).value.record.value,'retained');
});

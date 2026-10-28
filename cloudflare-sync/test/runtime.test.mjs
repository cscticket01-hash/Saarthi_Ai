import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {createHmac,createHash} from 'node:crypto';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
const key='development-only-not-a-production-secret-0000';
const school='vs-'+'f'.repeat(32),other='vs-'+'e'.repeat(32);
const mf=new Miniflare(convertV4MiniflareOptions({workers:[{name:"sync",modules:true,scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],outboundService:async()=>new Response('{}',{status:503}),durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},bindings:{EDGE_KEY:key,BROKER_URL:'https://broker.invalid/school-cloud'}}]}));
after(async()=>{await mf.dispose();});
async function rpc(command,data={},lane='notices',s=school){const body=JSON.stringify({...data,command,schoolId:s,lane});const time=String(Date.now());const r=await mf.dispatchFetch('https://worker.invalid/internal',{method:'POST',headers:{'content-type':'application/json','x-vidya-time':time,'x-vidya-signature':createHmac('sha256',key).update(time+'\n'+body).digest('hex')},body});return {status:r.status,...await r.json()};}
test('unsigned clients cannot create/read scoped school operations',async()=>{const r=await mf.dispatchFetch('https://worker.invalid/internal',{method:'POST',body:JSON.stringify({schoolId:school,lane:'notices',command:'snapshot'})});assert.equal(r.status,401);});
test('durable notice receipt precedes Drive delivery, survives retries, isolates schools and rejects stale writes',async()=>{
 const seed=await rpc('seed',{records:{},revision:'legacy'});assert.equal(seed.status,200);
 const request={action:'managed_records',collection:'school_notices',operation:'write',syncProtocol:2,id:'notice-a',operationId:'operation-000000000001',expectedRecordRevision:'',data:{schoolId:school,title:'First'}};
 const first=await rpc('write',{request});assert.equal(first.status,200);assert.equal(first.value.driveState,'pending');assert.equal(first.value.record.title,'First');
 const duplicate=await rpc('write',{request});assert.deepEqual(duplicate.value,first.value);
 const foreign=await rpc('snapshot',{},'notices',other);assert.equal(foreign.value.initialized,false);
 const stale=await rpc('write',{request:{...request,operationId:'operation-000000000002',data:{schoolId:school,title:'Bad overwrite'}}});assert.equal(stale.status,409);
 const conflict=await rpc('write',{request:{...request,data:{schoolId:school,title:'Changed replay'}}});assert.equal(conflict.status,409);
 const next=await rpc('write',{request:{...request,operationId:'operation-000000000003',expectedRecordRevision:first.value.recordRevision,data:{schoolId:school,title:'Second'}}});assert.equal(next.value.record.title,'Second');
 const pending=await rpc('pending',{limit:25});assert.equal(pending.value.length,1); // FIFO even with two edits.
 const job=pending.value[0];assert.equal(await rpc('claim',{id:job.id,claim:'claim-one',expires:Date.now()+10000}).then(r=>r.value),true);
 assert.equal(await rpc('claim',{id:job.id,claim:'claim-two',expires:Date.now()+10000}).then(r=>r.value),false);
 await rpc('finish',{id:job.id,claim:'wrong-claim',values:{state:'completed',nextAttemptAt:Number.MAX_SAFE_INTEGER,driveRevision:'wrong'}});
 assert.equal((await rpc('get',{id:job.id})).value.state,'processing');
 await rpc('finish',{id:job.id,claim:'claim-one',values:{state:'completed',nextAttemptAt:Number.MAX_SAFE_INTEGER,completedAt:Date.now(),driveRevision:'drive-one'}});
 assert.equal((await rpc('receipt',{revision:first.value.recordRevision})).value.response.driveRevision,'drive-one');
 assert.equal((await rpc('snapshot')).value.records['notice-a'].title,'Second');
});
test('attendance has durable idempotent receipts across partitions and exact claim fencing',async()=>{
 const id='a1'+'b'.repeat(62),lane='attendance-a1',row={operationId:id,schoolId:school,createdAt:Date.now(),day:'2026-10-28',mode:'entry',payload:{encrypted:'opaque'},state:'pending',attempts:0};
 assert.equal((await rpc('create',{id,row},lane)).value,true);
 assert.equal((await rpc('create',{id,row},lane)).value,false);
 assert.equal((await rpc('create',{id,row:{...row,schoolId:other}},lane)).status,400);
 assert.equal((await rpc('get',{id},lane,other)).value,null);
 const queued=(await rpc('pending',{limit:25},lane)).value;assert.equal(queued.length,1);
 await rpc('claim',{id,claim:'one',expires:Date.now()+10000},lane);
 await rpc('finish',{id,claim:'one',values:{state:'retry',nextAttemptAt:Date.now()+10000}},lane);
 assert.equal((await rpc('get',{id},lane)).value.state,'retry');
});
const sha=s=>createHash('sha256').update(s).digest('hex');
test('direct mobile grants enforce school, session, QR, geofence and expiry before accepting encrypted attendance',async()=>{
 const p={schoolId:school,sessionHash:sha('session'),expiresAt:Date.now()+60000,role:'student',personId:'stable',documentId:'student-a',qrHash:sha('student/student-a/qr-secret'),day:new Date(Date.now()+19800000).toISOString().slice(0,10),open:true,latitude:26,longitude:92,radiusMeters:100};
 const value=Buffer.from(JSON.stringify(p)).toString('base64url'),grant=value+'.'+createHmac('sha256',key).update(value).digest('hex');
 const body={schoolId:school,grant,request:{action:'mobile_mark_attendance',role:'student',personId:'student-a',linkToken:'qr-secret',sessionToken:'session',latitude:26,longitude:92,accuracy:5,mode:'entry',clientCapturedAt:Date.now()}};
 const send=async b=>{const r=await mf.dispatchFetch('https://worker.invalid/mobile',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(b)});return {status:r.status,...await r.json()};};
 assert.equal((await send({...body,schoolId:other})).status,409);
 assert.equal((await send({...body,request:{...body.request,sessionToken:'other'}})).status,409);
 assert.equal((await send({...body,request:{...body.request,latitude:27}})).status,400);
 const ack=await send(body);assert.equal(ack.status,200);assert.equal(ack.accepted,true);assert.equal(ack.driveState,'pending');
 assert.equal((await send(body)).duplicate,true);
 const stored=(await rpc('get',{id:ack.operationId},'attendance-'+ack.operationId.slice(0,2))).value;
 assert.equal(JSON.stringify(stored).includes('qr-secret'),false);assert.equal(JSON.stringify(stored).includes('sessionToken'),false);
 const status=await send({...body,request:{...body.request,action:'mobile_attendance_status',operationIds:[ack.operationId]}});assert.equal(status.operations[0].state,'pending');
 assert.equal((await send({...body,request:{...body.request,action:'mobile_attendance_status',operationIds:['f'.repeat(64)]}})).status,400);
});

test('broker integration seeds existing Drive notices, acknowledges Cloudflare first and delivers edits in exact revision order',async()=>{
 const {createRequire}=await import('node:module');const require=createRequire(import.meta.url);
 const {createCloudflareSync}=require('../../functions/cloudflare-sync.js');
 const {fixture,A}=require('../../functions/test/helpers/managed-school-broker.js');
 const edge=createCloudflareSync({url:'https://worker.invalid/',key,schools:[A],fetchImpl:(url,options)=>mf.dispatchFetch(String(url),options)});
 const drive=new Map(),writes=[];
 const f=fixture(async(_,options)=>{
  const envelope=JSON.parse(options.body),b=JSON.parse(envelope.payload);
  if(b.operation==='read')return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,syncProtocol:2,collectionRevision:'drive-head',records:Object.fromEntries(drive)})};
  writes.push(b);const previous=drive.get(b.id);assert.equal(b.expectedRecordRevision,previous?._syncRevision||'');
  const record={...b.data,id:b.id,schoolId:A,_syncRevision:'drive-'+writes.length};drive.set(b.id,record);
  return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:A,syncProtocol:2,recordRevision:record._syncRevision,record})};
 },{cloudflareSync:edge});
 const request={action:'managed/records',collection:'school_notices',operation:'write',syncProtocol:2,id:'new',operationId:'notice-integration-000001',expectedRecordRevision:'',data:{title:'Fast'}};
 const first=await f.call(request);assert.equal(first.cloudflareAccepted,true);assert.equal(first.driveState,'pending');assert.equal(writes.length,0);
 const snapshot=await f.call({action:'managed/records',collection:'school_notices',operation:'read',syncProtocol:2});assert.equal(snapshot.records.new.title,'Fast');
 const next=await f.call({...request,operationId:'notice-integration-000002',expectedRecordRevision:first.recordRevision,data:{title:'Edited'}});assert.equal(writes.length,0);
 const deliver=async b=>{writes.push(b);const previous=drive.get(b.id);assert.equal(b.expectedRecordRevision,previous?._syncRevision||'');const record={...b.data,id:b.id,schoolId:A,_syncRevision:'drive-'+writes.length};drive.set(b.id,record);return {syncProtocol:2,recordRevision:record._syncRevision,record};};
 await edge.drainNotices(A,deliver);await edge.drainNotices(A,deliver);
 assert.equal(writes.length,2);assert.equal(drive.get('new').title,'Edited');
 assert.equal((await f.call({action:'managed/records',collection:'school_notices',operation:'read',syncProtocol:2})).records.new._syncRevision,next.recordRevision);
 const delta=await f.call({action:'managed/changes',collections:['school_notices'],knownRevisions:{school_notices:'old'},knownRecordRevisions:{school_notices:{}}});assert.equal(delta.changes.school_notices.records.new.title,'Edited');
 await assert.rejects(f.call({...request,expectedRecordRevision:'stale'}),e=>e.status===409);
 await assert.rejects(f.call({...request,schoolId:other}),e=>e.status===403);
});


test('a rejected attendance receipt remains visible to school transfer status instead of reporting Drive complete',async()=>{
 const id='d1'+'c'.repeat(62),lane='attendance-d1',tenant='vs-'+'9'.repeat(32);
 await rpc('create',{id,row:{operationId:id,schoolId:tenant,createdAt:Date.now(),payload:{encrypted:'synthetic'}}},lane,tenant);
 await rpc('claim',{id,claim:'review',expires:Date.now()+10000},lane,tenant);
 await rpc('finish',{id,claim:'review',values:{state:'needsAttention',nextAttemptAt:Number.MAX_SAFE_INTEGER,lastError:'School review required'}},lane,tenant);
 let summary;
 for(let n=0;n<30;n++){await new Promise(r=>setTimeout(r,100));summary=(await rpc('stats',{},'delivery',tenant)).value;if(summary.needsAttention===1)break;}
 assert.equal(summary.needsAttention,1);assert.equal(summary.pendingPartitions,1);
 assert.equal((await rpc('get',{id},lane,tenant)).value.state,'needsAttention');
});

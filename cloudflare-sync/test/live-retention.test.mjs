import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {createHash,randomUUID} from 'node:crypto';
import {writeFile,unlink} from 'node:fs/promises';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
const require=createRequire(import.meta.url),{createLiveSync}=require('../../functions/live-sync'),{createCloudflareSync}=require('../../functions/cloudflare-sync'),{storage}=require('../../functions/test/helpers/managed-storage');
const {protect}=require('../../functions/managed-schools'),{attendancePayloadFinishValues,attendanceReceiptOwns}=require('../../functions/attendance-payload-receipt');
const {createCloudflareDelivery}=require('../../functions/cloudflare-delivery');
const school='vs-'+'a'.repeat(32),key='isolated-live-retention-key-000001';

async function verificationClockWorker(t){
 const file=new URL('../dist/verification-clock-'+randomUUID()+'.mjs',import.meta.url);
 const wrapper=[
  'import runtime,{SyncLane as Parent} from "./worker.js";',
  'export class SyncLane extends Parent {',
  'async fetch(request){',
  'if(new URL(request.url).pathname==="/__verified_clock_test"){',
  'const b=await request.json();const sql=this.ctx.storage.sql;',
  'const expired=Date.now()-24*60*60*1000-1000;',
  'if(b.lane==="live")sql.exec("UPDATE live_backup SET verified_at=? WHERE operation_id=? AND state=\\x27verified\\x27",expired,b.identity);',
  'else sql.exec("UPDATE edge_ops SET verified_at=?,purge_due=? WHERE id=? AND state=\\x27completed\\x27",expired,Date.now()-500,b.identity);',
  'return new Response("ok");',
  '}return super.fetch(request);',
  '}',
  '}',
  'export default runtime;',
 ].join('\n');
 await writeFile(file,wrapper);
 t.after(()=>unlink(file).catch(()=>{}));
 return file.pathname;
}
async function backdateVerified(mf,lane,identity){
 const namespace=await mf.getDurableObjectNamespace('LANES');
 const stub=namespace.get(namespace.idFromName(school+'/'+lane));
 const reply=await stub.fetch('https://clock.invalid/__verified_clock_test',{method:'POST',body:JSON.stringify({lane:lane==='live'?'live':'records',identity})});
 assert.equal(reply.status,200);
}

test('verified 24h cache preserves replay until expiry',async t=>{
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[{name:'retention',modules:true,scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],outboundService:()=>new Response('{}',{status:503}),durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},bindings:{EDGE_KEY:key,LIVE_SYNC_TEST_SCHOOL_ID:school,BROKER_URL:'https://broker.invalid/school-cloud'}}]}));t.after(()=>mf.dispose());
 const edge=createCloudflareSync({url:'https://worker.invalid',key,schools:['*'],fetchImpl:(url,opt)=>mf.dispatchFetch(String(url),opt)}),live=createLiveSync({edge,schools:[school]}),gs=storage({lifecycle:true,bundle:true}),read=async b=>gs.call(b);
 const collection='school_expenses';await live.prepare(school,collection,read);
 const request={collection,id:'one',operation:'write',operationId:'retention-original-operation',expectedRevision:'',data:{schoolId:school,amount:1}};
 const first=await live.commit(school,request,read);
 assert.equal((await live.command(school,{command:'compact',before:1})).floor,0);
 assert.equal((await live.drain(school,read)).processed,1);
 assert.equal((await live.command(school,{command:'compact',before:1})).floor,0);
 assert.equal((await live.command(school,{command:'expireVerified'})).expired,0);
 const next=await live.command(school,{command:'retention'});assert.equal(next.retentionHours,24);assert.ok(next.nextCleanupAt>Date.now());
 const head=await live.command(school,{command:'head'});assert.equal(head.cursor,1);assert.equal(head.collections[0].cursor,1);
 assert.equal((await live.replay(school,{command:'changes',after:0},read)).events.length,1);
 const snapshot=await live.replay(school,{command:'snapshot',collection,at:1,after:''},read);assert.equal(snapshot.records[0].record.amount,1);
 const retry=await live.commit(school,request,read);assert.equal(retry.recordRevision,first.recordRevision);
 const second=await live.commit(school,{...request,id:'two',operationId:'retention-second-operation'},read);assert.equal(second.cursor,2);
 const changes=await live.replay(school,{command:'changes',after:1},read);assert.equal(changes.events[0].sequence,2);
 const proof=await live.command(school,{command:'operationReceipt',operationId:request.operationId});assert.equal(proof.found,true);assert.equal(proof.receipt.recordRevision,first.recordRevision);
 assert.equal((await live.command(school,{command:'compact',before:2})).floor,0);
 const noticeRequest={action:'managed_records',collection:'school_notices',id:'old-notice',operation:'write',syncProtocol:2,operationId:'legacy-notice-retention-0001',expectedRecordRevision:'',data:{schoolId:school,title:'permanent Drive notice'}};
 await edge.writeNotice(school,noticeRequest,()=>read({action:'managed_records',collection:'school_notices',operation:'read',syncProtocol:2}));
 await assert.rejects(edge.rpc(school,'notices',{command:'retireNoticeCache'}));
 assert.equal((await edge.drainNotices(school,read)).processed,1);
 await live.prepare(school,'school_notices',read);
 assert.equal((await edge.rpc(school,'notices',{command:'retireNoticeCache'})).retired,true);
 const oldId=createHash('sha256').update(JSON.stringify([school,noticeRequest.operationId])).digest('hex');
 assert.equal((await edge.rpc(school,'notices',{command:'get',id:oldId})).payload,'');
 await assert.rejects(edge.notices(school,()=>{throw Error('retired cache must not reinitialize');}));
 assert.equal((await live.read(school,'school_notices','old-notice',read)).record.title,'permanent Drive notice');
 const operationId=createHash('sha256').update('verified-attendance-retention').digest('hex'),attendance=edge.attendanceStore(school),requestBody={action:'mobile_mark_attendance',role:'student',personId:'Class_1_Roll_12',mode:'entry',sessionToken:'private-session-token',latitude:24,longitude:92};
 await attendance.create(operationId,{schoolId:school,operationId,day:'2026-11-02',mode:'entry',createdAt:Date.now(),payload:protect(JSON.stringify(requestBody),'a'.repeat(64))});
 assert.equal(await attendance.claim(operationId,'verified-attendance-claim',Date.now(),Date.now()+120000),true);
 const pending=await attendance.get(operationId),values=attendancePayloadFinishValues({schoolId:school,operationId,row:pending,request:requestBody,verifiedAck:{schoolId:school,operationId,success:true},values:{state:'completed',completedAt:Date.now(),nextAttemptAt:Number.MAX_SAFE_INTEGER}});
 await assert.rejects(attendance.finish(operationId,'verified-attendance-claim',{...values,attendanceOwnerReceipt:{...values.attendanceOwnerReceipt,payloadHash:'0'.repeat(64)}}));
 assert.equal((await attendance.get(operationId)).state,'processing');
 assert.equal(await attendance.finish(operationId,'verified-attendance-claim',values),true);
 const complete=await attendance.get(operationId);assert.equal(complete.payload,null);assert.equal(complete.state,'completed');
 assert.equal(attendanceReceiptOwns({schoolId:school,operationId,row:complete,permit:{role:'student',documentId:'Class_1_Roll_12'}}),true);
 assert.equal(attendanceReceiptOwns({schoolId:school,operationId,row:complete,permit:{role:'student',documentId:'Class_1_Roll_13'}}),false);
 assert(!JSON.stringify(complete).includes('private-session-token'));assert(!JSON.stringify(complete).includes('latitude'));
 let guarded=false;
 const guardedEdge={...edge,rpc:async(s,l,b)=>{
  if(b.command==='finish'&&b.values?.payloadPurged===true&&!guarded){
   const fake=JSON.parse(JSON.stringify(b));fake.values.result.recordRevision='live-fake-drive-proof';fake.values.result.recordSource.recordRevision='live-fake-drive-proof';
   await assert.rejects(edge.rpc(s,l,fake));guarded=true;
  }
  return edge.rpc(s,l,b);
 }};
 const delivery=createCloudflareDelivery({edge:guardedEdge,payloadGcEnabled:true}),fee={action:'managed_records',collection:'fee_settings',id:'verified-fee',operation:'write',syncProtocol:2,operationId:'verified-fee-cleanup-0001',expectedRecordRevision:'',data:{schoolId:school,amount:25}};
 const accepted=await delivery.record(school,fee,read);assert.equal(accepted.driveState,'pending');
 assert.equal((await delivery.drain(school,'records',read)).processed,1);assert.equal(guarded,true);
 const raw=await edge.rpc(school,'records',{command:'status',id:accepted.delivery.id});assert.equal(raw.response.payloadPurged,true);assert.equal(raw.response.result.record,null);
 assert.equal((await delivery.status(school,'records',accepted.delivery.id,read)).record.amount,25);
 const projected=await edge.rpc(school,'records',{command:'projection',id:accepted.delivery.id});assert.equal(projected.identity.id,'verified-fee');assert.equal(projected.request,undefined);
 await live.command(school,{command:'seedBegin',collection:'school_calendar',fingerprint:'0'.repeat(64),count:1,sourceRevision:'interrupted-source'});
 await live.command(school,{command:'seedPage',collection:'school_calendar',fingerprint:'0'.repeat(64),rows:[{id:'stale-seed',data:{schoolId:school,title:'stale provisional seed',_syncRevision:'old-provisional-revision'}}]});
 assert.equal(gs.call({action:'managed_records',collection:'school_calendar',operation:'write',id:'fresh',syncProtocol:2,operationId:'calendar-fresh-seed-operation',expectedRecordRevision:'',data:{schoolId:school,title:'verified fresh baseline'}}).success,true);
 await live.prepare(school,'school_calendar',read);
 assert.equal((await live.read(school,'school_calendar','stale-seed',read)).source,'missing');
 assert.equal((await live.read(school,'school_calendar','fresh',read)).record.title,'verified fresh baseline');
 await assert.rejects(live.command(school,{command:'seedBegin',collection:'school_calendar',fingerprint:'1'.repeat(64),count:0,sourceRevision:'unsafe-reset',replaceSeeding:true}));
});

test('24h expiry clears only Drive-verified live snapshot, never a newer pending edit',async t=>{
 const scriptPath=await verificationClockWorker(t);
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[{name:'retention-clock',modules:true,scriptPath,compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],outboundService:()=>new Response('{}',{status:503}),durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},bindings:{EDGE_KEY:key,LIVE_SYNC_TEST_SCHOOL_ID:school,BROKER_URL:'https://broker.invalid/school-cloud'}}]}));
 t.after(()=>mf.dispose());
 const edge=createCloudflareSync({url:'https://worker.invalid',key,schools:['*'],fetchImpl:(url,opt)=>mf.dispatchFetch(String(url),opt)});
 const live=createLiveSync({edge,schools:[school]});
 const gs=storage({lifecycle:true,bundle:true}),read=async body=>gs.call(body);
 await live.prepare(school,'school_expenses',read);
 const request={collection:'school_expenses',id:'clock-record',operation:'write',operationId:'24hour-clock-first-operation',expectedRevision:'',data:{schoolId:school,title:'First'}};
 const first=await live.commit(school,request,read);
 assert.equal((await live.drain(school,read)).processed,1);
 const newer=await live.commit(school,{...request,operationId:'24hour-clock-second-operation',expectedRevision:first.recordRevision,data:{schoolId:school,title:'Second'}},read);
 await backdateVerified(mf,'live',request.operationId);
 assert.equal((await live.command(school,{command:'expireVerified'})).expired,1);
 const pending=await live.command(school,{command:'read',collection:'school_expenses',id:request.id});
 assert.equal(pending.source,'cloudflare');
 assert.equal(pending.record.title,'Second');
 const replay=await live.command(school,{command:'operationReceipt',operationId:request.operationId});
 assert.equal(replay.receipt.record,null);
 assert.equal(replay.receipt.recordRevision,first.recordRevision);
 assert.equal((await live.command(school,{command:'stats'})).backups.some(b=>b.state==='pending'),true);
 assert.equal((await live.command(school,{command:'expireVerified'})).expired,0);
 assert.equal((await live.drain(school,read)).processed,1);
 await backdateVerified(mf,'live','24hour-clock-second-operation');
 assert.equal((await live.command(school,{command:'expireVerified'})).expired,1);
 const after=await live.command(school,{command:'read',collection:'school_expenses',id:request.id});
 assert.equal(after.source,'drive');
 assert.equal(after.record,null);
 assert.equal(after.recordRevision,newer.recordRevision);
 const restored=await live.read(school,'school_expenses',request.id,read);
 assert.equal(restored.record.title,'Second');
 assert.equal(restored.record._syncRevision,newer.recordRevision);
 assert.deepEqual((await live.command(school,{command:'stats'})).payloadCopies,{records:0,events:0,backups:0,operations:0});
});
test('24h expiry removes verified delivery payload but never pending school records',async t=>{
 const scriptPath=await verificationClockWorker(t);
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[{name:'spool-clock',modules:true,scriptPath,compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],outboundService:()=>new Response('{}',{status:503}),durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},bindings:{EDGE_KEY:key,BROKER_URL:'https://broker.invalid/school-cloud'}}]}));
 t.after(()=>mf.dispose());
 const edge=createCloudflareSync({url:'https://worker.invalid',key,schools:['*'],fetchImpl:(url,opt)=>mf.dispatchFetch(String(url),opt)});
 const delivery=createCloudflareDelivery({edge,payloadGcEnabled:true});
 const gs=storage({lifecycle:true,bundle:true}),read=async body=>gs.call(body);
 const a={action:'managed_records',collection:'school_expenses',id:'verified-clock',operation:'write',syncProtocol:2,operationId:'spool-24hour-verified-op',expectedRecordRevision:'',data:{schoolId:school,amount:18}};
 const b={...a,id:'pending-clock',operationId:'spool-24hour-pending-op'};
 const first=await delivery.record(school,a,read),second=await delivery.record(school,b,read);
 assert.equal(first.driveState,'pending');
 assert.equal(second.driveState,'pending');
 assert.equal((await delivery.drain(school,'records',read)).processed,1);
 await backdateVerified(mf,'records',first.delivery.id);
 assert.equal((await edge.rpc(school,'records',{command:'expireVerified'})).expired,1);
 assert.equal((await edge.rpc(school,'records',{command:'status',id:first.delivery.id})).payload,'');
 const waiting=await edge.rpc(school,'records',{command:'status',id:second.delivery.id});
 assert.equal(waiting.state,'pending');
 assert.ok(waiting.payload.length>0);
 assert.equal((await delivery.status(school,'records',first.delivery.id,read)).driveState,'verified');
});


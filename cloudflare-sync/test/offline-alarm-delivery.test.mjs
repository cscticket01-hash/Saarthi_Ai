import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {createHmac,randomUUID} from 'node:crypto';
import {readFile,writeFile,unlink} from 'node:fs/promises';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
const require=createRequire(import.meta.url);
const {createCloudflareSync}=require('../../functions/cloudflare-sync');
const {createCloudflareDelivery}=require('../../functions/cloudflare-delivery');
const {storage}=require('../../functions/test/helpers/managed-storage');

test('client-offline alarms retry a lost Google ACK with the immutable original operation',async t=>{
 const school='vs-'+'d'.repeat(32),key='offline-alarm-fixture-only-key-000001';
 const file=new URL('../dist/offline-alarm-'+randomUUID()+'.mjs',import.meta.url);
 const base=await readFile(new URL('../dist/worker.js',import.meta.url),'utf8');
 // Harness invokes the actual production alarm and advances its persisted due
 // timestamps, without a sleeping wall clock or a Windows/Android/Web caller.
 await writeFile(file,base+`\nexport class OfflineLane extends SyncLane {
 async alarm(){}
 async fetch(r){
  if(new URL(r.url).pathname==='/__alarm'){
   const identity=this.meta('identity');
   if(identity?.endsWith('/delivery')){this.setMeta('deliveryBackoff','0');this.ctx.storage.sql.exec('UPDATE lanes SET due=0');}
   else this.ctx.storage.sql.exec("UPDATE edge_ops SET due=0 WHERE state IN ('pending','retry')");
   await super.alarm();return new Response('ok');
  }
  return super.fetch(r);
 }
}`);
 t.after(()=>unlink(file).catch(()=>{}));
 let delivery,providerCalls=0,callbackCalls=0,firstRevision;
 const gs=storage({schoolId:school,lifecycle:true,bundle:true});
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[{name:'offline-alarm',modules:true,scriptPath:file.pathname,compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],durableObjects:{LANES:{className:'OfflineLane',useSQLite:true}},bindings:{EDGE_KEY:key,BROKER_URL:'https://broker.invalid/school-cloud'},outboundService:async request=>{
  const raw=await request.text(),stamp=request.headers.get('x-vidya-time');
  assert.equal(request.headers.get('authorization'),'Bearer cloudflare-delivery');
  assert.equal(request.headers.get('x-vidya-signature'),createHmac('sha256',key).update(stamp+'\n'+raw).digest('hex'));
  const body=JSON.parse(raw);assert.equal(body.schoolId,school);callbackCalls++;
  const result=await delivery.drain(school,body.lane,async original=>{
   assert.equal(original.operationId,'offline-financial-original-operation');providerCalls++;
   const ack=gs.call(original);firstRevision??=ack.recordRevision;
   assert.equal(ack.recordRevision,firstRevision,'Lost-response retry must retain the committed revision');
   if(providerCalls===1)throw Object.assign(Error('fixture response lost'),{status:504,code:'SCRIPT_TIMEOUT'});
   return ack;
  });
  return Response.json(result);
 }}]}));
 t.after(()=>mf.dispose());
 const edge=createCloudflareSync({url:'https://worker.invalid',key,schools:['*'],fetchImpl:(url,opt)=>mf.dispatchFetch(String(url),opt)});
 delivery=createCloudflareDelivery({edge});
 const accepted=await delivery.record(school,{action:'managed_records',collection:'school_expenses',id:'expense-one',operation:'write',syncProtocol:2,operationId:'offline-financial-original-operation',expectedRecordRevision:'',data:{schoolId:school,amount:25}});
 assert.equal(accepted.driveState,'pending');assert.equal(providerCalls,0);
 const ns=await mf.getDurableObjectNamespace('LANES');
 async function alarm(lane){const stub=ns.get(ns.idFromName(school+'/'+lane));assert.equal((await stub.fetch('https://fixture.invalid/__alarm')).status,200);}
 // No client write or status-poll drives delivery after durable acceptance.
 await alarm('records');await alarm('delivery');
 // The scheduler may have admitted this lane in a separate waitUntil task.
 // Assert eventual real owner progress, not synchronous callback timing.
 async function waitFor(check,message){
  for(let i=0;i<250;i++){
   if(await check())return;
   await new Promise(resolve=>setTimeout(resolve,20));
  }
  throw Error(message);
 }
 await waitFor(()=>providerCalls>=1,'No independent owner call after client exit');
 assert.equal(providerCalls,1);
 await waitFor(async()=>{const row=await edge.rpc(school,'records',
  {command:'status',id:accepted.delivery.id});
  return row?.state==='retry';},'Failed provider attempt was not safely retained');
 await alarm('records');await alarm('delivery');
 await waitFor(()=>providerCalls>=2,'Original Drive retry did not run');
 assert.equal(providerCalls,2);assert.equal(callbackCalls,2);
 const result=await delivery.status(school,'records',accepted.delivery.id);
 assert.equal(result.driveState,'verified');assert.equal(result.recordRevision,firstRevision);
 assert.equal(result.record.amount,25);
});


test('broker Retry-After persists across another lane wake without client polling',async t=>{
 const school='vs-'+'b'.repeat(32),key='broker-retry-fixture-only-key-0000001';
 const file=new URL('../dist/retry-alarm-'+randomUUID()+'.mjs',import.meta.url);
 const base=await readFile(new URL('../dist/worker.js',import.meta.url),'utf8');
 await writeFile(file,base+`\nexport class RetryLane extends SyncLane {
  async alarm(){}
  async fetch(r){
   if(new URL(r.url).pathname==='/__alarm'){
    await super.alarm();
    return Response.json({backoff:Number(this.meta('deliveryBackoff')||0),alarm:await this.ctx.storage.getAlarm()});
   }
   return super.fetch(r);
  }
 }`);
 t.after(()=>unlink(file).catch(()=>{}));
 let calls=0;
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[{name:'retry-alarm',modules:true,scriptPath:file.pathname,
  compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],
  durableObjects:{LANES:{className:'RetryLane',useSQLite:true}},
  bindings:{EDGE_KEY:key,BROKER_URL:'https://broker.invalid/school-cloud'},
  outboundService:async r=>{calls++;assert.equal(JSON.parse(await r.text()).schoolId,school);
   return new Response('temporary quota',{status:429,headers:{'Retry-After':'120'}});
  }}]}));
 t.after(()=>mf.dispose());
 const edge=createCloudflareSync({url:'https://worker.invalid',key,schools:['*'],fetchImpl:(url,opt)=>mf.dispatchFetch(String(url),opt)});
 const owner=createCloudflareDelivery({edge});
 const accepted=await owner.record(school,{action:'managed_records',collection:'school_expenses',id:'expense-retry',operation:'write',syncProtocol:2,operationId:'broker-throttle-original-operation',expectedRecordRevision:'',data:{schoolId:school,amount:25}});
 assert.equal(accepted.driveState,'pending');
 const ns=await mf.getDurableObjectNamespace('LANES');
 const delivery=ns.get(ns.idFromName(school+'/delivery'));
 const before=Date.now();
 await delivery.command(school,'delivery',{command:'schedule',sourceLane:'records'});
 const first=await (await delivery.fetch('https://fixture.invalid/__alarm')).json();
 assert.equal(calls,1);
 assert.ok(first.backoff>=before+120000,'provider minimum must be durably retained');
 assert.ok(first.alarm>=first.backoff);
 // A second source lane can wake the shared school scheduler. It must not
 // erase the broker throttle or send any new request before that minimum.
 await delivery.command(school,'delivery',{command:'schedule',sourceLane:'notices'});
 const second=await (await delivery.fetch('https://fixture.invalid/__alarm')).json();
 assert.equal(calls,1);
 assert.equal(second.backoff,first.backoff);
 assert.ok(second.alarm>=first.backoff);
});

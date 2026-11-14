import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHmac,createHash} from 'node:crypto';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
const key='synthetic-test-owner-internal-key-00000000001';
const school='vs-'+'a'.repeat(32);
const digest=x=>createHash('sha256').update(x).digest('hex');
async function harness(t,enabled=true,bucket=true){
 const worker={name:'r2-test',modules:true,
  scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,
  compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],
  outboundService:()=>new Response('{}',{status:503}),
  durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},
  bindings:{EDGE_KEY:key,BROKER_URL:'https://broker.invalid/school-cloud',
   ...(enabled?{R2_STAGING_ENABLED:'true'}:{})},
  ...(bucket?{r2Buckets:['R2_STAGE']}:{})};
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[worker]}));
 t.after(()=>mf.dispose());
 async function rpc(command,body={},lane='records'){
  const raw=JSON.stringify({schoolId:school,lane,command,...body}),at=String(Date.now());
  const response=await mf.dispatchFetch('https://worker.invalid/internal',{method:'POST',
   headers:{'content-type':'application/json','x-vidya-time':at,
    'x-vidya-signature':createHmac('sha256',key).update(at+'\n'+raw).digest('hex')},
   body:raw});
  return {http:response.status,...await response.json()};
 }
 return {mf,rpc};
}
function record(id='one',title='Accepted'){
 const request={action:'managed_records',operation:'write',syncProtocol:2,
  collection:'school_calendar',id,operationId:'r2-staged-record-operation-001',
  expectedRecordRevision:'',data:{schoolId:school,title}};
 const identity=[request.collection,request.id,request.operationId];
 return {request,id:digest(JSON.stringify([school,request.action,identity]))};
}
test('private R2 record bytes are durable before cloud ACK; exact replay does not double-count',async t=>{
 const {mf,rpc}=await harness(t),r=record();
 const first=await rpc('enqueue',r);
 assert.equal(first.http,200,JSON.stringify(first));
 assert.equal(first.value.state,'pending');
 const object=await (await mf.getR2Bucket('R2_STAGE')).get('saarthi-v1/'+school+'/records/'+r.id+'/0');
 assert.ok(object,'R2 original school object must exist before ACK');
 assert.deepEqual(JSON.parse(await object.text()),r.request);
 const namespaces=await mf.getDurableObjectNamespace('LANES');
 const quota=namespaces.get(namespaces.idFromName('saarthi-account-r2-staging-budget-v1'));
 const before=await quota.r2CapacityStatus();
 assert.equal(before.schoolBytes,Buffer.byteLength(JSON.stringify(r.request)));
 assert.equal(before.schoolLimitBytes,8_000_000_000);
 assert.equal(before.reservedSystemBytes,2_000_000_000);
 const again=await rpc('enqueue',r);
 assert.equal(again.http,200);
 const after=await quota.r2CapacityStatus();
 assert.equal(after.schoolBytes,before.schoolBytes);
 const collision=await rpc('enqueue',{id:r.id,request:{...r.request,data:{schoolId:school,title:'Different'}}});
 assert.equal(collision.http,409);
 assert.equal((await quota.r2CapacityStatus()).schoolBytes,before.schoolBytes);
 assert.equal(JSON.parse(await (await (await mf.getR2Bucket('R2_STAGE')).get('saarthi-v1/'+school+'/records/'+r.id+'/0')).text()).data.title,'Accepted');
});
test('verified original R2 file remains until 24h; no unverified object is eligible for deletion',async t=>{
 const {mf,rpc}=await harness(t);
 const bytes=Buffer.from('private verified file bytes for TEST school only');
 const uploadKey='synthetic-r2-file-original-001',id=digest(JSON.stringify([school,uploadKey]));
 const manifest={uploadKey,sha256:digest(bytes),sizeBytes:bytes.length,name:'synthetic.txt',mime:'text/plain'};
 const first=await rpc('putSmall',{id,manifest,base64:bytes.toString('base64')},'file-'+id);
 assert.equal(first.http,200,JSON.stringify(first));
 const bucket=await mf.getR2Bucket('R2_STAGE');
 const path='saarthi-v1/'+school+'/file-'+id+'/'+id+'/0';
 assert.equal((await bucket.head(path))?.size,bytes.length);
 const claim='original-owner-claim';
 assert.equal((await rpc('claim',{id,claim,expires:Date.now()+60000},'file-'+id)).value,true);
 const completed=await rpc('finish',{id,claim,values:{state:'completed',
  nextAttemptAt:Number.MAX_SAFE_INTEGER,
  result:{success:true,schoolId:school,uploadResumableVersion:1,uploadKey,
   sha256:manifest.sha256,sizeBytes:bytes.length,committed:true,offset:bytes.length,fileId:'verified-google-file'}}},'file-'+id);
 assert.equal(completed.http,200,JSON.stringify(completed));
 assert.equal(completed.value,true);
 assert.ok(await bucket.head(path),'must keep verified bytes for 24h');
 const ns=await mf.getDurableObjectNamespace('LANES'),
  quota=ns.get(ns.idFromName('saarthi-account-r2-staging-budget-v1'));
 assert.equal((await quota.r2CapacityStatus()).schoolBytes,bytes.length);
});
test('missing private bucket fails closed; no record is acknowledged as R2 staged',async t=>{
 const {rpc}=await harness(t,true,false),r=record('without-binding');
 const response=await rpc('enqueue',r);
 assert.equal(response.http,503);
 assert.equal(response.success,false);
 assert.equal(response.schoolId,undefined);
});

test('original school notice is staged before ACK, and only a matching Drive-finished job releases verification',async t=>{
 const {mf,rpc}=await harness(t);
 assert.equal((await rpc('seed',{records:{},revision:'legacy'},'notices')).http,200);
 const request={action:'managed_records',collection:'school_notices',operation:'write',
  syncProtocol:2,id:'notice-r2',operationId:'r2-notice-original-operation-001',
  expectedRecordRevision:'',data:{schoolId:school,title:'Private notice'}};
 const first=await rpc('write',{request},'notices');
 assert.equal(first.http,200,JSON.stringify(first));
 const id=digest(JSON.stringify([school,request.operationId]));
 const bucket=await mf.getR2Bucket('R2_STAGE'),
  key='saarthi-v1/'+school+'/notices/'+id+'/0';
 assert.deepEqual(JSON.parse(await (await bucket.get(key)).text()),request);
 const actorNamespace=await mf.getDurableObjectNamespace('LANES'),
  actor=actorNamespace.get(actorNamespace.idFromName('saarthi-account-r2-staging-budget-v1'));
 const before=(await actor.r2CapacityStatus()).schoolBytes;
 const replay=await rpc('write',{request},'notices');
 assert.equal(replay.http,200);
 assert.equal((await actor.r2CapacityStatus()).schoolBytes,before);
 const conflict=await rpc('write',{request:{...request,data:{schoolId:school,title:'Different'}}},'notices');
 assert.equal(conflict.http,409,'Same original operation ID cannot silently replace its R2 payload');
 assert.equal((await actor.r2CapacityStatus()).schoolBytes,before);
 const pending=await rpc('pending',{limit:2},'notices');
 assert.equal(pending.value.length,1);
 const claim='test-notice-verified-claim';
 assert.equal((await rpc('claim',{id,claim,expires:Date.now()+60000},'notices')).value,true);
 const end=await rpc('finish',{id,claim,values:{state:'completed',nextAttemptAt:Number.MAX_SAFE_INTEGER,
  completedAt:Date.now(),driveRevision:'gdrive-signed-original-revision'}},'notices');
 assert.equal(end.http,200,JSON.stringify(end));
 assert.ok(await bucket.head(key),'Verified original R2 bytes remain within 24h');
});
test('encrypted attendance is staged before its DO ACK, old completion with no owner proof stays unverified',async t=>{
 const {mf,rpc}=await harness(t);
 const id='a1'+'9'.repeat(62),lane='attendance-a1';
 const row={operationId:id,schoolId:school,createdAt:Date.now(),
  day:'2026-11-14',mode:'entry',payload:{encrypted:'opaque-example'},
  state:'pending',attempts:0};
 const first=await rpc('create',{id,row},lane);
 assert.equal(first.http,200,JSON.stringify(first));assert.equal(first.value,true);
 const key='saarthi-v1/'+school+'/'+lane+'/'+id+'/0';
 const bucket=await mf.getR2Bucket('R2_STAGE');
 assert.deepEqual(JSON.parse(await (await bucket.get(key)).text()),row);
 const again=await rpc('create',{id,row},lane);
 assert.equal(again.value,false,'Exact original attendance replay stays idempotent');
 const actorNamespace=await mf.getDurableObjectNamespace('LANES'),
  actor=actorNamespace.get(actorNamespace.idFromName('saarthi-account-r2-staging-budget-v1'));
 assert.equal((await actor.r2CapacityStatus()).schoolBytes,Buffer.byteLength(JSON.stringify(row)));
 const claim='attendance-claim';
 assert.equal((await rpc('claim',{id,claim,expires:Date.now()+60000},lane)).value,true);
 const finish=await rpc('finish',{id,claim,values:{state:'completed',nextAttemptAt:Number.MAX_SAFE_INTEGER}},lane);
 assert.equal(finish.http,200);
 assert.equal((await actor.r2CapacityStatus()).schoolBytes,Buffer.byteLength(JSON.stringify(row)),
  'No valid owner receipt means the R2 copy cannot be expired or released');
 assert.ok(await bucket.head(key));
});

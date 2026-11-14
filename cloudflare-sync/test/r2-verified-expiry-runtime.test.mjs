import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHmac,createHash,randomUUID} from 'node:crypto';
import {readFile,writeFile,unlink} from 'node:fs/promises';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
const secret='synthetic-only-verified-retention-secret-001';
const school='vs-'+'6'.repeat(32),hash=s=>createHash('sha256').update(s).digest('hex');
const day=24*60*60*1000;
test('R2 actor deletes ONLY real Drive-verified original after 24h; uncertain bytes survive',async t=>{
 const path=new URL('../dist/r2-verified-time-'+randomUUID()+'.mjs',import.meta.url);
 const base=await readFile(new URL('../dist/worker.js',import.meta.url),'utf8');
 const wrapper=`
export class R2VerifiedTimeLane extends SyncLane {
 async r2OriginalVerified(...args){
  const sql=this.ctx.storage.sql;
  if(sql.exec("SELECT value FROM metadata WHERE key='test_fail_verification'").toArray()[0]?.value==='1'){
   sql.exec("DELETE FROM metadata WHERE key='test_fail_verification'");
   throw Error('synthetic quota notification outage');
  }
  return super.r2OriginalVerified(...args);
 }
 async fetch(request) {
  if(new URL(request.url).pathname==='/__private_retention_clock') {
   const b=await request.json(),sql=this.ctx.storage.sql;
   if(b.mode==='fail_verification'){
    sql.exec("INSERT OR REPLACE INTO metadata VALUES('test_fail_verification','1')");
    return Response.json({configured:true});
   }
   if(b.mode==='pending_verification')return Response.json({pending:sql.exec('SELECT count(*) AS n FROM r2_verification_pending').toArray()[0].n});
   if(b.mode==='inspect') {
    const rows=sql.exec("SELECT key,state,accepted_at,accepted_final,verified_at,purge_due FROM r2_staged WHERE key=?",
      b.key).toArray();
    return Response.json({rows});
   }
   if(b.mode==='fail_put'){
    const bucket=this.env.R2_STAGE;
    this.env.R2_STAGE={head:bucket.head.bind(bucket),put:async()=>{throw Error('synthetic R2 outage');}};
    try{await super.stageR2Object(b.school,'records',b.id,0,new Uint8Array([1,2,3]).buffer);}
    catch{return Response.json({failed:true});}finally{this.env.R2_STAGE=bucket;}
    return Response.json({failed:false});
   }
   const before=Date.now()-24*60*60*1000-4000;
   if(b.mode==='age_verified'){
    sql.exec("UPDATE r2_staged SET accepted_at=?,verified_at=?,purge_due=? WHERE key=? AND state='verified'",
     before,before,Date.now()-1000,b.key);
   }
   if(b.mode==='age_uncertain'){
    sql.exec("UPDATE r2_staged SET accepted_at=?,purge_due=? WHERE key=? AND state='stored'",
     before,Date.now()-1000,b.key);
   }
   if(b.mode==='fail_delete'){
    const bucket=this.env.R2_STAGE;
    this.env.R2_STAGE={...bucket,delete:async()=>{throw Error('synthetic delete interruption');}};
    try{await super.alarm();}finally{this.env.R2_STAGE=bucket;}
   }
   if(b.mode==='sweep')await super.alarm();
   return Response.json({success:true});
  }
  return super.fetch(request);
 }
}`;
 await writeFile(path,base+'\n'+wrapper);
 t.after(()=>unlink(path).catch(()=>{}));
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[{
  name:'r2-retention',modules:true,scriptPath:path.pathname,
  compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],
  durableObjects:{LANES:{className:'R2VerifiedTimeLane',useSQLite:true}},
  r2Buckets:['R2_STAGE'],outboundService:()=>new Response('{}',{status:503}),
  bindings:{EDGE_KEY:secret,R2_STAGING_ENABLED:'true',BROKER_URL:'https://broker.invalid/school-cloud'}
 }]}));
 t.after(()=>mf.dispose());
 const rpc=async(command,body={},lane='records')=>{
  const raw=JSON.stringify({schoolId:school,lane,command,...body}),at=String(Date.now());
  const r=await mf.dispatchFetch('https://worker.invalid/internal',{method:'POST',
   headers:{'content-type':'application/json','x-vidya-time':at,
    'x-vidya-signature':createHmac('sha256',secret).update(at+'\n'+raw).digest('hex')},body:raw});
  return {status:r.status,...await r.json()};
 };
 const ns=await mf.getDurableObjectNamespace('LANES');
 const quota=ns.get(ns.idFromName('saarthi-account-r2-staging-budget-v1'));
 const request=async operationId=>{
  const req={action:'managed_records',operation:'write',syncProtocol:2,
   collection:'school_calendar',id:operationId,operationId,
   expectedRecordRevision:'',data:{schoolId:school,title:operationId}};
  const id=hash(JSON.stringify([school,req.action,[req.collection,req.id,req.operationId]]));
  const first=await rpc('enqueue',{id,request:req});
  assert.equal(first.status,200,JSON.stringify(first));
  return {id,key:'saarthi-v1/'+school+'/records/'+id+'/0',req};
 };
 const failedId='4'.repeat(64),failedKey='saarthi-v1/'+school+'/records/'+failedId+'/0';
 const failed=await quota.fetch('https://quota.test/__private_retention_clock',{method:'POST',
  body:JSON.stringify({mode:'fail_put',school,id:failedId})});
 assert.equal((await failed.json()).failed,true,'Provider put failure returns no staged success');
 assert.equal((await quota.r2CapacityStatus()).reservedBytes,3,'Failed put remains fully reserved');
 const retryStarted=Date.now();
 await quota.stageR2Object(school,'records',failedId,0,new Uint8Array([1,2,3]).buffer);
 assert.equal((await quota.r2CapacityStatus()).reservedBytes,0);
 assert.equal((await quota.r2CapacityStatus()).schoolBytes,3,'Exact retry counts reservation once');
 const inspectFailed=await quota.fetch('https://quota.test/__private_retention_clock',{method:'POST',
  body:JSON.stringify({mode:'inspect',key:failedKey})});
 const retryRow=(await inspectFailed.json()).rows[0];
 assert.ok(retryRow.accepted_at>=retryStarted,'Retention never starts at failed reservation');
 assert.equal(retryRow.accepted_final,0,'Staged bytes alone do not seal original owner acceptance');
 const verified=await request('original-r2-verified-00002'),
  uncertain=await request('original-r2-uncertain-00001');
 const bucket=await mf.getR2Bucket('R2_STAGE');
 assert.ok(await bucket.head(uncertain.key));
 assert.ok(await bucket.head(verified.key));
 const inspect=async(key,mode)=>{
  const response=await quota.fetch('https://quota.test/__private_retention_clock',{method:'POST',
   body:JSON.stringify({key,mode})});
  assert.equal(response.status,200,mode);
  return response.json();
 };
 // Verify the original record through the existing signed claim/finish owner.
 const claim='synthetic-google-claim';
 const claimed=await rpc('claim',{id:verified.id,claim,expires:Date.now()+60000});
 assert.equal(claimed.value,true);
 await inspect(verified.key,'fail_verification');
 const saved=await rpc('finish',{id:verified.id,claim,values:{
  state:'completed',nextAttemptAt:Number.MAX_SAFE_INTEGER,
  result:{success:true,schoolId:school,syncProtocol:2,
   recordRevision:'google-original-immutable-revision',
   record:{schoolId:school,id:verified.req.id,
    _syncOperationId:verified.req.operationId,_syncRevision:'google-original-immutable-revision'}}
 }});
 assert.equal(saved.status,200,JSON.stringify(saved));
 assert.equal(saved.value,true);
 assert.equal((await inspect(verified.key,'inspect')).rows[0].state,'stored',
  'Original Google completion must survive a failed quota notification');
 const originalOwner=ns.get(ns.idFromName(school+'/records'));
 const pending=await originalOwner.fetch('https://owner.test/__private_retention_clock',{method:'POST',body:JSON.stringify({mode:'pending_verification'})});
 assert.equal((await pending.json()).pending,1,'Failed notification is durably queued');
 await originalOwner.fetch('https://owner.test/__private_retention_clock',{method:'POST',body:JSON.stringify({mode:'sweep'})});
 assert.equal((await inspect(verified.key,'inspect')).rows[0].state,'verified',
  'Owner alarm independently retries original proof notification');
 assert.equal((await inspect(uncertain.key,'inspect')).rows[0].state,'stored');
 // An unverified original must NOT be deleted even with a forged old age.
 await inspect(uncertain.key,'age_uncertain');
 await inspect(verified.key,'age_verified');
 const beforeCleanup=(await quota.r2CapacityStatus()).schoolBytes;
 await inspect(verified.key,'fail_delete');
 assert.ok(await bucket.head(verified.key),'Failed deletion keeps original bytes');
 assert.equal((await quota.r2CapacityStatus()).schoolBytes,beforeCleanup,'Failed cleanup never releases quota');
 await inspect(uncertain.key,'sweep');
 assert.ok(await bucket.head(uncertain.key),'Unknown Google delivery never permits R2 deletion');
 assert.equal(await bucket.head(verified.key),null,'Only matching signed Drive-verified bytes expire');
 const rows=await inspect(verified.key,'inspect');
 assert.equal(rows.rows.length,1,'Immutable replay tombstone is retained');
 assert.equal(rows.rows[0].state,'purged');
 const beforeReplay=(await quota.r2CapacityStatus()).schoolBytes;
 const replay=await rpc('enqueue',{id:verified.id,request:verified.req});
 assert.equal(replay.status,200);
 assert.equal(await bucket.head(verified.key),null,'Original replay cannot resurrect expired R2 bytes');
 assert.equal((await quota.r2CapacityStatus()).schoolBytes,beforeReplay);
 assert.ok((await quota.r2CapacityStatus()).schoolBytes>0,'Pending school bytes remain in quota');
 // Multipart originals acquire one owner-acceptance time only after sealing.
 const file=Buffer.alloc(512*1024+17,7),uploadKey='r2-partial-retention-original-001';
 const fileId=hash(JSON.stringify([school,uploadKey])),lane='file-'+fileId;
 const manifest={uploadKey,name:'synthetic-partial.bin',mime:'application/octet-stream',sizeBytes:file.length,sha256:hash(file)};
 assert.equal((await rpc('begin',{id:fileId,manifest},lane)).status,200);
 const send=async(offset,bytes)=>rpc('part',{id:fileId,offset,base64:bytes.toString('base64'),chunkSha256:hash(bytes)},lane);
 assert.equal((await send(0,file.subarray(0,512*1024))).status,200);
 const firstKey='saarthi-v1/'+school+'/'+lane+'/'+fileId+'/0';
 assert.equal((await inspect(firstKey,'inspect')).rows[0].accepted_final,0,
  'Incomplete upload has no final acceptance and cannot expire');
 const sealedAt=Date.now();
 assert.equal((await send(512*1024,file.subarray(512*1024))).status,200);
 const sealed=(await inspect(firstKey,'inspect')).rows[0];
 assert.equal(sealed.accepted_final,1);
 assert.ok(sealed.accepted_at>=sealedAt,'Earlier chunks retain at least 24h from final original acceptance');

});

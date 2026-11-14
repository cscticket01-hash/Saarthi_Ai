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
 async fetch(request) {
  if(new URL(request.url).pathname==='/__private_retention_clock') {
   const b=await request.json(),sql=this.ctx.storage.sql;
   if(b.mode==='inspect') {
    const rows=sql.exec("SELECT key,state,accepted_at,verified_at,purge_due FROM r2_staged WHERE key=?",
      b.key).toArray();
    return Response.json({rows});
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
 const saved=await rpc('finish',{id:verified.id,claim,values:{
  state:'completed',nextAttemptAt:Number.MAX_SAFE_INTEGER,
  result:{success:true,schoolId:school,syncProtocol:2,
   recordRevision:'google-original-immutable-revision',
   record:{schoolId:school,id:verified.req.id,
    _syncOperationId:verified.req.operationId,_syncRevision:'google-original-immutable-revision'}}
 }});
 assert.equal(saved.status,200,JSON.stringify(saved));
 assert.equal(saved.value,true);
 assert.equal((await inspect(verified.key,'inspect')).rows[0].state,'verified');
 assert.equal((await inspect(uncertain.key,'inspect')).rows[0].state,'stored');
 // An unverified original must NOT be deleted even with a forged old age.
 await inspect(uncertain.key,'age_uncertain');
 await inspect(verified.key,'age_verified');
 await inspect(uncertain.key,'sweep');
 assert.ok(await bucket.head(uncertain.key),'Unknown Google delivery never permits R2 deletion');
 assert.equal(await bucket.head(verified.key),null,'Only matching signed Drive-verified bytes expire');
 const rows=await inspect(verified.key,'inspect');
 assert.equal(rows.rows.length,0,'Quota can be reclaimed only after R2 confirmed deletion');
 assert.ok((await quota.r2CapacityStatus()).schoolBytes>0,'Pending school bytes remain in quota');
});

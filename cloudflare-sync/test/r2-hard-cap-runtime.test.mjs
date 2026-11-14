import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID,createHash,createHmac} from 'node:crypto';
import {readFile,writeFile,unlink} from 'node:fs/promises';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
const key='private-test-r2-hard-fence-owner-key-00000001',school='vs-'+'c'.repeat(32),other='vs-'+'d'.repeat(32);
const digest=x=>createHash('sha256').update(x).digest('hex');
test('global DO quota hard-rejects new school R2 uploads at 8 decimal GB across different school owners',async t=>{
 const path=new URL('../dist/r2-hard-fence-'+randomUUID()+'.mjs',import.meta.url);
 const base=await readFile(new URL('../dist/worker.js',import.meta.url),'utf8');
 const wrapper=`
export class R2HardFenceTestLane extends SyncLane {
 async fetch(request) {
  if(new URL(request.url).pathname==='/__test_private_full_budget'){
   const b=await request.json();
   if(!Number.isSafeInteger(b.bytes)||b.bytes<=0||b.bytes>8000000000)return new Response('invalid',{status:400});
   const sql=this.ctx.storage.sql;
   sql.exec("INSERT INTO r2_staged(key,school,lane,receipt_id,bytes,sha256,category,state,accepted_at) VALUES(?,?,?,?,?,?,?,'reserved',?)",
    'test-only-foreign-reservation', 'vs-dddddddddddddddddddddddddddddddd','records',
    'b'.repeat(64),b.bytes,'a'.repeat(64),'school',Date.now());
   return Response.json({reserved:true});
  }
  return super.fetch(request);
 }
}`;
 await writeFile(path,base+'\n'+wrapper);
 t.after(()=>unlink(path).catch(()=>{}));
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[{name:'r2-budget',
  modules:true,scriptPath:path.pathname,compatibilityDate:'2026-10-28',
  compatibilityFlags:['nodejs_compat'],
  durableObjects:{LANES:{className:'R2HardFenceTestLane',useSQLite:true}},
  r2Buckets:['R2_STAGE'],
  bindings:{EDGE_KEY:key,R2_STAGING_ENABLED:'true',BROKER_URL:'https://broker.invalid/school-cloud'},
  outboundService:()=>new Response('{}',{status:503})
 }]}));
 t.after(()=>mf.dispose());
 const rpc=async(s,id,title)=>{
  const request={action:'managed_records',collection:'school_calendar',operation:'write',
   syncProtocol:2,id,operationId:'r2-hard-fence-operation-'+id+'-000001',
   expectedRecordRevision:'',data:{schoolId:s,title}};
  const identity=[request.collection,request.id,request.operationId],
   receipt=digest(JSON.stringify([s,request.action,identity]));
  const raw=JSON.stringify({schoolId:s,lane:'records',command:'enqueue',id:receipt,request}),now=String(Date.now());
  const response=await mf.dispatchFetch('https://worker.invalid/internal',{method:'POST',
   headers:{'content-type':'application/json','x-vidya-time':now,
    'x-vidya-signature':createHmac('sha256',key).update(now+'\n'+raw).digest('hex')},body:raw});
  return {receipt,response:await response.json(),status:response.status};
 };
 const first=await rpc(school,'first','Private record'),namespace=await mf.getDurableObjectNamespace('LANES');
 assert.equal(first.status,200,JSON.stringify(first.response));
 const actor=namespace.get(namespace.idFromName('saarthi-account-r2-staging-budget-v1'));
 const used=(await actor.r2CapacityStatus()).schoolBytes;
 assert.ok(used>0&&used<8000000000);
 const injected=await actor.fetch('https://quota.test/__test_private_full_budget',{method:'POST',
  body:JSON.stringify({bytes:8000000000-used})});
 assert.equal(injected.status,200);
 assert.equal((await actor.r2CapacityStatus()).schoolBytes,8000000000);
 const blocked=await rpc(other,'second','This must stay on device');
 assert.equal(blocked.status,507,JSON.stringify(blocked.response));
 assert.equal(blocked.response.success,false);
 assert.equal(blocked.response.code,'R2_CAPACITY_EXCEEDED');
 assert.equal((await actor.r2CapacityStatus()).schoolBytes,8000000000);
 assert.equal(await (await mf.getR2Bucket('R2_STAGE')).head('saarthi-v1/'+other+'/records/'+blocked.receipt+'/0'),null);
});

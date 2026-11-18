import {test} from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {readFile,writeFile,unlink} from 'node:fs/promises';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
const school='vs-'+'a'.repeat(32);
test('new R2 admissions bypass HEAD; crashed reservations use HEAD before recovery',async t=>{
 const path=new URL('../dist/r2-first-write-'+randomUUID()+'.mjs',import.meta.url);
 const base=await readFile(new URL('../dist/worker.js',import.meta.url),'utf8');
 // Private test-only hook; never included in the deployed Worker.
 const wrapper=[
 'export class R2FirstWriteTestLane extends SyncLane {',
 ' async fetch(request) {',
 '  if(new URL(request.url).pathname!=="/__test_first_write") return super.fetch(request);',
 '  const b=await request.json(),bucket=this.env.R2_STAGE;',
 '  let head=0,put=0;',
 '  this.env.R2_STAGE={',
 '   head:async (...args)=>{head++;return bucket.head(...args);},',
 '   put:async (...args)=>{put++;if(b.failPut)throw Error("Injected R2 outage");return bucket.put(...args);}',
 '  };',
 '  try {',
 '   const result=await super.stageR2Object(b.school,"records",b.id,0,new Uint8Array(b.bytes).buffer);',
 '   return Response.json({ok:true,result,head,put});',
 '  } catch {return Response.json({ok:false,head,put});}',
 '  finally {this.env.R2_STAGE=bucket;}',
 ' }',
 '}'
 ].join('\n');
 await writeFile(path,base+'\n'+wrapper);
 t.after(()=>unlink(path).catch(()=>{}));
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[{
  name:'r2-first-write',modules:true,scriptPath:path.pathname,
  compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],
  durableObjects:{LANES:{className:'R2FirstWriteTestLane',useSQLite:true}},
  r2Buckets:['R2_STAGE'],
  bindings:{R2_STAGING_ENABLED:'true',R2_STAGING_SCHOOLS:school},
  outboundService:()=>new Response('{}',{status:503})
 }]}));
 t.after(()=>mf.dispose());
 const namespace=await mf.getDurableObjectNamespace('LANES');
 const actor=namespace.get(namespace.idFromName('saarthi-account-r2-staging-budget-v1'));
 const stage=async (id,bytes,failPut=false)=>{
  const response=await actor.fetch('https://private.test/__test_first_write',{
   method:'POST',headers:{'content-type':'application/json'},
   body:JSON.stringify({school,id,bytes,failPut})
  });
  assert.equal(response.status,200);
  return response.json();
 };
 const firstId='a'.repeat(64), firstBytes=[1,2,3,4,5];
 const first=await stage(firstId,firstBytes);
 assert.equal(first.ok,true);
 assert.equal(first.head,0,'Fresh quota reservation needs no R2 HEAD');
 assert.equal(first.put,1,'Original bytes must reach R2 before ACK');
 const original=await (await mf.getR2Bucket('R2_STAGE'))
  .get('saarthi-v1/'+school+'/records/'+firstId+'/0');
 assert.deepEqual(new Uint8Array(await original.arrayBuffer()),new Uint8Array(firstBytes));
 const again=await stage(firstId,firstBytes);
 assert.equal(again.ok,true);
 assert.equal(again.put,0);
 assert.equal(again.head,0);
 assert.equal((await actor.r2CapacityStatus()).schoolBytes,firstBytes.length);
 const failedId='b'.repeat(64),failedBytes=[7,8,9];
 const failed=await stage(failedId,failedBytes,true);
 assert.equal(failed.ok,false);
 assert.equal(failed.head,0);
 assert.equal(failed.put,1);
 assert.equal((await actor.r2CapacityStatus()).schoolBytes,
  firstBytes.length+failedBytes.length,'Failed R2 put remains quota-accounted');
 const recovered=await stage(failedId,failedBytes);
 assert.equal(recovered.ok,true);
 assert.equal(recovered.head,1,'Interrupted reservation checks R2 before recovery');
 assert.equal(recovered.put,1);
 assert.equal((await actor.r2CapacityStatus()).schoolBytes,
  firstBytes.length+failedBytes.length,'Recovered original cannot double-count quota');
});

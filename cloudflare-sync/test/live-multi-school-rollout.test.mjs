import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {createHash,createHmac} from 'node:crypto';
import {createRequire} from 'node:module';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
const {liveGrant}=createRequire(import.meta.url)('../../functions/live-sync');
const A='vs-'+'a'.repeat(32),B='vs-'+'b'.repeat(32),C='vs-'+'c'.repeat(32),key='multi-school-rollout-isolated-secret-00001';
const mf=new Miniflare(convertV4MiniflareOptions({workers:[{name:'multi-school-rollout',modules:true,scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],outboundService:()=>new Response('{}',{status:503}),durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},bindings:{EDGE_KEY:key,LIVE_SYNC_SCHOOLS:` ${A}, ${B} `,BROKER_URL:'https://broker.invalid/school-cloud'}}]}));
after(()=>mf.dispose());
async function rpc(school,body,signed=true,runtime=mf){
 const raw=JSON.stringify({...body,schoolId:school,lane:'live'}),time=String(Date.now());
 const response=await runtime.dispatchFetch('https://worker.invalid/internal',{method:'POST',headers:{'content-type':'application/json',...(signed?{'x-vidya-time':time,'x-vidya-signature':createHmac('sha256',key).update(time+'\n'+raw).digest('hex')}:{})},body:raw});
 return {status:response.status,...await response.json()};
}
test('two real SQLite school lanes require independent baselines and never share records',async()=>{
 assert.equal((await rpc(A,{command:'head'},false)).status,401);
 assert.equal((await rpc(C,{command:'head'})).status,412);
 const fingerprint=createHash('sha256').update('{}').digest('hex');
 for(const school of [A,B]){
  assert.equal((await rpc(school,{command:'seedBegin',collection:'school_expenses',fingerprint,count:0,sourceRevision:'verified-drive-'+school})).status,200);
  assert.equal((await rpc(school,{command:'seedSeal',collection:'school_expenses',fingerprint})).status,200);
  const result=await rpc(school,{command:'commit',collection:'school_expenses',id:'same-id',operation:'write',operationId:'same-operation-identity-0001',expectedRevision:'',data:{schoolId:school,amount:school===A?1:2}});
  assert.equal(result.status,200);assert.equal(result.value.backupState,'pending');
 }
 for(const [school,amount] of [[A,1],[B,2]]){
  const result=await rpc(school,{command:'read',collection:'school_expenses',id:'same-id'});
  assert.equal(result.value.record.schoolId,school);assert.equal(result.value.record.amount,amount);
 }
 assert.equal((await rpc(A,{command:'commit',collection:'school_expenses',id:'foreign',operation:'write',operationId:'foreign-operation-identity-0001',expectedRevision:'',data:{schoolId:B,amount:999}})).status,403);
});
test('400-school configuration fits four provider-sized bindings and admits the last school without wildcard access',async t=>{
 const ids=Array.from({length:400},(_,i)=>'vs-'+i.toString(16).padStart(32,'0'));
 const parts=Object.fromEntries([0,1,2,3].map(i=>['LIVE_SYNC_SCHOOLS'+(i?'_'+(i+1):''),ids.slice(i*100,i*100+100).join(',')]));
 assert.ok(Object.values(parts).every(value=>Buffer.byteLength(value)<5120));
 const full=new Miniflare(convertV4MiniflareOptions({workers:[{name:'full-school-cohort',modules:true,scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],outboundService:()=>new Response('{}',{status:503}),durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},bindings:{EDGE_KEY:key,BROKER_URL:'https://broker.invalid/school-cloud',...parts}}]}));
 t.after(()=>full.dispose());
 for(const school of [ids[0],ids[399]])assert.equal((await rpc(school,{command:'head'},true,full)).status,200);
 assert.equal((await rpc(C,{command:'head'},true,full)).status,412);
});
test('the second school can open its own signed socket while an unlisted school cannot',async()=>{
 for(const school of [B,C]){
  const grant=liveGrant({schoolId:school,uid:'school-admin',key,endpoint:'https://worker.invalid'});
  const response=await mf.dispatchFetch(grant.endpoint.replace('wss:','https:'),{headers:{Upgrade:'websocket','Sec-WebSocket-Protocol':grant.protocols.join(', ')}});
  assert.equal(response.status,school===B?101:412);
  if(response.webSocket){response.webSocket.accept();response.webSocket.close();}
 }
});

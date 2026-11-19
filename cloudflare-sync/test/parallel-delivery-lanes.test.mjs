import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHmac} from 'node:crypto';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';

const school='vs-'+'c'.repeat(32);
const key='synthetic-lane-parallelism-hmac-key-test-20261119';
test('a stalled person/record Drive call does not block notification lane',async t=>{
 let releaseRecord;
 const blockedRecord=new Promise(resolve=>{releaseRecord=resolve;});
 let bothStarted;
 const both=new Promise(resolve=>{bothStarted=resolve;});
 const seen=new Set();
 const worker={
  name:'sync-lane-parallel-test',modules:true,
  scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,
  compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],
  durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},
  bindings:{EDGE_KEY:key,BROKER_URL:'https://broker.invalid/school-cloud'},
  outboundService:async request=>{
   let body;
   try{body=await request.json();}catch{return new Response('{}',{status:503});}
   if(body.action!=='managed/cloudflare/drain')
    return new Response('{}',{status:503});
   seen.add(body.lane);
   if(seen.has('records')&&seen.has('notices'))bothStarted();
   if(body.lane==='records')await blockedRecord;
   return Response.json({success:true,schoolId:school,processed:0});
  }
 };
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[worker]}));
 t.after(async()=>{releaseRecord();await mf.dispose();});
 async function rpc(command,extras={},lane='delivery'){
  const raw=JSON.stringify({schoolId:school,lane,command,...extras});
  const time=String(Date.now());
  const response=await mf.dispatchFetch('https://worker.invalid/internal',{
   method:'POST',headers:{'content-type':'application/json',
    'x-vidya-time':time,
    'x-vidya-signature':createHmac('sha256',key)
      .update(time+'\n'+raw).digest('hex')},body:raw});
  return {http:response.status,...await response.json()};
 }
 try{
  const schedules=await Promise.all([
   rpc('schedule',{sourceLane:'records'}),
   rpc('schedule',{sourceLane:'notices'})
  ]);
  assert.ok(schedules.every(x=>x.http===200),JSON.stringify(schedules));
  let timeout;
  await Promise.race([
   both,
   new Promise((_,reject)=>{timeout=setTimeout(
    ()=>reject(Error('Notification was blocked behind record Drive request')),6000);})
  ]).finally(()=>clearTimeout(timeout));
  assert.ok(seen.has('records'));
  assert.ok(seen.has('notices'),
   'two independent per-school backup lanes launch before slow Drive release');
 }finally{releaseRecord();}
});

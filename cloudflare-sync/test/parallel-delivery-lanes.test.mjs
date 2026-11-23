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

test('new notice admitted DURING an already slow record Drive drain starts without waiting for that record',async t=>{
 let releaseRecord;const blockedRecord=new Promise(resolve=>{releaseRecord=resolve;});
 let startedRecord;const recordStarted=new Promise(resolve=>{startedRecord=resolve;});
 let startedNotice;const noticeStarted=new Promise(resolve=>{startedNotice=resolve;});
 const seen=[];
 const worker={name:'sync-late-notice-test',modules:true,
  scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,
  compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],
  durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},
  bindings:{EDGE_KEY:key,BROKER_URL:'https://broker.invalid/school-cloud'},
  outboundService:async request=>{
   let body;try{body=await request.json();}catch{return new Response('{}',{status:503});}
   if(body.action!=='managed/cloudflare/drain')return new Response('{}',{status:503});
   seen.push(body.lane);
   if(body.lane==='records'){startedRecord();await blockedRecord;}
   if(body.lane==='notices')startedNotice();
   return Response.json({success:true,schoolId:school,processed:0});
  }};
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[worker]}));
 t.after(async()=>{releaseRecord();await mf.dispose();});
 async function rpc(command,extras={}){
  const raw=JSON.stringify({schoolId:school,lane:'delivery',command,...extras});
  const time=String(Date.now()),r=await mf.dispatchFetch('https://worker.invalid/internal',{
    method:'POST',headers:{'content-type':'application/json',
     'x-vidya-time':time,'x-vidya-signature':createHmac('sha256',key)
       .update(time+'\n'+raw).digest('hex')},body:raw});
  return {http:r.status,...await r.json()};
 }
 let timeout;
 try{
  assert.equal((await rpc('schedule',{sourceLane:'records'})).http,200);
  await Promise.race([recordStarted,new Promise((_,reject)=>{timeout=setTimeout(
    ()=>reject(Error('Record drain never began')),4000);})]).finally(()=>clearTimeout(timeout));
  assert.equal((await rpc('schedule',{sourceLane:'notices'})).http,200);
  await Promise.race([noticeStarted,new Promise((_,reject)=>{timeout=setTimeout(
    ()=>reject(Error('New notice waited behind an already in-flight Drive record')),4000);})]).finally(()=>clearTimeout(timeout));
  assert.deepEqual(seen.slice(0,2),['records','notices']);
 }finally{releaseRecord();clearTimeout(timeout);}
});

test('a newer same-lane Save survives the first in-flight broker drain without duplicate admission',async t=>{
 let releaseFirst;
 const firstBlocked=new Promise(resolve=>{releaseFirst=resolve;});
 let firstStarted,secondStarted;
 const first=new Promise(resolve=>{firstStarted=resolve;});
 const second=new Promise(resolve=>{secondStarted=resolve;});
 let calls=0;
 const worker={name:'sync-same-lane-epoch-test',modules:true,
  scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,
  compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],
  durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},
  bindings:{EDGE_KEY:key,BROKER_URL:'https://broker.invalid/school-cloud'},
  outboundService:async request=>{
   let body;try{body=await request.json();}catch{return new Response('{}',{status:503});}
   if(body.action!=='managed/cloudflare/drain')return new Response('{}',{status:503});
   assert.equal(body.lane,'records');
   calls++;
   if(calls===1){firstStarted();await firstBlocked;}
   if(calls===2)secondStarted();
   return Response.json({success:true,schoolId:school,processed:0});
  }};
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[worker]}));
 t.after(async()=>{releaseFirst();await mf.dispose();});
 async function schedule(){
  const raw=JSON.stringify({schoolId:school,lane:'delivery',
   command:'schedule',sourceLane:'records'});
  const time=String(Date.now());
  const response=await mf.dispatchFetch('https://worker.invalid/internal',{
   method:'POST',headers:{'content-type':'application/json',
    'x-vidya-time':time,'x-vidya-signature':createHmac('sha256',key)
     .update(time+'\n'+raw).digest('hex')},body:raw});
  return response.status;
 }
 async function within(promise,message){
  let timer;try{return await Promise.race([
   promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error(message)),5000);})
  ]);}finally{clearTimeout(timer);}
 }
 try{
  assert.equal(await schedule(),200);
  await within(first,'First record Drive drain never started');
  assert.equal(await schedule(),200,
   'The newer Save must be durably scheduled during the first in-flight drain');
  assert.equal(calls,1,'Do not dispatch the same lane a second time under its existing lease');
  releaseFirst();
  await within(second,'The newer same-lane Save was lost after an older lease completed');
  assert.equal(calls,2,'Only the original and newer epochs should be drained');
 }finally{releaseFirst();}
});

test('school delivery never starts a fourth provider lane until an active lease settles',async t=>{
 const lanes=['records','notices','attendance-00','attendance-01'];
 const releases=new Map(),blockers=new Map(),started=new Map(),signals=new Map();
 for(const lane of lanes){
  blockers.set(lane,new Promise(resolve=>releases.set(lane,resolve)));
  signals.set(lane,new Promise(resolve=>started.set(lane,resolve)));
 }
 let active=0,maxActive=0;
 const worker={name:'sync-three-lane-bound-test',modules:true,
  scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,
  compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],
  durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},
  bindings:{EDGE_KEY:key,BROKER_URL:'https://broker.invalid/school-cloud'},
  outboundService:async request=>{
   let body;try{body=await request.json();}catch{return new Response('{}',{status:503});}
   if(body.action!=='managed/cloudflare/drain')return new Response('{}',{status:503});
   assert.ok(blockers.has(body.lane),'Unexpected school delivery lane');
   active++;maxActive=Math.max(maxActive,active);
   started.get(body.lane)();
   try{await blockers.get(body.lane);}
   finally{active--;}
   return Response.json({success:true,schoolId:school,processed:0});
  }};
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[worker]}));
 t.after(async()=>{
  for(const release of releases.values())release();
  await mf.dispose();
 });
 async function schedule(sourceLane){
  const raw=JSON.stringify({schoolId:school,lane:'delivery',command:'schedule',sourceLane});
  const time=String(Date.now());
  const response=await mf.dispatchFetch('https://worker.invalid/internal',{
   method:'POST',headers:{'content-type':'application/json',
    'x-vidya-time':time,'x-vidya-signature':createHmac('sha256',key)
     .update(time+'\n'+raw).digest('hex')},body:raw});
  assert.equal(response.status,200,sourceLane+' schedule was rejected');
 }
 async function within(promise,message){
  let timer;try{return await Promise.race([
   promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(Error(message)),5000);})
  ]);}finally{clearTimeout(timer);}
 }
 try{
  for(const lane of lanes.slice(0,3)){
   await schedule(lane);
   await within(signals.get(lane),lane+' never entered delivery');
  }
  assert.equal(active,3);
  await schedule(lanes[3]);
  // A short negative window catches an accidental fourth in-flight admission.
  const fourthBeforeRelease=await Promise.race([
   signals.get(lanes[3]).then(()=>true),
   new Promise(resolve=>setTimeout(()=>resolve(false),150)),
  ]);
  assert.equal(fourthBeforeRelease,false,'The fourth Google request bypassed the three-lane ceiling');
  assert.equal(maxActive,3);
  releases.get(lanes[0])();
  await within(signals.get(lanes[3]),'The fourth lane was never resumed after capacity cleared');
  assert.equal(maxActive,3,'No more than three Google broker calls may overlap');
 }finally{
  for(const release of releases.values())release();
 }
});

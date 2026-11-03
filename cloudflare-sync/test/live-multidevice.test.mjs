import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
const require=createRequire(import.meta.url);
const {createLiveSync}=require('../../functions/live-sync');
const {createCloudflareSync}=require('../../functions/cloudflare-sync');
const school='vs-'+'a'.repeat(32),key='isolated-multidevice-test-secret-00000001';

async function setup(t,count){
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[{
  name:'live-multidevice-'+count,modules:true,scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,
  compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],
  outboundService:()=>new Response('{}',{status:503}),
  durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},
  bindings:{EDGE_KEY:key,LIVE_SYNC_TEST_SCHOOL_ID:school,BROKER_URL:'https://broker.invalid/school-cloud'},
 }]}));
 t.after(()=>mf.dispose());
 const edge=createCloudflareSync({url:'https://worker.invalid',key,schools:[school],
  fetchImpl:(url,opt)=>mf.dispatchFetch(String(url),opt)});
 let baselineReads=0;
 const baseline=async body=>{
  baselineReads++;
  assert.equal(body.action,'managed_records');assert.equal(body.operation,'read');
  assert.equal(body.collection,'school_expenses');
  return {success:true,schoolId:school,syncProtocol:2,collectionRevision:'verified-empty-drive-head',
   records:{},...(body.knownRevision==='verified-empty-drive-head'?{unchanged:true}:{})};
 };
 const owner=createLiveSync({edge,schools:[school]});
 await owner.prepare(school,'school_expenses',baseline);
 assert.equal(baselineReads,2,'one verified baseline and its unchanged-head confirmation');
 const noDrive=async()=>{throw Error('Pending Cloudflare records must be visible without waiting for Drive');};
 const clients=Array.from({length:count},(_,index)=>({
  live:createLiveSync({edge,schools:[school]}),device:createHash('sha256').update('test-pc-'+index).digest('hex'),
  cursor:0,records:new Map(),snapshotPages:0,
 }));
 async function bootstrap(client){
  const head=await client.live.command(school,{command:'head'});
  let after='';
  do{
   const page=await client.live.replay(school,{command:'snapshot',collection:'school_expenses',at:head.cursor,after},noDrive);
   client.snapshotPages++;
   for(const item of page.records)client.records.set(item.id,item.record);
   after=page.next;
  }while(after!==null);
  client.cursor=head.cursor;
 }
 async function receive(client){
  let more;
  do{
   const page=await client.live.replay(school,{command:'changes',after:client.cursor},noDrive);
   for(const event of page.events){
    assert(event.sequence>client.cursor);assert.equal(event.collection,'school_expenses');
    assert.equal(event.record.schoolId,school);
    // Tombstones are retained separately from the visible application list.
    if(event.record._syncDeleted)client.records.delete(event.id);
    else client.records.set(event.id,event.record);
   }
   client.cursor=page.cursor;more=page.more;
   assert.equal((await client.live.command(school,{command:'received',device:client.device,cursor:client.cursor})).received,true);
  }while(more);
 }
 return {owner,clients,bootstrap,receive,noDrive,getBaselineReads:()=>baselineReads};
}
const write=(operationId,expectedRevision='',data={amount:10})=>({collection:'school_expenses',id:'shared-record',
 operation:'write',operationId,expectedRevision,data:{schoolId:school,...data}});

for(const count of [1,2,5]){
 test(`${count} independent replay clients see add/edit/delete before Drive ACK without another full snapshot`,async t=>{
  const f=await setup(t,count);
  await Promise.all(f.clients.map(f.bootstrap));
  const snapshotCounts=f.clients.map(client=>client.snapshotPages);
  const added=await f.clients[0].live.commit(school,write(`multidevice-${count}-original-add`),f.noDrive);
  assert.equal(added.cloudState,'committed');assert.equal(added.backupState,'pending');
  await Promise.all(f.clients.map(f.receive));
  for(const client of f.clients){assert.equal(client.records.get('shared-record').amount,10);assert.equal(client.cursor,added.cursor);}
  const edited=await f.clients.at(-1).live.commit(school,write(`multidevice-${count}-original-edit`,added.recordRevision,{amount:33,note:'Only changed record'}),f.noDrive);
  await Promise.all(f.clients.map(f.receive));
  for(const client of f.clients){assert.equal(client.records.get('shared-record').amount,33);assert.equal(client.records.get('shared-record')._syncRevision,edited.recordRevision);}
  const deleted=await f.clients[0].live.commit(school,{collection:'school_expenses',id:'shared-record',operation:'delete',
   operationId:`multidevice-${count}-original-delete`,expectedRevision:edited.recordRevision},f.noDrive);
  await Promise.all(f.clients.map(f.receive));
  for(let index=0;index<count;index++){
   assert.equal(f.clients[index].records.has('shared-record'),false);
   assert.equal(f.clients[index].cursor,deleted.cursor);
   assert.equal(f.clients[index].snapshotPages,snapshotCounts[index]);
  }
  const stats=await f.owner.command(school,{command:'stats'});
  assert.deepEqual(stats.backups.map(row=>({state:row.state,count:row.count})),[{state:'pending',count:3}]);
  assert.equal(f.getBaselineReads(),2,'no device/save performed a new full Drive baseline');
  const late={live:f.clients[0].live,device:'f'.repeat(64),cursor:0,records:new Map(),snapshotPages:0};
  await f.bootstrap(late);
  assert.equal(late.records.get('shared-record')._syncDeleted,true,'new-device snapshot contains the current tombstone');
  const replay=await late.live.replay(school,{command:'changes',after:late.cursor},f.noDrive);
  assert.deepEqual(replay.events,[]);assert.equal(replay.cursor,deleted.cursor);
 });
}

test('offline same-record creates reconcile cloud contents across five readers without a duplicate event or backup',async t=>{
 const f=await setup(t,5);
 const original=write('multidevice-offline-original-add','',{amount:75,title:'Existing cloud value'});
 const saved=await f.owner.commit(school,original,f.noDrive);
 await Promise.all(f.clients.map(f.bootstrap));
 const before=await f.owner.command(school,{command:'stats'});
 const same=await f.clients.at(-1).live.commit(school,{...original,operationId:'multidevice-offline-matching-add',createIntent:true},f.noDrive);
 assert.equal(same.duplicate,true);assert.equal(same.resolution,'cloudRetained');assert.equal(same.recordRevision,saved.recordRevision);
 assert.equal(same.cursor,before.cursor);
 await assert.rejects(f.clients.at(-1).live.commit(school,{...original,
  operationId:'multidevice-offline-different-add',createIntent:true,data:{schoolId:school,amount:999,title:'Different offline value'}},f.noDrive));
 await Promise.all(f.clients.map(f.receive));
 for(const client of f.clients){assert.equal(client.records.get('shared-record').amount,75);assert.equal(client.records.get('shared-record')._syncRevision,saved.recordRevision);}
 const after=await f.owner.command(school,{command:'stats'});
 assert.equal(after.cursor,before.cursor);assert.deepEqual(after.backups,before.backups);
});

test('partial, point and unchanged maps cannot be promoted as a complete initial Drive baseline',async t=>{
 const f=await setup(t,1);
 for(const incomplete of [{partialRecords:true},{partial:true},{pointRead:true},{unchanged:true}]){
  const read=async body=>({success:true,schoolId:school,syncProtocol:2,
   collectionRevision:'incomplete-drive-head',records:body.knownRevision?{}:{only:{schoolId:school,title:'Only one row of the real collection',_syncRevision:'drive-one-row'}},
   ...(body.knownRevision?{unchanged:true}:incomplete)});
  await assert.rejects(f.owner.prepare(school,'school_calendar',read),error=>
   error.code==='LIVE_BASELINE_UNVERIFIED'||error.code==='LIVE_BASELINE_CHANGED'||error.status===502||error.status===409);
 }
 const head=await f.owner.command(school,{command:'head'});
 assert.equal(head.collections.some(row=>row.collection==='school_calendar'&&row.state==='active'),false);
});

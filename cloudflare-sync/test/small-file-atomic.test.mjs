import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
const require=createRequire(import.meta.url);
const {createCloudflareSync}=require('../../functions/cloudflare-sync');
const {createCloudflareDelivery}=require('../../functions/cloudflare-delivery');
const school='vs-'+'a'.repeat(32),key='atomic-photo-test-school-key-000001';
const sha=b=>createHash('sha256').update(b).digest('hex');
async function setup(t){
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[{name:'small-image',modules:true,
  scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],
  outboundService:()=>new Response('{}',{status:503}),durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},
  bindings:{EDGE_KEY:key,LIVE_SYNC_TEST_SCHOOL_ID:school,BROKER_URL:'https://broker.invalid/school-cloud'}}]}));
 t.after(()=>mf.dispose());
 return createCloudflareSync({url:'https://worker.invalid',key,schools:['*'],fetchImpl:(url,opt)=>mf.dispatchFetch(String(url),opt)});
}
test('one Cloudflare photo transaction verifies real bytes and ACKs before Google Script, never fabricating a Drive ID',async t=>{
 const edge=await setup(t),delivery=createCloudflareDelivery({edge,atomicSmallFilesEnabled:true});
 const bytes=Buffer.from('JPEG-TEST-only-'+('portrait'.repeat(5000))),uploadKey='portrait-atomic-school-A-0001';
 const req={action:'managed_upload',uploadKey,name:'synthetic-portrait.jpg',mime:'image/jpeg',base64:bytes.toString('base64')};
 const accepted=await delivery.wholeFile(school,req);
 assert.equal(accepted.cloudflareAccepted,true);
 assert.equal(accepted.driveState,'pending');
 assert.equal(accepted.fileId,undefined);
 assert.equal(accepted.delivery.lane,'file-'+accepted.delivery.id);
 const part=await edge.rpc(school,accepted.delivery.lane,{command:'readPart',id:accepted.delivery.id,offset:0});
 assert.equal(part.sha256,sha(bytes));
 assert.deepEqual(Buffer.from(part.base64,'base64'),bytes);
 assert.equal((await edge.rpc(school,accepted.delivery.lane,{command:'expireVerified'})).expired,0);
 assert.equal((await edge.rpc(school,accepted.delivery.lane,{command:'retention'})).nextCleanupAt,null);
 const replay=await delivery.wholeFile(school,req);
 assert.deepEqual(replay.delivery,accepted.delivery);
 await assert.rejects(delivery.wholeFile(school,{...req,base64:Buffer.from('different').toString('base64')}),/conflict|collision|fingerprint|ID conflict/i);
 let calls=0;
 const deliver=async b=>{
  calls++;
  if(b.operation==='begin')return {success:true,schoolId:school,uploadResumableVersion:1,uploadKey,
   sha256:sha(bytes),sizeBytes:bytes.length,offset:0,committed:false};
  assert.equal(b.operation,'part');
  assert.equal(sha(Buffer.from(b.base64,'base64')),sha(bytes));
  return {success:true,schoolId:school,uploadResumableVersion:1,uploadKey,
   sha256:sha(bytes),sizeBytes:bytes.length,offset:bytes.length,committed:true,fileId:'test-file-id-001'};
 };
 assert.equal((await delivery.drain(school,accepted.delivery.lane,deliver)).processed,1);
 assert.equal(calls,2);
 const verified=await delivery.status(school,accepted.delivery.lane,accepted.delivery.id);
 assert.equal(verified.driveState,'verified');
 assert.equal(verified.fileId,'test-file-id-001');
 assert.ok((await edge.rpc(school,accepted.delivery.lane,{command:'retention'})).nextCleanupAt>Date.now());
});
test('single-file transaction refuses foreign fingerprints, invalid bytes and oversize files without ACK',async t=>{
 const edge=await setup(t),delivery=createCloudflareDelivery({edge,atomicSmallFilesEnabled:true});
 const bytes=Buffer.alloc(1000,83),uploadKey='single-file-safety-001',digest=sha(bytes),
  id=sha(JSON.stringify([school,uploadKey])),lane='file-'+id,
  manifest={uploadKey,sha256:digest,sizeBytes:bytes.length,name:'portrait.jpg',mime:'image/jpeg'};
 await assert.rejects(edge.rpc(school,lane,{command:'putSmall',id,manifest,base64:Buffer.alloc(1000,84).toString('base64')}));
 await assert.rejects(edge.rpc(school,lane,{command:'putSmall',id,manifest:{...manifest,sizeBytes:300000},base64:bytes.toString('base64')}));
 assert.equal((await edge.rpc(school,lane,{command:'stats'})).pending,0);
 const normal=await delivery.wholeFile(school,{action:'managed_upload',...manifest,base64:bytes.toString('base64')});
 assert.equal(normal.driveState,'pending');
});

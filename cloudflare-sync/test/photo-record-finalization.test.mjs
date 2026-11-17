import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
const require=createRequire(import.meta.url);
const {createCloudflareSync}=require('../../functions/cloudflare-sync.js');
const {createCloudflareDelivery}=require('../../functions/cloudflare-delivery.js');
const hash=v=>createHash('sha256').update(v).digest('hex');
const school='vs-'+'a'.repeat(32);
const key='dev-only-photo-metadata-gate-not-a-production-secret';
const mf=new Miniflare(convertV4MiniflareOptions({workers:[{
  name:'photo-ack-gate',modules:true,
  scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,
  compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],
  outboundService:()=>new Response('{}',{status:503}),
  durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},
  bindings:{EDGE_KEY:key,BROKER_URL:'https://broker.invalid/school-cloud'},
}]}));
after(()=>mf.dispose());
const edge=createCloudflareSync({url:'https://worker.invalid',key,schools:['*'],
  fetchImpl:(url,opt)=>mf.dispatchFetch(String(url),opt)});
const delivery=createCloudflareDelivery({edge});
test('Worker rejects wrong and fabricated photo metadata even if Google file itself uploaded',async()=>{
 const bytes=Buffer.from([0xff,0xd8,0xff,0x00,0xff,0xd9]);
 const sha=hash(bytes),rawHash=hash('original-pixel-image');
 const record={version:1,schoolId:school,collection:'students_directory',
  operation:'write',id:'student-1',
  operationId:'original-photo-operation-0000001',
  expectedRecordRevision:'',mediaPrefix:'photo',sourceHash:rawHash,
  data:{schoolId:school,studentId:'student-1',photoSourceHash:rawHash}};
 const uploadKey=hash(JSON.stringify([school,record.collection,record.id,record.operationId,sha]));
 const staged=await delivery.file(school,{operation:'part',
  uploadKey,sha256:sha,sizeBytes:bytes.length,name:'portrait.jpg',
  mime:'image/jpeg',record,offset:0,base64:bytes.toString('base64'),
  chunkSha256:sha});
 assert.equal(staged.driveState,'pending');
 const id=hash(JSON.stringify([school,uploadKey])),lane='file-'+id,claim='photo-original-claim';
 assert.equal(await edge.rpc(school,lane,{command:'claim',id,claim,expires:Date.now()+60000}),true);
 const result={success:true,schoolId:school,uploadResumableVersion:1,
  uploadKey,sha256:sha,sizeBytes:bytes.length,offset:bytes.length,
  committed:true,fileId:'google-photo-original-file'};
 const correct={
  collection:record.collection,id:record.id,operationId:record.operationId,
  fileId:result.fileId,fileSha256:sha,sourceHash:rawHash,
  recordRevision:'google-signed-record-revision',
 };
 const finish=mediaRecord=>edge.rpc(school,lane,{
  command:'finish',id,claim,values:{
    state:'completed',nextAttemptAt:Number.MAX_SAFE_INTEGER,
    result:{...result,mediaRecord},
  },
 });
 const rejected=e=>e&&e.code==='CLOUDFLARE_SYNC_UNAVAILABLE'&&
  e.status===503;
 await assert.rejects(finish(undefined),rejected);
 await assert.rejects(finish({...correct,fileId:'fabricated-file-id'}),rejected);
 await assert.rejects(finish({...correct,operationId:'wrong-original-operation'}),rejected);
 await assert.rejects(finish({...correct,recordRevision:'cf-fake'}),rejected);
 const incomplete=await edge.rpc(school,lane,{command:'status',id});
 assert.notEqual(incomplete.state,'completed');
 assert.equal(await finish(correct),true);
 const verified=await delivery.status(school,lane,id);
 assert.equal(verified.driveState,'verified');
 assert.deepEqual(verified.mediaRecord,correct);
});

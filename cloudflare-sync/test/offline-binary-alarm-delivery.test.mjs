import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash,createHmac,randomUUID} from 'node:crypto';
import {createRequire} from 'node:module';
import {readFile,writeFile,unlink} from 'node:fs/promises';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';

const require=createRequire(import.meta.url);
const {createCloudflareSync}=require('../../functions/cloudflare-sync');
const {createCloudflareDelivery}=require('../../functions/cloudflare-delivery');
const school='vs-'+'9'.repeat(32),secret='isolated-offline-binary-school-only-20261118';
const sha=data=>createHash('sha256').update(data).digest('hex');

test('app-closed Cloudflare alarm independently finishes original person photo and uploaded PDF/metadata in Drive',async t=>{
 const path=new URL('../dist/offline-binary-'+randomUUID()+'.mjs',import.meta.url);
 const source=await readFile(new URL('../dist/worker.js',import.meta.url),'utf8');
 await writeFile(path,source+`
export class OfflineBinaryLane extends SyncLane {
 async alarm(){}
 async fetch(request){
  if(new URL(request.url).pathname==='/__test_alarm'){
   if(this.meta('identity')?.endsWith('/delivery')){
    this.setMeta('deliveryBackoff','0');
    this.ctx.storage.sql.exec('UPDATE lanes SET due=0');
   }else this.ctx.storage.sql.exec("UPDATE edge_ops SET due=0 WHERE state IN ('pending','retry')");
   await super.alarm();
   return Response.json({alarm:true});
  }
  return super.fetch(request);
 }
}`);
 t.after(()=>unlink(path).catch(()=>{}));
 const files=new Map(),records=new Map(),attempts=new Map();
 let brokerCalls=0,delivery;
 const mf=new Miniflare(convertV4MiniflareOptions({workers:[{
  name:'offline-binary-alarm',modules:true,scriptPath:path.pathname,
  compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],
  durableObjects:{LANES:{className:'OfflineBinaryLane',useSQLite:true}},
  r2Buckets:['R2_STAGE'],
  bindings:{EDGE_KEY:secret,R2_STAGING_ENABLED:'true',
   R2_STAGING_SCHOOLS:school,BROKER_URL:'https://broker.invalid/school-cloud'},
  outboundService:async request=>{
   const raw=await request.text(),stamp=request.headers.get('x-vidya-time');
   assert.equal(request.headers.get('authorization'),'Bearer cloudflare-delivery');
   assert.equal(request.headers.get('x-vidya-signature'),
     createHmac('sha256',secret).update(stamp+'\n'+raw).digest('hex'));
   const b=JSON.parse(raw);assert.equal(b.schoolId,school);
   brokerCalls++;
   const outcome=await delivery.drain(school,b.lane,async op=>{
    if(op.action==='managed_records'){
     assert.equal(op.operation,'write');
     const revision='drive-'+op.operationId;
     const record={...op.data,id:op.id,schoolId:school,
      _syncRevision:revision,_syncOperationId:op.operationId};
     records.set(op.id,record);
     return {success:true,schoolId:school,syncProtocol:2,
      recordRevision:revision,record};
    }
    assert.equal(op.action,'managed_upload_resumable');
    const existing=files.get(op.uploadKey);
    if(op.operation==='begin'){
     return {success:true,schoolId:school,uploadResumableVersion:1,
      uploadKey:op.uploadKey,sha256:op.sha256,sizeBytes:op.sizeBytes,
      offset:existing?.bytes.length||0,committed:!!existing,
      ...(existing?{fileId:existing.fileId}:{})};
    }
    assert.equal(op.operation,'part');
    const bytes=Buffer.from(op.base64,'base64');
    assert.equal(sha(bytes),op.chunkSha256);
    assert.equal(sha(bytes),op.sha256);
    const fileId='drive-file-'+op.uploadKey.slice(0,24);
    files.set(op.uploadKey,{bytes,fileId});
    attempts.set(op.uploadKey,(attempts.get(op.uploadKey)||0)+1);
    // Simulate Google committing immutable bytes, then the response dropping.
    if(attempts.get(op.uploadKey)===1)
     throw Object.assign(Error('Provider ACK lost'),{status:504,code:'SCRIPT_TIMEOUT'});
    return {success:true,schoolId:school,uploadResumableVersion:1,
     uploadKey:op.uploadKey,sha256:op.sha256,sizeBytes:op.sizeBytes,
     offset:bytes.length,committed:true,fileId};
   });
   return Response.json(outcome);
  },
 }]}));
 t.after(()=>mf.dispose());
 const edge=createCloudflareSync({url:'https://worker.invalid',key:secret,
  schools:['*'],fetchImpl:(url,opt)=>mf.dispatchFetch(String(url),opt)});
 delivery=createCloudflareDelivery({edge,atomicSmallFilesEnabled:true});
 const ns=await mf.getDurableObjectNamespace('LANES');
 async function alarm(lane){
  const stub=ns.get(ns.idFromName(school+'/'+lane));
  const response=await stub.fetch('https://synthetic.invalid/__test_alarm');
  assert.equal(response.status,200);
 }
 const photo=Buffer.from('synthetic private photo bytes-'.repeat(400));
 const photoHash=sha(photo),sourceHash=sha('original-photo-source'),
  photoKey='offline-owner-photo-20261118-1',photoId='student-offline-1',
  photoOperation='offline-photo-record-original-0001';
 const media={
  version:1,schoolId:school,collection:'students_directory',
  operation:'write',id:photoId,operationId:photoOperation,
  expectedRecordRevision:'',mediaPrefix:'photo',sourceHash,
  data:{schoolId:school,studentId:photoId,photoSourceHash:sourceHash},
 };
 const pdf=Buffer.from('%PDF-1.4\\nsynthetic uploaded document\\n%%EOF');
 const pdfKey='offline-owner-pdf-20261118-1',pdfHash=sha(pdf),
   documentId='document-offline-1',documentOperation='offline-pdf-document-original-0001';
 const document={
  version:1,schoolId:school,id:documentId,operationId:documentOperation,
  expectedRecordRevision:'',
  data:{schoolId:school,documentId,documentRevision:documentOperation,
   studentId:photoId,contentHash:pdfHash,documentKind:'uploadedPdf'},
 };
 for(const file of [
  {uploadKey:photoKey,bytes:photo,name:'photo.jpeg',mime:'image/jpeg',record:media},
  {uploadKey:pdfKey,bytes:pdf,name:'uploaded.pdf',mime:'application/pdf',document},
 ]){
  const stage=await delivery.wholeFile(school,{
   action:'managed_upload',uploadKey:file.uploadKey,name:file.name,
   mime:file.mime,base64:file.bytes.toString('base64'),
   ...(file.record?{record:file.record}:{}),
   ...(file.document?{document:file.document}:{}),
  });
  assert.equal(stage.cloudflareAccepted,true);
  assert.equal(stage.driveState,'pending');
  assert.equal(files.has(file.uploadKey),false,'Google is not called before Cloudflare ACK');
  await alarm(stage.delivery.lane);
  await alarm('delivery');
  // New lanes are admitted asynchronously under durable per-lane leases.
  // Check the immutable provider bytes, not the instant alarm response.
  async function until(check,message){
   for(let i=0;i<250;i++){
    if(await check())return;
    await new Promise(resolve=>setTimeout(resolve,20));
   }
   throw Error(message);
  }
  await until(()=>files.has(file.uploadKey),
    'Original bytes were not delivered independently after the app closed');
  assert.equal((await delivery.status(school,stage.delivery.lane,stage.delivery.id)).driveState,'pending');
  await until(async()=>{const state=await edge.rpc(school,stage.delivery.lane,{
   command:'status',id:stage.delivery.id});
   return state?.state==='retry';},'Provider lost-ACK retry was not durably retained');
  await alarm(stage.delivery.lane);
  await alarm('delivery');
  await until(async()=>{const state=await delivery.status(school,
   stage.delivery.lane,stage.delivery.id);
   return state.driveState==='verified';},'Original provider Drive ACK never verified');
  const complete=await delivery.status(school,stage.delivery.lane,stage.delivery.id);
  assert.equal(complete.driveState,'verified');
  assert.equal(complete.fileId,files.get(file.uploadKey).fileId);
  assert.deepEqual(files.get(file.uploadKey).bytes,file.bytes);
  if(file.record){
   assert.equal(complete.mediaRecord?.recordRevision,'drive-'+photoOperation);
   assert.equal(records.get(photoId)?.photoFileId,complete.fileId);
  }else{
   assert.equal(complete.documentRecord?.recordRevision,'drive-'+documentOperation);
   assert.equal(records.get(documentId)?.fileId,complete.fileId);
  }
 }
 assert.ok(brokerCalls>=4,'Worker alarms, never device polling, drove both deliveries');
 const quota=ns.get(ns.idFromName('saarthi-account-r2-staging-budget-v1'));
 const usage=await quota.r2CapacityStatus();
 assert.ok(usage.verifiedBytes>=photo.length+pdf.length,
  'Both accepted originals remain in verified R2 retention, not purged early');
});

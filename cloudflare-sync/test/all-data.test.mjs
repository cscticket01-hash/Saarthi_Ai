import {test,after} from 'node:test';
import assert from 'node:assert/strict';
import {createHash,createHmac} from 'node:crypto';
import {createRequire} from 'node:module';
import {Miniflare,convertV4MiniflareOptions} from 'miniflare';
const require=createRequire(import.meta.url);
const {createCloudflareSync}=require('../../functions/cloudflare-sync.js');
const {createCloudflareDelivery}=require('../../functions/cloudflare-delivery.js');
const {fixture,A,B}=require('../../functions/test/helpers/managed-school-broker.js');
const key='development-only-not-a-production-secret-0000',hash=v=>createHash('sha256').update(v).digest('hex');
const mf=new Miniflare(convertV4MiniflareOptions({workers:[{name:'all-data',modules:true,scriptPath:new URL('../dist/worker.js',import.meta.url).pathname,compatibilityDate:'2026-10-28',compatibilityFlags:['nodejs_compat'],outboundService:()=>new Response('{}',{status:503}),durableObjects:{LANES:{className:'SyncLane',useSQLite:true}},bindings:{EDGE_KEY:key,BROKER_URL:'https://broker.invalid/school-cloud'}}]}));
after(()=>mf.dispose());
const edge=createCloudflareSync({url:'https://worker.invalid',key,schools:['*'],fetchImpl:(url,opt)=>mf.dispatchFetch(String(url),opt)});
const delivery=createCloudflareDelivery({edge});
const write=(collection,id,operationId='operation-'+id.padEnd(20,'x'))=>({action:'managed_records',collection,operation:'write',syncProtocol:2,id,operationId,expectedRecordRevision:'',data:{schoolId:A,name:id}});
const tenant=n=>'vs-'+n.repeat(32);
async function rpc(school,lane,body){const raw=JSON.stringify({...body,schoolId:school,lane}),time=String(Date.now());const r=await mf.dispatchFetch('https://worker.invalid/internal',{method:'POST',headers:{'content-type':'application/json','x-vidya-time':time,'x-vidya-signature':createHmac('sha256',key).update(time+'\n'+raw).digest('hex')},body:raw});return {status:r.status,...await r.json()};}
test('all school record collections stage privately, replay exactly and require real Drive receipts',async()=>{
 const collections=['teachers_directory','students_directory','school_settings','fee_payments','fee_ledger','exam_results','school_expenses','documents','teacher_salary'];
 for(const col of collections){
  const request=write(col,'new-'+col);const first=await delivery.record(A,request);
  assert.equal(first.cloudflareAccepted,true);assert.equal(first.driveState,'pending');assert.equal(first.recordRevision,undefined);
  const replay=await delivery.record(A,request);assert.deepEqual(replay.delivery,first.delivery);
  await assert.rejects(delivery.record(A,{...request,data:{...request.data,name:'changed'}}),e=>e.status===409);
  await assert.rejects(delivery.status(B,first.delivery.lane,first.delivery.id));
 }
 let delivered=0;
 for(const col of collections){await delivery.drain(A,'records',async request=>{
  assert.equal(request.collection,col);delivered++;return {success:true,schoolId:A,syncProtocol:2,recordRevision:'drive-'+delivered,record:{...request.data,id:request.id,_syncOperationId:request.operationId}};
 });}
 assert.equal(delivered,collections.length);
 const settled=await delivery.record(A,write('teachers_directory','new-teachers_directory'));
 assert.equal(settled.driveState,'verified');assert.equal(settled.recordRevision,'drive-1');
});
test('unverified and foreign Drive acknowledgements cannot complete accepted records',async()=>{
 const school=tenant('d'),request={...write('teachers_directory','bad-ack'),data:{schoolId:school,name:'teacher'}};
 const accepted=await delivery.record(school,request);
 await delivery.drain(school,'records',async()=>({success:true,schoolId:school,syncProtocol:2,recordRevision:'cf-fake'}));
 const row=await edge.rpc(school,'records',{command:'status',id:accepted.delivery.id});
 assert.equal(row.state,'retry');assert.equal(row.response.result,undefined);
 const forged=await rpc(school,'records',{command:'finish',id:accepted.delivery.id,claim:'wrong',values:{state:'completed',nextAttemptAt:Number.MAX_SAFE_INTEGER,result:{success:true}}});
 assert.equal(forged.value,false);
});
test('file bytes are hash-verified, school isolated, resumable at non-chunk offsets and only pruned after committed Drive ACK',async()=>{
 const school=tenant('b'),bytes=Buffer.alloc(1024*1024+17,0x5a),uploadKey='document-owner-revision-000001';
 const manifest={uploadKey,name:'Teacher_ID.pdf',mime:'application/pdf',sha256:hash(bytes),sizeBytes:bytes.length};
 const staged=await delivery.wholeFile(school,{...manifest,base64:bytes.toString('base64')});
 assert.equal(staged.driveState,'pending');assert.equal(staged.fileId,undefined);
 await assert.rejects(delivery.status(A,staged.delivery.lane,staged.delivery.id));
 let offset=0,first=true,parts=0;
 const ack=()=>({success:true,schoolId:school,uploadResumableVersion:1,uploadKey,sha256:manifest.sha256,sizeBytes:bytes.length,offset,committed:offset===bytes.length,...(offset===bytes.length?{fileId:'verified-drive-file'}:{})});
 for(let n=0;n<8;n++){
  await delivery.drain(school,staged.delivery.lane,async request=>{
   if(request.operation==='begin')return ack();
   assert.equal(request.offset,offset);const chunk=Buffer.from(request.base64,'base64');assert.equal(hash(chunk),request.chunkSha256);assert.deepEqual(chunk,bytes.subarray(offset,offset+chunk.length));
   offset+=first?32768:chunk.length;first=false;parts++;return ack();
  });
  const current=await delivery.status(school,staged.delivery.lane,staged.delivery.id);
  if(current.driveState==='verified'){assert.equal(current.fileId,'verified-drive-file');assert.equal(current.sha256,hash(bytes));break;}
  assert.equal(current.fileId,undefined);await new Promise(r=>setTimeout(r,300));
 }
 assert(offset===bytes.length&&parts>=3);
 const pruned=await rpc(school,staged.delivery.lane,{command:'readPart',id:staged.delivery.id,offset:0});assert.equal(pruned.status,409);
 const replay=await delivery.wholeFile(school,{...manifest,base64:bytes.toString('base64')});assert.equal(replay.fileId,'verified-drive-file');
});
test('changed upload manifest and chunk replay are rejected; incomplete bytes never become a Drive file',async()=>{
 const school=tenant('c'),bytes=Buffer.alloc(512*1024+10,0x41),uploadKey='resume-original-000001',id=hash(JSON.stringify([school,uploadKey])),lane='file-'+id;
 const manifest={uploadKey,name:'Original.pdf',mime:'application/pdf',sha256:hash(bytes),sizeBytes:bytes.length};
 await rpc(school,lane,{command:'begin',id,manifest});
 assert.equal((await rpc(school,lane,{command:'begin',id,manifest:{...manifest,name:'Changed.pdf'}})).status,409);
 const part=bytes.subarray(0,512*1024);
 assert.equal((await rpc(school,lane,{command:'part',id,offset:0,base64:part.toString('base64'),chunkSha256:hash(part)})).status,200);
 const changed=Buffer.alloc(part.length,0x42);
 assert.equal((await rpc(school,lane,{command:'part',id,offset:0,base64:changed.toString('base64'),chunkSha256:hash(changed)})).status,409);
 const state=await rpc(school,lane,{command:'status',id});assert.equal(state.value.state,'receiving');assert.equal(state.value.manifest.received,part.length);
 const unsigned=await mf.dispatchFetch('https://worker.invalid/internal',{method:'POST',body:JSON.stringify({schoolId:school,lane,command:'status',id})});assert.equal(unsigned.status,401);
});
test('broker validates authorization before edge acceptance; legacy callers keep original verified path',async()=>{
 let writes=0;
 const f=fixture(async(_,options)=>{const outer=JSON.parse(options.body),b=JSON.parse(outer.payload);writes++;return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:outer.schoolId,syncProtocol:2,recordRevision:'drive-broker',record:{...b.data,id:b.id,_syncOperationId:b.operationId}})};},{cloudflareSync:edge,cloudflareAllDataEnabled:true});
 const request={...write('teachers_directory','broker-teacher'),action:'managed/records',edgeDeliveryVersion:1};
 await assert.rejects(f.call({...request,schoolId:B},'A'));assert.equal(writes,0);
 const first=await f.call(request);assert.equal(first.driveState,'pending');assert.equal(writes,0);
 const legacy=await f.call({...write('teachers_directory','legacy-teacher'),action:'managed/records'});assert.equal(legacy.recordRevision,'drive-broker');assert.equal(writes,1);
 await delivery.drain(A,'records',async req=>({success:true,schoolId:A,syncProtocol:2,recordRevision:'drive-broker-new',record:{...req.data,id:req.id}}));
 const status=await f.call({action:'managed/cloudflare/operation',...first.delivery});assert.equal(status.recordRevision,'drive-broker-new');
});
test('partial batch ACKs survive retry without replaying already committed edits',async()=>{
 const school=tenant('e');
 const operations=['first','second'].map(id=>({...write('school_expenses',id),data:{schoolId:school,amount:10}}));
 const accepted=await delivery.record(school,{action:'managed_records_batch',operations});
 let calls=0;
 const deliver=async request=>{
  calls++;
  assert.deepEqual(request.operations.map(op=>op.id),calls===1?['first','second']:['second']);
  return {success:true,schoolId:school,syncProtocol:2,recordWriteBatchVersion:1,
   acknowledgements:request.operations.map(op=>calls===1&&op.id==='second'
    ?{operationId:op.operationId,success:false,code:'SCRIPT_TIMEOUT'}
    :{operationId:op.operationId,success:true,recordRevision:'drive-'+op.id,
      record:{...op.data,id:op.id,_syncOperationId:op.operationId}})};
 };
 await delivery.drain(school,'records',deliver);
 const partial=await edge.rpc(school,'records',{command:'status',id:accepted.delivery.id});
 assert.equal(partial.state,'retry');assert.equal(Object.keys(partial.response.partial).length,1);
 await new Promise(resolve=>setTimeout(resolve,5100));
 // Recreate the broker helper to model a process restart with no in-memory ACKs.
 const restarted=createCloudflareDelivery({edge});
 await restarted.drain(school,'records',deliver);
 const final=await restarted.status(school,'records',accepted.delivery.id);
 assert.equal(final.driveState,'verified');assert.equal(final.acknowledgements.length,2);assert.equal(calls,2);
});
test('batch ACK for another record is rejected before recording partial success',async()=>{
 const school=tenant('f'),op={...write('school_expenses','own-record'),data:{schoolId:school}};
 const accepted=await delivery.record(school,{action:'managed_records_batch',operations:[op]});
 await delivery.drain(school,'records',async()=>({success:true,schoolId:school,syncProtocol:2,recordWriteBatchVersion:1,
  acknowledgements:[{operationId:op.operationId,success:true,recordRevision:'drive-foreign',record:{schoolId:school,id:'another-record'}}]}));
 const row=await edge.rpc(school,'records',{command:'status',id:accepted.delivery.id});
 assert.equal(row.state,'retry');assert.deepEqual(row.response.partial,{});
});
test('real Sheet lifecycle saved.data ACK binds an omitted wrapper ID through the exact operation ID',async()=>{
 const school=tenant('9'),request={...write('teachers_directory','saved-data'),data:{schoolId:school,name:'Synthetic teacher'}};
 const accepted=await delivery.record(school,request);
 await delivery.drain(school,'records',async op=>({success:true,schoolId:school,syncProtocol:2,recordRevision:'drive-saved-data',
  record:{...op.data,_syncRevision:'drive-saved-data',_syncOperationId:op.operationId}}));
 const result=await delivery.status(school,'records',accepted.delivery.id);
 assert.equal(result.driveState,'verified');assert.equal(result.recordRevision,'drive-saved-data');
 for(const suffix of ['8','7']){
  const foreignSchool=tenant(suffix),op={...request,id:'wrong-'+suffix,data:{schoolId:foreignSchool}};
  const receipt=await delivery.record(foreignSchool,op);
  await delivery.drain(foreignSchool,'records',async()=>({success:true,schoolId:foreignSchool,syncProtocol:2,recordRevision:'drive-real',
   record:{schoolId:foreignSchool,_syncOperationId:suffix==='8'?'another-operation':op.operationId,_syncRevision:suffix==='7'?'another-revision':'drive-real'}}));
  const row=await edge.rpc(foreignSchool,'records',{command:'status',id:receipt.delivery.id});
  assert.equal(row.state,'retry');assert.equal(row.response.failureCode,'ACK_UNVERIFIED');
 }
});
test('authenticated broker drain commits real record ACK and pending jobs drain after admission rollback',async()=>{
 let writes=0;
 const fetch=async(_,options)=>{const outer=JSON.parse(options.body),request=JSON.parse(outer.payload);writes++;
  return {ok:true,status:200,text:async()=>JSON.stringify({success:true,schoolId:outer.schoolId,syncProtocol:2,
   recordRevision:'drive-real-broker',record:{...request.data,id:request.id,_syncOperationId:request.operationId}})};};
 const enabled=fixture(fetch,{cloudflareSync:edge,cloudflareAllDataEnabled:true,now:Date.now});
 enabled.docs.get('school_entitlements/'+A).startsAt=Date.now()-1000;
 const accepted=await enabled.call({...write('school_settings','staff-payroll'),action:'managed/records',edgeDeliveryVersion:1});
 assert.equal(writes,0);
 const rolledBack=fixture(fetch,{cloudflareSync:edge,cloudflareAllDataEnabled:false,now:Date.now});
 rolledBack.docs.get('school_entitlements/'+A).startsAt=Date.now()-1000;
 await assert.rejects(rolledBack.handle({method:'POST',headers:{},body:{action:'managed/cloudflare/drain',schoolId:A,lane:'records'}}));
 assert.equal(writes,0);
 const body={action:'managed/cloudflare/drain',schoolId:A,lane:'records'},raw=JSON.stringify(body),time=String(Date.now());
 const drained=await rolledBack.handle({method:'POST',body,headers:{'x-vidya-time':time,
  'x-vidya-signature':createHmac('sha256',key).update(time+'\n'+raw).digest('hex')}});
 assert.equal(drained.processed,1);assert.equal(writes,1);
 const status=await rolledBack.call({action:'managed/cloudflare/operation',...accepted.delivery});
 assert.equal(status.recordRevision,'drive-real-broker');assert.equal(status.driveState,'verified');
});

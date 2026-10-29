'use strict';
const {createHash,randomUUID}=require('node:crypto');
const digest=v=>createHash('sha256').update(v).digest('hex');
const FILE=/^file-[a-f0-9]{64}$/;
const fail=(status,code)=>{throw Object.assign(Error('Cloud delivery pending; original work retained.'),{status,code,publicMessage:true});};
const terminal=new Set(['RECORD_REVISION_CONFLICT','OPERATION_ID_CONFLICT','SCRIPT_RECORD_REVISION_CONFLICT','SCRIPT_OPERATION_ID_CONFLICT','SCRIPT_DOCUMENT_REVISION_CONFLICT','SCRIPT_PERMISSION_DENIED','SCRIPT_INVALID_SYNC_OPERATION','SCRIPT_BLANK_SCHOOL_PROFILE','SCRIPT_EMPTY_PROFILE_OVERWRITE','SCRIPT_STUDENT_GENERATION_DELETED','SCRIPT_EXTERNAL_EDIT_REVIEW_REQUIRED','SCRIPT_STUDENT_SLOT_CONFLICT','STUDENT_SLOT_CONFLICT','SCRIPT_WORKBOOK_IDENTITY_MISMATCH','SCRIPT_RECORD_VERIFY_FAILED']);
function createCloudflareDelivery({edge,now=Date.now,recordParallelism=1}){
 const pending=(school,lane,id)=>({success:true,schoolId:school,edgeDeliveryVersion:1,cloudflareAccepted:true,driveState:'pending',delivery:{lane,id}});
 async function status(school,lane,id){
  if(!(lane==='records'||FILE.test(lane))||!/^[a-f0-9]{64}$/.test(id)||FILE.test(lane)&&lane!=='file-'+id)fail(400,'INVALID_EDGE_RECEIPT');
  const row=await edge.rpc(school,lane,{command:'status',id});
  const timing=row.response?.timing;
  const measured=timing&&timing.version===1&&['deliveryMillis','observedAt'].every(k=>Number.isSafeInteger(timing[k])&&timing[k]>=0)?{deliveryTiming:{version:1,deliveryMillis:timing.deliveryMillis,observedAt:timing.observedAt,...(Number.isSafeInteger(timing.queueWaitMillis)&&timing.queueWaitMillis>=0?{queueWaitMillis:timing.queueWaitMillis}:{})}}:{};
  if(['completed','needsAttention'].includes(row.state)&&row.response?.result)return {...row.response.result,cloudflareAccepted:true,driveState:'verified',...measured};
  if(row.state==='needsAttention')fail(row.response?.failureStatus||409,row.response?.failureCode||'EDGE_DELIVERY_REVIEW_REQUIRED');
  if(row.response?.failureStatus===429)throw Object.assign(Error('Provider quota reached; staged work retained.'),{status:429,code:row.response.failureCode||'SCRIPT_QUOTA_EXCEEDED',retryAfterMs:Math.max(1000,row.due-now()),publicMessage:true});
  return {...pending(school,lane,id),...measured,deliveryStatus:{state:row.state,
   ...(row.state==='retry'&&Number.isSafeInteger(row.due)?{retryAtMillis:row.due}:{}),
   ...(/^[A-Z_]{1,80}$/.test(row.response?.failureCode||'')?{failureCode:row.response.failureCode}:{})}};
 }
 async function record(school,request){
  const identity=request.action==='managed_records_batch'?request.operations.map(op=>[op.collection,op.id,op.operationId]):[request.collection,request.id,request.operationId];
  const id=digest(JSON.stringify([school,request.action,identity]));
  await edge.rpc(school,'records',{command:'enqueue',id,request});return status(school,'records',id);
 }
 function fileIdentity(school,uploadKey){const id=digest(JSON.stringify([school,uploadKey]));return {id,lane:'file-'+id};}
 async function file(school,request){
  const {id,lane}=fileIdentity(school,request.uploadKey);
  const manifest={uploadKey:request.uploadKey,sha256:request.sha256,sizeBytes:request.sizeBytes,name:request.name,mime:request.mime};
  const row=await edge.rpc(school,lane,{command:'begin',id,manifest});
  if(request.operation==='part'){
   const bytes=Buffer.from(request.base64,'base64');
   for(let pos=0;pos<bytes.length;pos+=512*1024){const chunk=bytes.subarray(pos,pos+512*1024);await edge.rpc(school,lane,{command:'part',id,offset:request.offset+pos,base64:chunk.toString('base64'),chunkSha256:digest(chunk)});}
  }
  const current=request.operation==='part'||request.operation==='status'?await edge.rpc(school,lane,{command:'status',id}):row;
  if(current.manifest.received===manifest.sizeBytes)return status(school,lane,id);
  return {success:true,schoolId:school,uploadResumableVersion:1,uploadKey:manifest.uploadKey,sha256:manifest.sha256,sizeBytes:manifest.sizeBytes,offset:current.manifest.received,committed:false,cloudflareAccepted:true,driveState:'receiving'};
 }
 async function wholeFile(school,request){
  if(!request.uploadKey)fail(400,'EDGE_UPLOAD_KEY_REQUIRED');
  if(typeof request.base64!=='string'||! /^[A-Za-z0-9+/]*={0,2}$/.test(request.base64))fail(400,'INVALID_EDGE_FILE');
  const bytes=Buffer.from(request.base64,'base64');if(bytes.toString('base64')!==request.base64||!bytes.length||bytes.length>20*1024*1024)fail(400,'INVALID_EDGE_FILE');
  const m={uploadKey:request.uploadKey,sha256:digest(bytes),sizeBytes:bytes.length,name:request.name,mime:request.mime};
  const {id,lane}=fileIdentity(school,m.uploadKey);const row=await edge.rpc(school,lane,{command:'begin',id,manifest:m});
  if(row.state==='completed')return status(school,lane,id);
  for(let offset=row.manifest.received;offset<bytes.length;offset+=512*1024){const chunk=bytes.subarray(offset,offset+512*1024);await edge.rpc(school,lane,{command:'part',id,offset,base64:chunk.toString('base64'),chunkSha256:digest(chunk)});}
  return status(school,lane,id);
 }
 function verifiedRecord(result,school,request){
  if(result?.success!==true||result.schoolId!==school||result.syncProtocol!==2||
    typeof result.recordRevision!=='string'||!result.recordRevision||result.recordRevision.startsWith('cf-'))return false;
  const record=result.record;if(!record)return true;
  if(record.schoolId!==school||record._syncRevision!==undefined&&record._syncRevision!==result.recordRevision)return false;
  if(!request)return true;
  // Sheet lifecycle ACKs return saved.data, which may omit the wrapper ID.
  // The original immutable operation ID supplies that binding; a present ID
  // must still match. Never weaken foreign-school/operation/revision checks.
  return (record.id===undefined?record._syncOperationId===request.operationId:record.id===request.id)&&
    (record._syncOperationId===undefined||record._syncOperationId===request.operationId);
 }

 async function drainOne(school,lane,deliver,job){
  const claim=randomUUID();if(!await edge.rpc(school,lane,{command:'claim',id:job.id,claim,expires:now()+120000}))return {processed:0};
  const started=now(),original=JSON.parse(job.payload);
  const finish=values=>edge.rpc(school,lane,{command:'finish',id:job.id,claim,values:{...values,timing:{version:1,deliveryMillis:Math.max(0,now()-started),observedAt:now(),...(Number.isSafeInteger(job.created)&&job.created>0?{queueWaitMillis:Math.max(0,started-job.created)}:{})}}});
  let partial=job.response?JSON.parse(job.response).partial||{}:{};
  try{
   let result;
   if(lane==='records'){
    if(original.action==='managed_records_batch'){
     const remaining=original.operations.filter(op=>!partial[op.operationId]);
     const reply=await deliver({...original,operations:remaining});
     if(reply.success!==true||reply.schoolId!==school||reply.syncProtocol!==2||reply.recordWriteBatchVersion!==1||!Array.isArray(reply.acknowledgements))fail(502,'ACK_UNVERIFIED');
     const seen=new Set();for(const ack of reply.acknowledgements){
      if(!remaining.some(op=>op.operationId===ack.operationId)||seen.has(ack.operationId)||typeof ack.success!=='boolean'||ack.success&&!verifiedRecord({...ack,success:true,schoolId:school,syncProtocol:2},school,remaining.find(op=>op.operationId===ack.operationId)))fail(502,'ACK_UNVERIFIED');seen.add(ack.operationId);
     }
     for(const ack of reply.acknowledgements)if(ack.success||terminal.has(ack.code))partial[ack.operationId]=ack;
     if(original.operations.some(op=>!partial[op.operationId])){
      const refusal=reply.acknowledgements.find(ack=>!ack.success&&!terminal.has(ack.code));
      if(refusal?.code==='SCRIPT_QUOTA_EXCEEDED')fail(429,refusal.code);fail(503,'EDGE_DELIVERY_PENDING');
     }
     result={success:true,schoolId:school,syncProtocol:2,recordWriteBatchVersion:1,acknowledgements:original.operations.map(op=>partial[op.operationId])};
    }else {result=await deliver(original);if(!verifiedRecord(result,school,original))fail(502,'ACK_UNVERIFIED');}
   }else {
    if(!FILE.test(lane))fail(400,'INVALID_EDGE_RECEIPT');
    const request={action:'managed_upload_resumable',uploadKey:original.uploadKey,sha256:original.sha256,sizeBytes:original.sizeBytes,name:original.name,mime:original.mime};
    let progress=await deliver({...request,operation:'begin'});
    const valid=p=>p?.success===true&&p.schoolId===school&&p.uploadResumableVersion===1&&p.uploadKey===original.uploadKey&&p.sha256===original.sha256&&p.sizeBytes===original.sizeBytes&&Number.isSafeInteger(p.offset)&&p.offset>=0&&p.offset<=original.sizeBytes&&typeof p.committed==='boolean'&&(p.committed||p.offset<original.sizeBytes)&&(!p.committed||p.offset===original.sizeBytes&&/^[A-Za-z0-9_-]{1,200}$/.test(p.fileId||''));
    if(!valid(progress))fail(502,'UPLOAD_ACK_UNVERIFIED');
    if(!progress.committed){
     const chunk=await edge.rpc(school,lane,{command:'readPart',id:job.id,offset:progress.offset});
     const bytes=Buffer.from(chunk.base64,'base64');if(chunk.offset!==progress.offset||bytes.length!==chunk.sizeBytes||digest(bytes)!==chunk.sha256)fail(502,'EDGE_FILE_HASH_MISMATCH');
     progress=await deliver({...request,operation:'part',offset:progress.offset,base64:chunk.base64,chunkSha256:chunk.sha256});if(!valid(progress))fail(502,'UPLOAD_ACK_UNVERIFIED');
    }
    if(!progress.committed){await finish({state:'retry',nextAttemptAt:now()+250});return {processed:0};}
    result={...progress,fileUrl:'https://drive.google.com/file/d/'+progress.fileId+'/view'};
   }
   const stored=await finish({state:'completed',nextAttemptAt:Number.MAX_SAFE_INTEGER,result,completedAt:now()});return {processed:stored===true?1:0};
  }catch(error){
   const review=terminal.has(error.code)||[400,401,403,409,422].includes(error.status);
   await finish({state:review?'needsAttention':'retry',nextAttemptAt:review?Number.MAX_SAFE_INTEGER:now()+Math.max(error.status===429?60000:5000,Math.min(86400000,Number(error.retryAfterMs)||0)),partial,
    failureStatus:Number.isInteger(error.status)&&error.status>=400&&error.status<=599?error.status:503,failureCode:typeof error.code==='string'&&/^[A-Z_]{1,80}$/.test(error.code)?error.code:'EDGE_DELIVERY_PENDING'});
   return {processed:0};
  }
 }
 async function drain(school,lane,deliver){
  // Default remains serial. Two independently eligible jobs are admitted only
  // with an explicit broker rollout flag and a scheduler-capable Worker.
  let limit=1;
  if(lane==='records'&&recordParallelism===2){
   const capability=await edge.rpc(school,lane,{command:'capabilities'});
   if(capability?.recordSchedulingVersion===1)limit=2;
  }
  const jobs=await edge.rpc(school,lane,{command:'pending',limit});
  if(!Array.isArray(jobs)||jobs.length>limit)fail(502,'EDGE_SCHEDULER_UNVERIFIED');
  const results=await Promise.all(jobs.map(job=>drainOne(school,lane,deliver,job)));
  return {processed:results.reduce((n,r)=>n+r.processed,0)};
 }
 return {record,file,wholeFile,status,drain};
}
module.exports={createCloudflareDelivery};

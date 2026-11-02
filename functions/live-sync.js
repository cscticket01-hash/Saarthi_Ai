'use strict';
const {createHash,createHmac}=require('node:crypto');
const {canonical}=require('./live-sync-canonical');
const COLLECTIONS=new Set(['school_expenses','school_calendar','school_notices','school_settings','students_directory','teachers_directory','fee_settings','fee_ledger','fee_payments','teacher_salary','attendance_records','attendance_logs','teacher_attendance','teacher_schedules','exams','exam_results','exam_center_results','documents','student_scan_index','scanner_devices','school_config']);
const payloadHash=record=>createHash('sha256').update(canonical({deleted:record._syncDeleted===true,data:Object.fromEntries(Object.entries(record).filter(([key])=>!key.startsWith('_sync')))})).digest('hex');
const refuse=(status,code)=>{throw Object.assign(Error('Live sync admission requires verified school state.'),{status,code,publicMessage:true});};
function createLiveSync({edge,schools=[],now=Date.now}){
 const enabled=school=>schools.includes(school)&&edge?.enabled(school)===true;
 async function command(school,body){if(!enabled(school))refuse(412,'LIVE_SYNC_DISABLED');return edge.rpc(school,'live',body);}
 async function resolve(school,collection,id,readDrive,cachedBaseline){
  const result=await command(school,{command:'read',collection,id});
  if(result.source!=='drive')return {result,baseline:null};
  // A device may already hold the exact committed version. Verify its full
  // content against retained metadata; never trust a name, timestamp or flag.
  if(cachedBaseline&&cachedBaseline.schoolId===school&&cachedBaseline._syncRevision===result.recordRevision&&payloadHash(cachedBaseline)===result.payloadHash){
   return {result:{...result,record:cachedBaseline},baseline:{...cachedBaseline,_syncRevision:result.driveRevision}};
  }
  const reply=await readDrive({action:'managed_records',operation:'read',collection,id,syncProtocol:2});
  const record=reply?.records?.[id];
  if(reply?.success!==true||reply.schoolId!==school||reply.syncProtocol!==2||reply.pointRead!==true||!record||record.schoolId!==school||record._syncRevision!==result.driveRevision||payloadHash(record)!==result.payloadHash)refuse(503,'LIVE_DRIVE_READ_UNVERIFIED');
  return {result:{...result,record:{...record,_syncRevision:result.recordRevision}},baseline:record};
 }
 async function read(school,collection,id,readDrive){return (await resolve(school,collection,id,readDrive)).result;}
 async function commit(school,body,readDrive){
  const {cachedBaseline,...wire}=body;
  const {baseline}=await resolve(school,body.collection,body.id,readDrive,cachedBaseline);
  return command(school,{...wire,command:'commit',...(baseline?{baseline}:{})});
 }
 async function replay(school,body,readDrive){
  const result=await command(school,body),cache=new Map();
  const authority=body.command==='changes'?await command(school,{command:'head'}):null;
  const rows=body.command==='changes'?result.events:result.records;
  if(!Array.isArray(rows))refuse(502,'LIVE_REPLAY_UNVERIFIED');
  for(const entry of rows){
   const collection=body.command==='changes'?entry.collection:body.collection,key=collection+'/'+entry.id;
   if(authority?.collections?.find(item=>item.collection===collection)?.state==='legacy'){
    // Verified rollback retired this event's live owner. Retain a durable
    // invalidation so receivers reconcile through the normal Drive gateway;
    // never hydrate an obsolete live revision or stall other collections.
    entry.record=null;entry.retired=true;entry.source='drive';entry.recordAuthority='school-drive';continue;
   }
   // Superseded events are current-state hints. Fetch one current version per
   // key, never ask Drive for a historical row that has since been overwritten.
   if(!cache.has(key))cache.set(key,await read(school,collection,entry.id,readDrive));
   const current=cache.get(key);if(!current.record)refuse(503,'LIVE_DRIVE_READ_UNVERIFIED');
   entry.record=current.record;entry.coalesced=true;
  }
  if(body.command==='snapshot'&&(await command(school,{command:'head'})).cursor!==body.at)refuse(409,'LIVE_SNAPSHOT_CHANGED');
  return result;
 }
 async function prepare(school,collection,read){
  if(!COLLECTIONS.has(collection))refuse(412,'LIVE_COLLECTION_NOT_ADMITTED');
  const source=await read({action:'managed_records',operation:'read',collection,syncProtocol:2});
  if(source.success!==true||source.schoolId!==school||source.syncProtocol!==2||!source.records||typeof source.records!=='object'||Array.isArray(source.records)||typeof source.collectionRevision!=='string'||source.missingRecords?.length||source.partialRecords===true||source.partial===true||source.pointRead===true||source.unchanged===true)refuse(502,'LIVE_BASELINE_UNVERIFIED');
  const entries=Object.entries(source.records).filter(([id])=>collection!=='school_settings'||id!=='staff_payroll_directory');if(entries.length>100000)refuse(413,'LIVE_BASELINE_TOO_LARGE');
  const fingerprint=createHash('sha256').update(canonical(Object.fromEntries(entries))).digest('hex');
  const started=await command(school,{command:'seedBegin',collection,count:entries.length,fingerprint,sourceRevision:source.collectionRevision,replaceSeeding:true});
  if(started.state==='active')return {liveProtocol:1,schoolId:school,state:'active'};
  // Bound pages by bytes as well as record count; every original row remains.
  let rows=[],bytes=0;
  for(const [id,data]of entries){
   const size=Buffer.byteLength(JSON.stringify({id,data}));if(size>250000)refuse(413,'LIVE_BASELINE_RECORD_TOO_LARGE');
   if(rows.length&&(rows.length===100||bytes+size>250000)){await command(school,{command:'seedPage',collection,fingerprint,rows});rows=[];bytes=0;}
   rows.push({id,data});bytes+=size;
  }
  if(rows.length)await command(school,{command:'seedPage',collection,fingerprint,rows});
  const verified=await read({action:'managed_records',operation:'read',collection,syncProtocol:2,knownRevision:source.collectionRevision});
  if(verified.schoolId!==school||verified.success!==true||verified.syncProtocol!==2||verified.collectionRevision!==source.collectionRevision||verified.unchanged!==true)refuse(409,'LIVE_BASELINE_CHANGED');
  return {liveProtocol:1,schoolId:school,...await command(school,{command:'seedSeal',collection,fingerprint})};
 }
 async function drain(school,deliver){
  const {job}=await command(school,{command:'backupClaim'});if(!job)return {processed:0};
  const finish=values=>command(school,{command:'backupFinish',sequence:job.seq,claim:job.claim,...values});
  try{
   const ack=await deliver(job.request);
   const record=ack?.record;
   if(ack?.success!==true||ack.schoolId!==school||ack.syncProtocol!==2||typeof ack.recordRevision!=='string'||!ack.recordRevision||/^(live-|cf-)/.test(ack.recordRevision)||
      record&&(record.schoolId!==school||record._syncRevision!==undefined&&record._syncRevision!==ack.recordRevision||record.id!==undefined&&record.id!==job.request.id||record._syncOperationId!==undefined&&record._syncOperationId!==job.request.operationId))refuse(502,'LIVE_BACKUP_ACK_UNVERIFIED');
   let proof=record;
   if(!proof){
    const readback=await deliver({action:'managed_records',operation:'read',collection:job.request.collection,id:job.request.id,syncProtocol:2});
    if(readback?.success!==true||readback.schoolId!==school||readback.syncProtocol!==2||readback.pointRead!==true)refuse(502,'LIVE_BACKUP_ACK_UNVERIFIED');
    proof=readback.records?.[job.request.id];
   }
   if(!proof||proof.schoolId!==school||proof._syncRevision!==ack.recordRevision||proof._syncOperationId!==job.request.operationId)refuse(502,'LIVE_BACKUP_ACK_UNVERIFIED');
   const expected=job.request.operation==='delete'?{schoolId:school,_syncDeleted:true}:job.request.data;
   const savedRecord={...proof};if(!Object.hasOwn(expected,'id')&&savedRecord.id===job.request.id)delete savedRecord.id;
   if(payloadHash(savedRecord)!==payloadHash(expected))refuse(502,'LIVE_BACKUP_CONTENT_UNVERIFIED');
   const saved=await finish({verified:true,driveRevision:ack.recordRevision});return {processed:saved.accepted?1:0};
  }catch(error){
   const review=[400,401,403,409,422].includes(error.status);
   await finish({verified:false,review,retryAt:now()+Math.max(5000,Math.min(86400000,Number(error.retryAfterMs)||0))});return {processed:0};
  }
 }
 async function rollback(school,collection,readDrive,rollbackToken){
  if(!COLLECTIONS.has(collection))refuse(412,'LIVE_COLLECTION_NOT_ADMITTED');
  const head=await command(school,{command:'head'});
  const rows=[];let after='';
  do{
   const page=await command(school,{command:'rollbackSnapshot',collection,at:head.cursor,after});
   if(!Array.isArray(page.records))refuse(502,'LIVE_ROLLBACK_UNVERIFIED');
   for(const entry of page.records){
    // A 24h resident cache may already have exact verified Drive proof.
    // Rollback needs signed Drive readback, never a cache or merely an ACK.
    if(!entry.driveRevision||!entry.payloadHash)refuse(409,'LIVE_BACKUP_PENDING');
    const reply=await readDrive({action:'managed_records',operation:'read',collection,id:entry.id,syncProtocol:2});
    const record=reply?.records?.[entry.id];
    if(reply?.success!==true||reply.schoolId!==school||reply.syncProtocol!==2||reply.pointRead!==true||!record||record.schoolId!==school||record._syncRevision!==entry.driveRevision||payloadHash(record)!==entry.payloadHash)refuse(503,'LIVE_ROLLBACK_DRIVE_UNVERIFIED');
    rows.push({id:entry.id,recordRevision:entry.recordRevision,driveRevision:entry.driveRevision,payloadHash:entry.payloadHash});
   }
   if(rows.length>100000)refuse(413,'LIVE_BASELINE_TOO_LARGE');
   if(page.next!==null&&(typeof page.next!=='string'||page.next<=after))refuse(502,'LIVE_ROLLBACK_UNVERIFIED');
   after=page.next;
  }while(after!==null);
  const fingerprint=createHash('sha256').update(canonical(rows)).digest('hex');
  const result=await command(school,{command:'rollbackSeal',collection,cursor:head.cursor,fingerprint});
  return {success:true,...result,rollbackToken};
 }
 return {enabled,command,prepare,drain,read,commit,replay,rollback};
}
function liveGrant({schoolId,uid,key,endpoint,now=Date.now()}){
 const value=Buffer.from(JSON.stringify({version:1,schoolId,uid,expiresAt:now+60000})).toString('base64url');
 const grant=value+'.'+createHmac('sha256',key).update('live-v1\n'+value).digest('hex');
 const url=new URL('/live',endpoint);url.protocol='wss:';return {liveProtocol:1,schoolId,endpoint:url.href,protocols:['vidya-live-v1','grant.'+grant],expiresAt:now+60000};
}
module.exports={createLiveSync,liveGrant,COLLECTIONS};

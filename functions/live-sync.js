'use strict';
const {createHash,createHmac}=require('node:crypto');
const {canonical}=require('./live-sync-canonical');
const COLLECTIONS=new Set(['school_expenses','school_calendar','school_notices','school_settings']);
const refuse=(status,code)=>{throw Object.assign(Error('Live sync admission requires verified school state.'),{status,code,publicMessage:true});};
function createLiveSync({edge,schools=[],now=Date.now}){
 const enabled=school=>schools.includes(school)&&edge?.enabled(school)===true;
 async function command(school,body){if(!enabled(school))refuse(412,'LIVE_SYNC_DISABLED');return edge.rpc(school,'live',body);}
 async function prepare(school,collection,read){
  if(!COLLECTIONS.has(collection))refuse(412,'LIVE_COLLECTION_NOT_ADMITTED');
  const source=await read({action:'managed_records',operation:'read',collection,syncProtocol:2});
  if(source.success!==true||source.schoolId!==school||source.syncProtocol!==2||!source.records||typeof source.records!=='object'||Array.isArray(source.records)||typeof source.collectionRevision!=='string'||source.missingRecords?.length)refuse(502,'LIVE_BASELINE_UNVERIFIED');
  const entries=Object.entries(source.records);if(entries.length>100000)refuse(413,'LIVE_BASELINE_TOO_LARGE');
  const fingerprint=createHash('sha256').update(canonical(source.records)).digest('hex');
  const started=await command(school,{command:'seedBegin',collection,count:entries.length,fingerprint,sourceRevision:source.collectionRevision});
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
   const saved=await finish({verified:true,driveRevision:ack.recordRevision});return {processed:saved.accepted?1:0};
  }catch(error){
   const review=[400,401,403,409,422].includes(error.status);
   await finish({verified:false,review,retryAt:now()+Math.max(5000,Math.min(86400000,Number(error.retryAfterMs)||0))});return {processed:0};
  }
 }
 return {enabled,command,prepare,drain};
}
function liveGrant({schoolId,uid,key,endpoint,now=Date.now()}){
 const value=Buffer.from(JSON.stringify({version:1,schoolId,uid,expiresAt:now+60000})).toString('base64url');
 const grant=value+'.'+createHmac('sha256',key).update('live-v1\n'+value).digest('hex');
 const url=new URL('/live',endpoint);url.protocol='wss:';return {liveProtocol:1,schoolId,endpoint:url.href,protocols:['vidya-live-v1','grant.'+grant],expiresAt:now+60000};
}
module.exports={createLiveSync,liveGrant,COLLECTIONS};

'use strict';
const {createHash}=require('node:crypto');
const {canonical}=require('./live-sync-canonical');
const {COLLECTIONS}=require('./live-sync');
const refuse=(status,code)=>{throw Object.assign(Error('Live sync verification is pending; saved changes are retained.'),{status,code,publicMessage:true});};
const revision=(collection,cursor)=>'live:'+collection+':'+cursor;
const validId=id=>typeof id==='string'&&id.length>0&&id.length<=200&&!id.includes('/')&&!['.','..','__proto__','prototype','constructor'].includes(id);
function createLiveGateway({liveSync,migration,maxRecords=100000,maxBytes=20*1024*1024}){
 const envelope=school=>({success:true,schoolId:school,syncProtocol:2,liveProtocol:1,recordAuthority:'cloudflare-live'});
 function verifyRecord(school,id,record){
  if(!validId(id)||!record||typeof record!=='object'||Array.isArray(record)||record.schoolId!==school||record.id!==undefined&&record.id!==id||typeof record._syncRevision!=='string'||!record._syncRevision||record._syncRevision.length>100)refuse(502,'LIVE_GATEWAY_RECORD_UNVERIFIED');
 }
 async function reserved(school,collection,readDrive){
  if(collection!=='school_settings')return {suffix:'',records:{}};
  const reply=await readDrive({action:'managed_records',collection,operation:'read',id:'staff_payroll_directory',syncProtocol:2});
  if(reply?.success!==true||reply.schoolId!==school||reply.syncProtocol!==2||reply.pointRead!==true)refuse(503,'LIVE_RESERVED_RECORD_UNVERIFIED');
  const record=reply.records?.staff_payroll_directory;
  if(record){verifyRecord(school,'staff_payroll_directory',record);if(/^(live-|cf-)/.test(record._syncRevision))refuse(503,'LIVE_RESERVED_RECORD_UNVERIFIED');}
  return {suffix:':'+createHash('sha256').update(canonical(record||null)).digest('hex'),records:record?{staff_payroll_directory:record}:{}};
 }
 async function head(school,collection,readDrive,current){
  const value=current||await liveSync.command(school,{command:'head'}),item=value.collections?.find(row=>row.collection===collection&&row.state==='active');
  if(value.schoolId!==school||value.liveProtocol!==1||!Number.isSafeInteger(value.cursor)||!item||!Number.isSafeInteger(item.cursor))refuse(503,'LIVE_GATEWAY_HEAD_UNVERIFIED');
  const extra=await reserved(school,collection,readDrive);return {value,extra,collectionRevision:revision(collection,item.cursor)+extra.suffix};
 }
 async function records(school,body,readDrive){
  if(body.liveProtocol!==1||body.syncProtocol!==2)refuse(412,'LIVE_PROTOCOL_REQUIRED');
  if(!COLLECTIONS.has(body.collection))refuse(412,'LIVE_COLLECTION_NOT_ADMITTED');
  if(!['read','write','delete'].includes(body.operation))refuse(412,'LIVE_OPERATION_NOT_ADMITTED');
  if(body.operation==='read'){
   if(body.id!==undefined){
    if(!validId(body.id))refuse(400,'LIVE_RECORD_ID_INVALID');
    const result=await liveSync.read(school,body.collection,body.id,readDrive);
    if(result.schoolId!==school||result.liveProtocol!==1||!Number.isSafeInteger(result.cursor)||result.cursor<0)refuse(502,'LIVE_GATEWAY_READ_UNVERIFIED');
    if(result.record)verifyRecord(school,body.id,result.record);
    else if(result.source!=='missing')refuse(503,'LIVE_GATEWAY_READ_UNVERIFIED');
    return {...envelope(school),pointRead:true,records:result.record?{[body.id]:result.record}:{}};
   }
   const head=await liveSync.command(school,{command:'head'});
   if(head.schoolId!==school||head.liveProtocol!==1||!Number.isSafeInteger(head.cursor)||head.cursor<0)refuse(502,'LIVE_GATEWAY_HEAD_UNVERIFIED');
   const collectionHead=head.collections?.find(item=>item.collection===body.collection);
   if(!collectionHead||!Number.isSafeInteger(collectionHead.cursor)||collectionHead.cursor<0)refuse(502,'LIVE_GATEWAY_HEAD_UNVERIFIED');
   const extra=await reserved(school,body.collection,readDrive),collectionRevision=revision(body.collection,collectionHead.cursor)+extra.suffix;
   if(body.knownRevision===collectionRevision)return {...envelope(school),collectionRevision,records:{},unchanged:true};
   const found=Object.create(null);let after='',count=0,bytes=0;
   // Every page is pinned to one head, and hydration rechecks that head. Never
   // return a partial map or silently switch snapshot versions while paging.
   for(let pages=0;pages<=maxRecords;pages++){
    const page=await liveSync.replay(school,{command:'snapshot',collection:body.collection,at:head.cursor,after},readDrive);
    if(page.schoolId!==school||page.liveProtocol!==1||page.cursor!==head.cursor||!Array.isArray(page.records)||page.records.length>100)refuse(502,'LIVE_GATEWAY_SNAPSHOT_UNVERIFIED');
    let last=after;
    for(const entry of page.records){
     if(!entry||!validId(entry.id)||Buffer.compare(Buffer.from(entry.id),Buffer.from(last))<=0||Object.hasOwn(found,entry.id))refuse(502,'LIVE_GATEWAY_SNAPSHOT_UNVERIFIED');
     verifyRecord(school,entry.id,entry.record);last=entry.id;
     bytes+=Buffer.byteLength(JSON.stringify(entry));count++;
     if(count>maxRecords||bytes>maxBytes)refuse(413,'LIVE_GATEWAY_SNAPSHOT_TOO_LARGE');
     found[entry.id]=entry.record;
    }
    if(page.next!==(page.records.length?last:null))refuse(502,'LIVE_GATEWAY_SNAPSHOT_UNVERIFIED');
    if(page.next===null){
     const verified=await liveSync.command(school,{command:'head'});
     if(verified.schoolId!==school||verified.liveProtocol!==1||verified.cursor!==head.cursor)refuse(409,'LIVE_SNAPSHOT_CHANGED');
     const finalReserved=await reserved(school,body.collection,readDrive);if(finalReserved.suffix!==extra.suffix)refuse(409,'LIVE_SNAPSHOT_CHANGED');
     if(count+Object.keys(extra.records).length>maxRecords||bytes+Buffer.byteLength(JSON.stringify(extra.records))>maxBytes)refuse(413,'LIVE_GATEWAY_SNAPSHOT_TOO_LARGE');
     Object.assign(found,extra.records);
     return {...envelope(school),collectionRevision,records:found};
    }
    after=last;
   }
   refuse(413,'LIVE_GATEWAY_SNAPSHOT_TOO_LARGE');
  }
  if(!validId(body.id)||typeof body.operationId!=='string'||!/^[A-Za-z0-9_-]{16,100}$/.test(body.operationId)||typeof body.expectedRecordRevision!=='string'||body.expectedRecordRevision.length>100)refuse(400,'LIVE_OPERATION_INVALID');
  if(body.operation==='write'&&(!body.data||typeof body.data!=='object'||Array.isArray(body.data)||body.data.schoolId!==school))refuse(400,'LIVE_OPERATION_INVALID');
  if(typeof migration?.live!=='function')refuse(503,'LIVE_MIGRATION_NOT_ACTIVE');
  const patch=body.data?._syncFieldPatch;
  if(patch&&(body.operation!=='write'||patch.version!==1||!patch.set||typeof patch.set!=='object'||Array.isArray(patch.set)||!Array.isArray(patch.remove)||!patch.before||typeof patch.before!=='object'||Object.keys(body.data).some(k=>!['schoolId','_syncFieldPatch'].includes(k))||[...Object.keys(patch.set),...patch.remove].some(k=>['studentId','personId','mobileStableId','teacherId'].includes(k))))refuse(400,'LIVE_PATCH_INVALID');
  const request={command:'commit',collection:body.collection,id:body.id,operation:patch?'patch':body.operation,operationId:body.operationId,expectedRevision:body.expectedRecordRevision,...(body.operation==='write'?{data:patch?{schoolId:school,set:patch.set,remove:patch.remove}:body.data}:{}),...(body.createIntent!==undefined?{createIntent:body.createIntent}:{}),...(body.deleteEverywhereVersion===1?{deleteEverywhereVersion:1}:{}),...(body.cachedBaseline?{cachedBaseline:body.cachedBaseline}:{})};
  return migration.live(school,body.collection,async()=>{
   const result=await liveSync.commit(school,request,readDrive);
   if(result.liveProtocol!==1||result.schoolId!==school||result.cloudState!=='committed'||!['pending','verified'].includes(result.backupState)||result.operationId!==body.operationId||typeof result.recordRevision!=='string'||!result.recordRevision)refuse(502,'LIVE_GATEWAY_ACK_UNVERIFIED');
   let record=result.record;
   if(!record){
    const current=await liveSync.read(school,body.collection,body.id,readDrive);
    if(current.schoolId!==school||current.liveProtocol!==1||current.recordRevision!==result.recordRevision)refuse(409,'RECORD_REVISION_CONFLICT');
    record=current.record;
   }
   verifyRecord(school,body.id,record);
   if(record._syncRevision!==result.recordRevision||(!result.unchanged&&result.resolution!=='cloudRetained'&&record._syncOperationId!==body.operationId))refuse(502,'LIVE_GATEWAY_ACK_UNVERIFIED');
   // This acknowledges Cloudflare authority only. backupState remains pending
   // until the independent Drive delivery owner verifies the exact content.
   return {...result,...envelope(school),record};
  },request);
 }
 return {records,head};
}
module.exports={createLiveGateway};

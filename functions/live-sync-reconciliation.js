'use strict';
const {createHash}=require('node:crypto');
const {canonical}=require('./live-sync-canonical');
const SCHOOL=/^vs-[a-f0-9]{32}$/,HASH=/^[a-f0-9]{64}$/;
const hash=value=>createHash('sha256').update(canonical(value)).digest('hex');
const validId=value=>typeof value==='string'&&value.length>0&&value.length<=200&&!value.includes('/')&&value!=='.'&&value!=='..'&&!['__proto__','prototype','constructor'].includes(value);
const validOperation=value=>typeof value==='string'&&/^[A-Za-z0-9_-]{16,100}$/.test(value);
const syncMetadata=new Set(['_syncRevision','_syncOperationId','_syncRequestHash','_syncDeleted','_syncDeletedFileId','_syncFileCleanupComplete','_syncFieldRevisions']);
// Match VS_syncRequestShape in the signed Apps Script bundle exactly. The hash
// binds intent without retaining student data or another temporary payload copy.
function legacyRequestHash(request){
 const data={};if(request.operation==='write')for(const [key,value]of Object.entries(request.data||{}))if(!syncMetadata.has(key))data[key]=value;
 return hash({operation:request.operation,data});
}
function bindOperation(school,lane,request){
 if(!SCHOOL.test(school)||!request||!['legacy','live'].includes(lane)||!validId(request.id)||!validOperation(request.operationId)||typeof request.collection!=='string'||!/^[a-z][a-z0-9_]{0,99}$/.test(request.collection))return null;
 if(lane==='legacy'&&(request.action!=='managed_records'||request.syncProtocol!==2||!['write','delete'].includes(request.operation)))return null;
 if(lane==='live'&&(!['write','delete','patch'].includes(request.operation)||typeof request.expectedRevision!=='string'||request.expectedRevision.length>100))return null;
 const requestHash=lane==='legacy'?legacyRequestHash(request):hash({collection:request.collection,id:request.id,operation:request.operation,operationId:request.operationId,expectedRevision:request.expectedRevision,data:request.data??null,...(request.createIntent===true?{createIntent:true}:{})});
 return {version:1,schoolId:school,lane,collection:request.collection,id:request.id,operation:request.operation,operationId:request.operationId,requestHash};
}
function validBinding(binding,school,lane,collection){
 return binding?.version===1&&binding.schoolId===school&&binding.lane===lane&&binding.collection===collection&&validId(binding.id)&&validOperation(binding.operationId)&&HASH.test(binding.requestHash||'')&&['write','delete',...(lane==='live'?['patch']:[])].includes(binding.operation);
}
function liveProofMatches(proof,binding){
 const receipt=proof?.receipt;
 return proof?.liveProtocol===1&&proof.schoolId===binding.schoolId&&proof.operationId===binding.operationId&&proof.found===true&&proof.fingerprint===binding.requestHash&&receipt?.liveProtocol===1&&receipt.schoolId===binding.schoolId&&receipt.operationId===binding.operationId&&receipt.cloudState==='committed'&&['pending','verified'].includes(receipt.backupState)&&typeof receipt.recordRevision==='string'&&receipt.recordRevision.startsWith('live-')&&receipt.recordRevision.length>5&&Number.isSafeInteger(receipt.cursor)&&receipt.cursor>=0;
}
function driveProofMatches(proof,binding){
 const record=proof?.records?.[binding.id];
 return proof?.success===true&&proof.schoolId===binding.schoolId&&proof.syncProtocol===2&&proof.pointRead===true&&record?.schoolId===binding.schoolId&&(record.id===undefined||record.id===binding.id)&&record._syncOperationId===binding.operationId&&record._syncRequestHash===binding.requestHash&&typeof record._syncRevision==='string'&&record._syncRevision.length>0&&!/^(live-|cf-)/.test(record._syncRevision)&&(binding.operation==='delete'?record._syncDeleted===true:record._syncDeleted!==true);
}
function createLiveReconciliation({db,readLiveReceipt,readDrive,now=Date.now}){
 async function reconcile(school,{limit=25}={}){
  if(!SCHOOL.test(school)||!Number.isSafeInteger(limit)||limit<1||limit>100)throw Object.assign(Error('Invalid admission reconciliation scope'),{status:400,code:'LIVE_RECONCILIATION_SCOPE_INVALID'});
  const ref=db.doc('school_live_migrations/'+school),snapshot=(await ref.get()).data()||{};
  const candidates=['inflight','liveInflight'].flatMap(map=>Object.entries(snapshot[map]||{}).map(([token,marker])=>({map,token,marker}))).sort((a,b)=>(Number(a.marker.startedAt)||0)-(Number(b.marker.startedAt)||0));
  let cleared=0;const reasons={},proofs=new Map();
  const retain=reason=>{reasons[reason]=(reasons[reason]||0)+1;};
  for(const {map,token,marker}of candidates.slice(0,limit)){
   const lane=map==='liveInflight'?'live':'legacy',binding=marker.operationBinding;
   if(!validBinding(binding,school,lane,marker.collection)){retain('unbound');continue;}
   let verified=false;
   try{
    const proofKey=canonical(binding);
    // Several lost responses for one immutable operation need one verified
    // lookup. The cache lasts only this bounded reconciliation invocation.
    if(!proofs.has(proofKey))proofs.set(proofKey,(async()=>{
     if(lane==='live'&&typeof readLiveReceipt==='function')return liveProofMatches(await readLiveReceipt(school,binding.operationId),binding);
     if(lane==='legacy'&&typeof readDrive==='function')return driveProofMatches(await readDrive(school,{action:'managed_records',operation:'read',collection:binding.collection,id:binding.id,syncProtocol:2}),binding);
     return false;
    })());
    verified=await proofs.get(proofKey);
   }catch{retain('proof_unavailable');continue;}
   if(!verified){retain('proof_unverified');continue;}
   const removed=await db.runTransaction(async tx=>{
    const current=(await tx.get(ref)).data()||{},markers={...current[map]};
    // A proof for an old request can never clear a replacement marker, even
    // if a token was accidentally reused. Preserve concurrent state and maps.
    if(!markers[token]||canonical(markers[token])!==canonical(marker))return false;
    delete markers[token];tx.set(ref,{...current,[map]:markers});return true;
   });
   if(removed)cleared++;else retain('marker_changed');
  }
  return {success:true,schoolId:school,scanned:Math.min(limit,candidates.length),cleared,retained:Object.values(reasons).reduce((a,b)=>a+b,0),more:candidates.length>limit,reasons};
 }
 return {reconcile};
}
module.exports={bindOperation,legacyRequestHash,createLiveReconciliation};

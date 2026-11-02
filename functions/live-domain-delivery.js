'use strict';
const {createHash}=require('node:crypto');
const {canonical}=require('./live-sync-canonical');
const SCHOOL=/^vs-[a-f0-9]{32}$/;
const DOMAINS=Object.freeze({
 financial:new Set(['fee_settings','fee_ledger','fee_payments','teacher_salary']),
 attendance:new Set(['attendance_records','attendance_logs','teacher_attendance','teacher_schedules']),
 exams:new Set(['exams','exam_results','exam_center_results']),
});
const GC_COLLECTIONS=new Set(['students_directory','teachers_directory','attendance_logs','teacher_attendance','attendance_records','teacher_schedules','school_calendar','exam_results','teacher_salary','school_config','school_settings','fee_settings','fee_ledger','fee_payments','school_expenses','student_scan_index','scanner_devices','documents','backups','exams','exam_center_results']);
const canGcRecord=request=>request?.action==='managed_records'&&GC_COLLECTIONS.has(request.collection);
// A queued legacy child with an explicit stable student generation must not
// appear as an accepted proposal after the parent was retired on another PC.
// This pre-admission check supplements (never replaces) signed GS CAS and
// generation checks at final delivery time, including the deletion race.
const STUDENT_DEPENDENT=new Set(['fee_ledger','fee_payments','attendance_records','attendance_logs','exam_results','exam_center_results','documents','student_scan_index']);
const domainFor=collection=>Object.entries(DOMAINS).find(([,collections])=>collections.has(collection))?.[0]||null;
const refuse=(status,code)=>{throw Object.assign(Error('Domain delivery needs verification; saved work is retained.'),{status,code,publicMessage:true});};
const validId=id=>typeof id==='string'&&id.length>0&&id.length<=200&&!id.includes('/')&&!['.','..','__proto__','prototype','constructor'].includes(id);
const deliveryId=(school,request)=>createHash('sha256').update(JSON.stringify([school,request.action,[request.collection,request.id,request.operationId]])).digest('hex');
function validate(school,request,identityOnly=false,gc=false){
 if(!SCHOOL.test(school)||!request||request.action!=='managed_records'||!(gc?canGcRecord(request):domainFor(request.collection))||!['write','delete'].includes(request.operation)||request.syncProtocol!==2||!validId(request.id)||!/^[A-Za-z0-9_-]{16,100}$/.test(request.operationId||'')||typeof request.expectedRecordRevision!=='string'||request.expectedRecordRevision.length>100||/^(live-|cf-)/.test(request.expectedRecordRevision))refuse(400,'DOMAIN_OPERATION_INVALID');
 if(!identityOnly&&request.operation==='write'&&(!request.data||typeof request.data!=='object'||Array.isArray(request.data)||request.data.schoolId!==school))refuse(403,'DOMAIN_SCHOOL_MISMATCH');
 if(Buffer.byteLength(JSON.stringify(request))>256000)refuse(413,'DOMAIN_OPERATION_TOO_LARGE');
}
function domainPayloadHash(record){
 return createHash('sha256').update(canonical({deleted:record._syncDeleted===true,data:Object.fromEntries(Object.entries(record).filter(([key])=>key!=='id'&&!key.startsWith('_sync')))})).digest('hex');
}
function scrubDomainReceipt(school,result,request){
 validate(school,request,false,true);
 const record=result?.record;
 if(result?.success!==true||result.schoolId!==school||result.syncProtocol!==2||typeof result.recordRevision!=='string'||!result.recordRevision||/^(live-|cf-)/.test(result.recordRevision)||!record||record.schoolId!==school||record.id!==undefined&&record.id!==request.id||record._syncRevision!==result.recordRevision||record._syncOperationId!==request.operationId||(record._syncDeleted===true)!==(request.operation==='delete'))refuse(502,'DOMAIN_CANONICAL_UNVERIFIED');
 const patch=request.data?._syncFieldPatch;
 const deleted={schoolId:school,_syncDeleted:true};
 if(request.operation==='delete'&&request.collection==='documents'&&record.documentRevision!==undefined){
  if(typeof record.documentRevision!=='string'||record.documentRevision!==(request.expectedRevision||''))refuse(502,'DOMAIN_CONTENT_UNVERIFIED');
  deleted.documentRevision=record.documentRevision;
 }
 if(request.operation==='write'&&patch){
  if(patch.version!==1||!patch.set||typeof patch.set!=='object'||Array.isArray(patch.set)||!Array.isArray(patch.remove)||Object.entries(patch.set).some(([key,value])=>!Object.hasOwn(record,key)||canonical(record[key])!==canonical(value))||patch.remove.some(key=>Object.hasOwn(record,key)))refuse(502,'DOMAIN_CONTENT_UNVERIFIED');
 }else if(domainPayloadHash(record)!==domainPayloadHash(request.operation==='delete'?deleted:request.data))refuse(502,'DOMAIN_CONTENT_UNVERIFIED');
 return {...result,record:null,recordSource:{version:1,collection:request.collection,id:request.id,recordRevision:result.recordRevision,operationId:request.operationId,payloadHash:domainPayloadHash(record)}};
}
async function hydrateDomainReceipt(school,result,readDrive){
 const source=result?.recordSource;
 if(!source)return result;
 if(!SCHOOL.test(school)||result.success!==true||result.schoolId!==school||result.syncProtocol!==2||source.version!==1||!GC_COLLECTIONS.has(source.collection)||!validId(source.id)||typeof source.recordRevision!=='string'||!source.recordRevision||source.recordRevision!==result.recordRevision||/^(live-|cf-)/.test(source.recordRevision)||!/^[A-Za-z0-9_-]{16,100}$/.test(source.operationId||'')||!/^[a-f0-9]{64}$/.test(source.payloadHash||''))refuse(502,'DOMAIN_SOURCE_UNVERIFIED');
 if(result.record){
  const record=result.record;
  if(record.schoolId!==school||record.id!==undefined&&record.id!==source.id||record._syncRevision!==source.recordRevision||record._syncOperationId!==source.operationId||domainPayloadHash(record)!==source.payloadHash)refuse(502,'DOMAIN_CANONICAL_UNVERIFIED');
  return result;
 }
 if(typeof readDrive!=='function')refuse(503,'DOMAIN_CANONICAL_READ_REQUIRED');
 const reply=await readDrive({action:'managed_records',operation:'read',collection:source.collection,id:source.id,syncProtocol:2});
 const record=reply?.records?.[source.id];
 if(reply?.success!==true||reply.schoolId!==school||reply.syncProtocol!==2||reply.pointRead!==true||!record||record.schoolId!==school||record.id!==undefined&&record.id!==source.id)refuse(502,'DOMAIN_CANONICAL_UNVERIFIED');
 if(record._syncRevision!==source.recordRevision||record._syncOperationId!==source.operationId)refuse(409,'RECORD_REVISION_CONFLICT');
 if(domainPayloadHash(record)!==source.payloadHash)refuse(502,'DOMAIN_CANONICAL_UNVERIFIED');
 return {...result,record};
}
function createLiveDomainDelivery({edgeDelivery,edge,emitHint=async()=>{},assertStudentDependency}){
 async function submit(school,request,readDrive){
  validate(school,request);
  // Exact student-owned document and scan-index writes obey the same retired\n  // generation fence as fee and attendance writes. Shared/teacher records do not.\n  if(request.operation==='write'&&STUDENT_DEPENDENT.has(request.collection)&&
      request.data?.role!=='teacher'&&request.data?.ownerRole!=='teacher'){
   const data=request.data,generation=data?.personId;
   const studentId=data?.studentDocId||data?.studentDocumentId||data?.studentId;
   if(typeof generation==='string'&&/^p-[a-f0-9]{32,64}$/.test(generation)&&validId(studentId)){
    if(typeof assertStudentDependency!=='function')refuse(503,'DOMAIN_STUDENT_DEPENDENCY_UNVERIFIED');
    await assertStudentDependency(school,studentId,generation);
   }
  }
  // Keep the existing immutable delivery identity, scheduler barriers, exact
  // CAS and real GS result owner. No second financial/attendance writer exists.
  const receipt=await edgeDelivery.record(school,request,readDrive);
  if(receipt.schoolId!==school||receipt.success!==true)refuse(502,'DOMAIN_RECEIPT_UNVERIFIED');
  if(receipt.driveState==='pending'){
   const id=deliveryId(school,request);
   if(receipt.edgeDeliveryVersion!==1||receipt.delivery?.lane!=='records'||receipt.delivery?.id!==id||receipt.recordRevision!==undefined)refuse(502,'DOMAIN_RECEIPT_UNVERIFIED');
   // Metadata only: the wakeup itself is never record truth. A failed optional
   // wakeup cannot turn an accepted durable operation into a fake failure.
   try{await emitHint(school,{domainDeliveryVersion:1,domain:domainFor(request.collection),collection:request.collection,id:request.id,operationId:request.operationId,delivery:{lane:'records',id}});}catch{}
  }else if(receipt.driveState!=='verified'||receipt.syncProtocol!==2||typeof receipt.recordRevision!=='string'||!receipt.recordRevision||/^(live-|cf-)/.test(receipt.recordRevision))refuse(502,'DOMAIN_RECEIPT_UNVERIFIED');
  return receipt;
 }
 async function projection(school,descriptor,readDrive){
  if(!SCHOOL.test(school)||descriptor?.lane!=='records'||!/^[a-f0-9]{64}$/.test(descriptor.id||''))refuse(400,'DOMAIN_DELIVERY_INVALID');
  // Private RPC, reachable only after the broker's school-admin authorization.
  // The Worker must bind the returned original request to this school/receipt.
  const stored=await edge.rpc(school,'records',{command:'projection',id:descriptor.id});
  if(stored?.id!==descriptor.id||!['pending','retry','processing','completed','needsAttention'].includes(stored.state))refuse(502,'DOMAIN_PROJECTION_UNVERIFIED');
  const request=stored.request||stored.identity;
  if(!request)refuse(503,'DOMAIN_PROJECTION_SOURCE_UNAVAILABLE');
  validate(school,request,!['pending','retry','processing'].includes(stored.state));
  if(deliveryId(school,request)!==descriptor.id)refuse(502,'DOMAIN_PROJECTION_UNVERIFIED');
  const identity={success:true,schoolId:school,domainDeliveryVersion:1,domain:domainFor(request.collection),collection:request.collection,id:request.id,operationId:request.operationId,delivery:{lane:'records',id:descriptor.id}};
  if(['pending','retry','processing'].includes(stored.state)){
   // Intent is visible instantly across devices, but cannot enter canonical
   // business tables, baselines, fee totals, presence counts or document jobs.
   return {...identity,disposition:'pending',authoritative:false,driveState:'pending',proposal:{operation:request.operation,expectedRecordRevision:request.expectedRecordRevision,...(request.operation==='write'?{data:request.data}:{})}};
  }
  if(stored.state==='needsAttention')return {...identity,disposition:'review',authoritative:false,driveState:'review',proposal:null};
  const receipt=await hydrateDomainReceipt(school,await edgeDelivery.status(school,'records',descriptor.id),readDrive);
  if(receipt?.success!==true||receipt.schoolId!==school||receipt.syncProtocol!==2||receipt.driveState!=='verified'||typeof receipt.recordRevision!=='string'||!receipt.recordRevision||/^(live-|cf-)/.test(receipt.recordRevision))refuse(502,'DOMAIN_RECEIPT_UNVERIFIED');
  let record=receipt.record;
  if(!record){
   if(typeof readDrive!=='function')refuse(503,'DOMAIN_CANONICAL_READ_REQUIRED');
   const verified=await readDrive({action:'managed_records',operation:'read',collection:request.collection,id:request.id,syncProtocol:2});
   if(verified?.success!==true||verified.schoolId!==school||verified.syncProtocol!==2||verified.pointRead!==true)refuse(502,'DOMAIN_CANONICAL_UNVERIFIED');
   record=verified.records?.[request.id];
  }
  if(!record||record.schoolId!==school||record.id!==undefined&&record.id!==request.id||typeof record._syncRevision!=='string'||/^(live-|cf-)/.test(record._syncRevision))refuse(502,'DOMAIN_CANONICAL_UNVERIFIED');
  if(record._syncRevision!==receipt.recordRevision||record._syncOperationId!==request.operationId)return {...identity,disposition:'superseded',authoritative:false,driveState:'verified',record:null,reconcileRequired:true};
  if((record._syncDeleted===true)!==(request.operation==='delete'))refuse(502,'DOMAIN_CANONICAL_UNVERIFIED');
  return {...identity,disposition:'verified',authoritative:true,driveState:'verified',recordRevision:receipt.recordRevision,record};
 }
 return {handles:request=>request?.action==='managed_records'&&domainFor(request.collection)!==null,submit,projection};
}
module.exports={createLiveDomainDelivery,domainFor,deliveryId,domainPayloadHash,scrubDomainReceipt,hydrateDomainReceipt,canGcRecord};

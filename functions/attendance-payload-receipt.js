'use strict';
const {createHash}=require('node:crypto');
const {canonical}=require('./live-sync-canonical');
const SCHOOL=/^vs-[a-f0-9]{32}$/,HASH=/^[a-f0-9]{64}$/;
const hash=value=>createHash('sha256').update(canonical(value)).digest('hex');
const validDocument=id=>typeof id==='string'&&id.length>0&&id.length<=200&&!id.includes('/')&&id!=='.'&&id!=='..';
const refuse=()=>{throw Object.assign(Error('Verified attendance handoff required before payload removal'),{status:409,code:'ATTENDANCE_PAYLOAD_RECEIPT_UNVERIFIED'});};
// Called only inside the trusted signed-GS delivery owner. The decrypted
// request must come from THIS exact row's AES-GCM envelope in the Cloudflare store. Neither
// a mobile caller nor HTTP200 alone may supply verifiedAck.
function buildAttendancePayloadReceipt({schoolId,operationId,row,request,verifiedAck}){
 if(!SCHOOL.test(schoolId)||!HASH.test(operationId||'')||!row||row.schoolId!==schoolId||row.operationId!==operationId||![undefined,'cloudflare-v1'].includes(row.payloadTransport)||!['pending','retry','processing'].includes(row.state)||!/^\d{4}-\d{2}-\d{2}$/.test(row.day||'')||!['entry','exit'].includes(row.mode))refuse();
 if(!verifiedAck||verifiedAck.success!==true||verifiedAck.schoolId!==schoolId||verifiedAck.operationId!==operationId)refuse();
 const envelope=row.payload;
 if(!envelope||typeof envelope!=='object'||Array.isArray(envelope)||typeof envelope.iv!=='string'||typeof envelope.body!=='string'||Buffer.from(envelope.body,'base64').length>20000)refuse();
 if(row.payloadTransport==='cloudflare-v1'){
  if(Buffer.from(envelope.iv,'base64').length!==12||Buffer.from(envelope.body,'base64').length<17)refuse();
 }else{
  // Broker-originated entries in the same Cloudflare store use protect(),
  // which stores IV/tag as hex separately from its ciphertext. The caller
  // decrypts them with unprotect(), never with the Cloudflare EDGE_KEY.
  if(!/^[a-f0-9]{24}$/i.test(envelope.iv)||typeof envelope.tag!=='string'||!/^[a-f0-9]{32}$/i.test(envelope.tag)||Buffer.from(envelope.body,'base64').length<1)refuse();
 }
 if(!request||request.action!=='mobile_mark_attendance'||!['student','teacher'].includes(request.role)||!validDocument(request.personId)||(request.schoolId!==undefined&&request.schoolId!==schoolId)||(request.projectId!==undefined&&request.projectId!==schoolId)||(request.mode==='exit'?'exit':'entry')!==row.mode)refuse();
 if(request.clientCapturedAt!==undefined&&(!Number.isSafeInteger(request.clientCapturedAt)||request.clientCapturedAt<=0||new Date(request.clientCapturedAt+19800000).toISOString().slice(0,10)!==row.day))refuse();
 // The operation ID uses the grant's stable personId, whereas the request uses
 // documentId. They can differ across student generations; never hash documentId
 // in an attempt to reconstruct the operation ID or authorize a different owner.
 return {version:1,schoolId,operationId,role:request.role,documentId:request.personId,day:row.day,mode:row.mode,requestHash:hash(request),payloadHash:hash(envelope),driveVerified:true};
}
function attendancePayloadFinishValues({schoolId,operationId,row,request,verifiedAck,values}){
 if(!values||values.state!=='completed')return values;
 if(!Number.isSafeInteger(values.completedAt)||values.completedAt<=0)refuse();
 return {...values,attendanceOwnerReceipt:buildAttendancePayloadReceipt({schoolId,operationId,row,request,verifiedAck}),attendancePayloadPurged:true};
}
// Use only for the completed/purged branch of mobile status. Existing active
// rows continue through the original decrypt+permit checks. The active permit
// is still validated by the broker before reaching this ownership check.
function attendanceReceiptOwns({schoolId,operationId,row,permit}){
 const receipt=row?.attendanceOwnerReceipt;
 return SCHOOL.test(schoolId)&&HASH.test(operationId||'')&&row?.schoolId===schoolId&&row.operationId===operationId&&row.state==='completed'&&row.attendancePayloadPurged===true&&receipt?.version===1&&receipt.schoolId===schoolId&&receipt.operationId===operationId&&receipt.driveVerified===true&&HASH.test(receipt.requestHash||'')&&HASH.test(receipt.payloadHash||'')&&['student','teacher'].includes(receipt.role)&&validDocument(receipt.documentId)&&receipt.role===permit?.role&&receipt.documentId===permit.documentId&&/^\d{4}-\d{2}-\d{2}$/.test(receipt.day||'')&&['entry','exit'].includes(receipt.mode);
}
module.exports={buildAttendancePayloadReceipt,attendancePayloadFinishValues,attendanceReceiptOwns};

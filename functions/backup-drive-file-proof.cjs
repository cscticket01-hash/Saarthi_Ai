'use strict';
// Read-only independent original-file proof. No mutation and no optimistic
// success from an R2 stage, Edge completion or a provider URL alone.
const {createHash}=require('node:crypto');
const SCHOOL=/^vs-[a-f0-9]{32}$/;
const HASH=/^[a-f0-9]{64}$/;
const ID=/^[A-Za-z0-9_-]{1,200}$/;
const MAX_BYTES=20*1024*1024;
const fail=code=>{const e=new Error(code);e.code=code;throw e;};
async function verifyOwnerDriveFile({schoolId,operationId,owner,auditEntry,readFile}){
 if(!SCHOOL.test(String(schoolId))||!HASH.test(String(operationId))||
    typeof readFile!=='function')fail('DRIVE_PROOF_INVALID_SCOPE');
 if(!owner||owner.id!==operationId||
    owner.state!=='completed')fail('DRIVE_OWNER_NOT_COMPLETED');
 const original=owner.manifest,ack=owner.response?.result;
 if(!original||typeof original!=='object'||!HASH.test(original.sha256)||
    !Number.isSafeInteger(original.sizeBytes)||original.sizeBytes<=0||
    original.sizeBytes>MAX_BYTES||typeof original.mime!=='string'||
    original.mime.length>100||
    !ack||ack.success!==true||ack.schoolId!==schoolId||
    ack.uploadResumableVersion!==1||ack.committed!==true||
    ack.uploadKey!==original.uploadKey||
    ack.sha256!==original.sha256||
    ack.sizeBytes!==original.sizeBytes||
    ack.offset!==original.sizeBytes||
    !ID.test(String(ack.fileId||'')))
  fail('DRIVE_OWNER_ACK_UNVERIFIED');
 // Re-read the actual current owner Drive bytes with the already verified
 // signed per-school Apps Script connection. Do not trust ACK metadata alone.
 const result=await readFile(ack.fileId);
 if(!result||result.success!==true||result.schoolId!==schoolId||
    result.mime!==original.mime||
    typeof result.base64!=='string'||
    result.base64.length!==Math.ceil(original.sizeBytes/3)*4||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(result.base64))
  fail('DRIVE_SIGNED_READBACK_MISSING');
 const bytes=Buffer.from(result.base64,'base64');
 if(bytes.length!==original.sizeBytes||
    bytes.toString('base64')!==result.base64||
    createHash('sha256').update(bytes).digest('hex')!==original.sha256)
  fail('DRIVE_ORIGINAL_BYTES_MISMATCH');
 const verifiedAt=auditEntry?.id===operationId&&
    auditEntry.state==='completed'&&auditEntry.driveOwnerReceiptPresent===true&&
    Number.isSafeInteger(auditEntry.verifiedAt)&&auditEntry.verifiedAt>0
      ?auditEntry.verifiedAt:null;
 return {version:1,schoolId,originalId:operationId,verified:true,
    readbackSource:'signed-school-drive',driveVerified:true,
    fileId:ack.fileId,mime:original.mime,
    fileBytes:original.sizeBytes,fileSha256:original.sha256,
    verifiedAt,originalVerifiedAtUnknown:verifiedAt===null,
    coverage:'one-file-owner-only',partial:true};
}
module.exports={verifyOwnerDriveFile};

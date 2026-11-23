'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {createHash}=require('node:crypto');
const {verifyOwnerDriveFile}=require('../backup-drive-file-proof.cjs');
const school='vs-'+'a'.repeat(32),id='b'.repeat(64);
const bytes=Buffer.from('immutable provider file data','utf8');
const sha=createHash('sha256').update(bytes).digest('hex');
const owner={
 id,state:'completed',
 manifest:{uploadKey:'upload-key-one',sha256:sha,sizeBytes:bytes.length,mime:'image/png'},
 response:{result:{success:true,schoolId:school,uploadResumableVersion:1,
   committed:true,uploadKey:'upload-key-one',sha256:sha,sizeBytes:bytes.length,
   offset:bytes.length,fileId:'originalGoogleFileId1'}}
};
const readFile=async()=>({success:true,schoolId:school,mime:'image/png',base64:bytes.toString('base64')});
const page={id,state:'completed',driveOwnerReceiptPresent:true,verifiedAt:Date.UTC(2026,10,19,8)};
test('exact authenticated school Drive bytes and retained owner time verify file',async()=>{
 const r=await verifyOwnerDriveFile({schoolId:school,operationId:id,owner,auditEntry:page,readFile});
 assert.equal(r.verified,true);assert.equal(r.driveVerified,true);
 assert.equal(r.fileSha256,sha);assert.equal(r.fileBytes,bytes.length);
 assert.equal(r.verifiedAt,page.verifiedAt);
 assert.equal(r.coverage,'one-file-owner-only');assert.equal(r.partial,true);
});
test('unknown original verification timestamp never becomes newly verified hourly event',async()=>{
 const r=await verifyOwnerDriveFile({schoolId:school,operationId:id,owner,readFile});
 assert.equal(r.verified,true);assert.equal(r.verifiedAt,null);
 assert.equal(r.originalVerifiedAtUnknown,true);
});
test('Cloudflare acceptance or fake ACK is not a Drive proof',async()=>{
 await assert.rejects(verifyOwnerDriveFile({schoolId:school,operationId:id,
    owner:{...owner,state:'pending'},readFile}),/DRIVE_OWNER_NOT_COMPLETED/);
 await assert.rejects(verifyOwnerDriveFile({schoolId:school,operationId:id,
    owner:{...owner,response:{result:{...owner.response.result,committed:false}}},readFile}),
    /DRIVE_OWNER_ACK_UNVERIFIED/);
});
test('cross-school receipt and wrong immutable file bytes must fail',async()=>{
 await assert.rejects(verifyOwnerDriveFile({schoolId:'vs-'+'c'.repeat(32),
    operationId:id,owner,readFile}),/DRIVE_OWNER_ACK_UNVERIFIED/);
 await assert.rejects(verifyOwnerDriveFile({schoolId:school,operationId:id,
    owner,readFile:async()=>({...await readFile(),
      base64:Buffer.alloc(bytes.length,0).toString('base64')})}),
    /DRIVE_ORIGINAL_BYTES_MISMATCH/);
});
test('wrong provider MIME, missing file ID, malformed base64 cannot be certified',async()=>{
 await assert.rejects(verifyOwnerDriveFile({schoolId:school,operationId:id,
    owner,readFile:async()=>({...await readFile(),mime:'application/pdf'})}),
    /DRIVE_SIGNED_READBACK_MISSING/);
 await assert.rejects(verifyOwnerDriveFile({schoolId:school,operationId:id,
    owner:{...owner,response:{result:{...owner.response.result,fileId:''}}},readFile}),
    /DRIVE_OWNER_ACK_UNVERIFIED/);
 await assert.rejects(verifyOwnerDriveFile({schoolId:school,operationId:id,
    owner,readFile:async()=>({...await readFile(),base64:'-not-base64-'})}),
    /DRIVE_SIGNED_READBACK_MISSING/);
});

'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {reconcileBackupCoverage}=require('../backup-audit-evidence.cjs');
const school='vs-'+'1'.repeat(32),sha='a'.repeat(64),now=Date.UTC(2026,10,19,9,15);
const base={schoolId:school,operationId:'operation_test_001',originalId:'operation_test_001',originalSha256:sha,source:'records'};
const sources=(rows=[],omit='')=>async(s,src,hourEnd)=>src===omit?{complete:false,rows:[]}:
  {complete:true,coversHistory:true,closedThrough:hourEnd,rows:src==='records'?rows:[]};
const proof=(row={})=>async(s,original)=>({readbackSource:'signed-school-drive',schoolId:s,
  originalId:original.originalId,originalSha256:original.originalSha256,
  providerReceiptId:'google_receipt_001',driveVerified:true,
  verifiedAt:now-25*60*1000,...row});
test('all owner sources and exact signed Drive readback certify one closed-hour count',async()=>{
 const r=await reconcileBackupCoverage({schoolId:school,now,
   sourceInventory:sources([base]),readOwnerProof:proof()});
 assert.equal(r.complete,true);assert.equal(r.verifiedCount,1);
 assert.equal(r.breakdown.records,1);
 assert.equal(r.hourStart,Date.UTC(2026,10,19,8));
});
test('missing legacy source prevents complete coverage',async()=>{
 const r=await reconcileBackupCoverage({schoolId:school,now,
   sourceInventory:sources([base],'legacy-local-outbox'),readOwnerProof:proof()});
 assert.equal(r.complete,false);assert.deepEqual(r.missingSources,['legacy-local-outbox']);
});
test('Cloudflare acceptance alone cannot certify Drive backup',async()=>{
 const r=await reconcileBackupCoverage({schoolId:school,now,
   sourceInventory:sources([base]),readOwnerProof:async()=>({cloudflareAccepted:true})});
 assert.equal(r.complete,false);assert.equal(r.verifiedCount,0);
});
test('modern and legacy copies of one original count once',async()=>{
 const inv=async(s,src,hourEnd)=>({complete:true,coversHistory:true,closedThrough:hourEnd,
   rows:src==='records'?[base]:src==='legacy-records'?[{...base,source:src}]:[]});
 const r=await reconcileBackupCoverage({schoolId:school,now,
   sourceInventory:inv,readOwnerProof:proof()});
 assert.equal(r.originalCount,1);assert.equal(r.verifiedCount,1);
});
test('conflicting immutable hashes fail closed',async()=>{
 const inv=async(s,src,hourEnd)=>({complete:true,coversHistory:true,closedThrough:hourEnd,
   rows:src==='records'?[base]:src==='legacy-records'?[{...base,source:src,originalSha256:'b'.repeat(64)}]:[]});
 const r=await reconcileBackupCoverage({schoolId:school,now,
   sourceInventory:inv,readOwnerProof:proof()});
 assert.equal(r.complete,false);assert.equal(r.conflictCount,1);
});
test('wrong signed owner/hash and file size never count as verified',async()=>{
 const wrong=await reconcileBackupCoverage({schoolId:school,now,
   sourceInventory:sources([base]),readOwnerProof:proof({originalSha256:'b'.repeat(64)})});
 assert.equal(wrong.complete,false);assert.equal(wrong.verifiedCount,0);
 const file={...base,source:'files',fileBytes:42};
 const inv=async(s,src,end)=>({complete:true,coversHistory:true,closedThrough:end,
   rows:src==='files'?[file]:[]});
 const mismatch=await reconcileBackupCoverage({schoolId:school,now,
   sourceInventory:inv,readOwnerProof:proof({fileBytes:43,fileSha256:sha})});
 assert.equal(mismatch.complete,false);assert.equal(mismatch.conflictCount,1);
});
test('open-hour completions and unknown historical timestamps do not certify previous hour',async()=>{
 const after=await reconcileBackupCoverage({schoolId:school,now,
   sourceInventory:sources([base]),readOwnerProof:proof({verifiedAt:now-1000})});
 assert.equal(after.verifiedCount,0);
 const unknown=await reconcileBackupCoverage({schoolId:school,now,
   sourceInventory:sources([base]),readOwnerProof:proof({originalVerifiedAtUnknown:true})});
 assert.equal(unknown.complete,false);
});
test('missing owner adapter or inventory is not treated as a zero-count success',async()=>{
 await assert.rejects(reconcileBackupCoverage({schoolId:school,now,
   sourceInventory:sources([base])}),/owner inventory and readback/);
 const r=await reconcileBackupCoverage({schoolId:school,now,
   sourceInventory:async()=>({complete:true,rows:[]}),readOwnerProof:proof()});
 assert.equal(r.complete,false);assert.equal(r.missingSourceCount,10);
});

test('cross-source duplicate must not turn a file into a record-only Drive success',async()=>{
 const inv=async(_,src,hourEnd)=>({complete:true,coversHistory:true,closedThrough:hourEnd,
   rows:src==='records'?[base]:src==='files'?[{...base,source:'files',fileBytes:42}]:[]});
 const noBytes=await reconcileBackupCoverage({schoolId:school,now,sourceInventory:inv,
   readOwnerProof:proof()});
 assert.equal(noBytes.complete,false);
 assert.equal(noBytes.verifiedCount,0);
 assert.deepEqual(noBytes.conflicts,['operation_test_001:original-file-proof-missing']);
 const signedBytes=await reconcileBackupCoverage({schoolId:school,now,sourceInventory:inv,
   readOwnerProof:proof({fileSha256:sha,fileBytes:42,driveFileId:'google_file_001'})});
 assert.equal(signedBytes.complete,true);
 assert.equal(signedBytes.verifiedCount,1);
 assert.equal(signedBytes.breakdown.files,1);
 assert.equal(signedBytes.breakdown.records,0,
   'A single immutable original is counted once with its stronger file proof');
});
test('disagreeing modern and legacy file manifests cannot count as verified',async()=>{
 const modern={...base,source:'files',fileBytes:42};
 const legacy={...modern,source:'legacy-files',fileBytes:43};
 const inv=async(_,src,hourEnd)=>({complete:true,coversHistory:true,closedThrough:hourEnd,
   rows:src==='files'?[modern]:src==='legacy-files'?[legacy]:[]});
 const r=await reconcileBackupCoverage({schoolId:school,now,sourceInventory:inv,
   readOwnerProof:proof({fileSha256:sha,fileBytes:42,driveFileId:'google_file_001'})});
 assert.equal(r.complete,false);
 assert.equal(r.verifiedCount,0);
 assert.deepEqual(r.conflicts,['operation_test_001:file-manifest-size-conflict']);
});
test('immutable hash conflicts cannot contribute to certified hourly count',async()=>{
 const inv=async(_,src,hourEnd)=>({complete:true,coversHistory:true,closedThrough:hourEnd,
   rows:src==='records'?[base]:src==='legacy-records'?
     [{...base,source:'legacy-records',originalSha256:'b'.repeat(64)}]:[]});
 const r=await reconcileBackupCoverage({schoolId:school,now,sourceInventory:inv,
   readOwnerProof:proof()});
 assert.equal(r.complete,false);
 assert.equal(r.conflictCount,1);
 assert.equal(r.verifiedCount,0);
 assert.equal(r.verifiedOriginals,0);
});

test('a future provider timestamp cannot certify an original',async()=>{
 const result=await reconcileBackupCoverage({schoolId:school,now,
  sourceInventory:sources([base]),readOwnerProof:proof({verifiedAt:now+1})});
 assert.equal(result.complete,false);
 assert.equal(result.verifiedOriginals,0);
 assert.equal(result.unverifiedCount,1);
});

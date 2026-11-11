'use strict';
const assert=require('node:assert/strict'),{createHash}=require('node:crypto');
const hash=value=>createHash('sha256').update(JSON.stringify(value)).digest('hex');
// Point-read the original operation only. Iterator tokens and school file IDs
// stay in memory; reports contain counts, never cursor/record contents.
function observeDeletePlan(read,schoolId,onProgress=()=>{}) {
 let identity;
 return async(request,attempt)=>{
  const reply=await read(request.collection,request.id);
  assert.equal(reply.success,true);assert.equal(reply.schoolId,schoolId);
  assert.equal(reply.syncProtocol,2);assert.equal(reply.pointRead,true);
  const row=reply.records?.[request.id];
  assert.equal(row?.schoolId,schoolId);
  assert.ok(row.id===undefined||row.id===request.id);
  if(row._syncDeleted!==true){
   assert.equal(row.mobileStableId,request.deletedStudentGeneration);
   assert.equal(row._syncRevision,request.expectedRecordRevision);
   assert.equal(identity,undefined,'A deleted original must never become live again');
   onProgress({attempt,phase:'awaiting_original_tombstone'});
   return hash(['original_live',row._syncRevision]);
  }
  assert.equal(row._syncOperationId,request.operationId);
  assert.equal(row._syncDeletedOwner,request.deletedStudentGeneration);
  const plan=row._syncErasePlan;
  assert.equal(plan?.version,1);assert.ok(Array.isArray(plan.targets)&&Array.isArray(plan.files));
  const root=plan.targets.find(t=>t.collection===request.collection&&t.id===request.id);
  assert.equal(root?.generation,request.deletedStudentGeneration);
  assert.equal(root.revision,row._syncRevision);
  assert.equal(root.sourceRevision,request.expectedRecordRevision);
  const signature=hash([row._syncRevision,plan.targets,plan.files,plan.retainedShared||[]]);
  if(identity)assert.equal(signature,identity,'Original deletion inventory changed');
  identity=signature;
  for(const [cursor,total] of [[plan.cursor,plan.targets.length],[plan.fileCursor,plan.files.length]])
   assert.ok(Number.isSafeInteger(cursor)&&cursor>=0&&cursor<=total);
  if(plan.archiveIds){assert.ok(Array.isArray(plan.archiveIds));
   assert.ok(Number.isSafeInteger(plan.archiveCursor)&&plan.archiveCursor>=0&&plan.archiveCursor<=plan.archiveIds.length);}
  onProgress({attempt,phase:plan.complete?'complete':plan.archivesComplete?'final_receipt':plan.archiveIds?'archive_redaction':'archive_inventory',
   targetsProcessed:plan.cursor,targetsTotal:plan.targets.length,
   filesProcessed:plan.fileCursor,filesTotal:plan.files.length,
   archiveCandidates:plan.archiveIds?.length??plan.archiveScan?.ids?.length??null,
   archivesProcessed:plan.archiveCursor??null,scanDepth:plan.archiveScan?.stack?.length??null});
  return hash([signature,plan.cursor,plan.fileCursor,plan.archiveIds,plan.archiveCursor,
   plan.archiveScan,plan.archivesComplete,plan.complete]);
 };
}
module.exports={observeDeletePlan};

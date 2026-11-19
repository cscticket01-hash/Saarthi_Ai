'use strict';

/* Fail-closed reconciliation: requires complete durable owner inventory
 * AND independent authenticated Google Drive readbacks. Never call with
 * user-supplied receipts or R2 acceptance in place of signed provider proof.
 */
const SCHOOL=/^vs-[a-f0-9]{32}$/;
const SHA=/^[a-f0-9]{64}$/;
const OP=/^[A-Za-z0-9_-]{8,150}$/;
const SOURCES=Object.freeze([
  'records','files','notices','attendance','live',
  'legacy-records','legacy-files','legacy-notices','legacy-attendance',
  'legacy-local-outbox'
]);
const KINDS=Object.freeze(['records','files','notices','attendance','live']);
const kindOf=s=>s.includes('files')?'files':s.includes('notices')?'notices':
  s.includes('attendance')?'attendance':s==='live'?'live':'records';
const stamp=x=>Number.isSafeInteger(x)&&x>0;
function checkedOriginal(row,school,source){
  if(!row||typeof row!=='object'||row.schoolId!==school||row.source!==source||
    typeof row.operationId!=='string'||!OP.test(row.operationId)||
    typeof row.originalSha256!=='string'||!SHA.test(row.originalSha256)||
    (row.originalId!==undefined&&
      (typeof row.originalId!=='string'||!OP.test(row.originalId))))
    throw Error('Original inventory identity invalid');
  return {...row,originalId:row.originalId||row.operationId};
}
async function reconcileBackupCoverage({schoolId,now=Date.now(),
  sourceInventory,readOwnerProof,sources=SOURCES}){
  if(!SCHOOL.test(String(schoolId))||!stamp(now)||
    typeof sourceInventory!=='function'||typeof readOwnerProof!=='function'||
    !Array.isArray(sources)||sources.length!==SOURCES.length||
    new Set(sources).size!==SOURCES.length||SOURCES.some(x=>!sources.includes(x)))
    throw Error('Complete school-scoped owner inventory and readback required');
  const hourEnd=Math.floor(now/3600000)*3600000,hourStart=hourEnd-3600000;
  const missingSources=[],conflicts=[],unverified=[],undated=[];
  const originals=new Map();
  for(const source of SOURCES){
    let inventory;
    try{inventory=await sourceInventory(schoolId,source,hourEnd);}
    catch{missingSources.push(source);continue;}
    if(!inventory||inventory.complete!==true||inventory.coversHistory!==true||
      !stamp(inventory.closedThrough)||inventory.closedThrough<hourEnd||
      !Array.isArray(inventory.rows)||inventory.rows.length>250000){
      missingSources.push(source);continue;
    }
    for(const raw of inventory.rows){
      let row;
      try{row=checkedOriginal(raw,schoolId,source);}
      catch{conflicts.push(source+':invalid-original');continue;}
      const previous=originals.get(row.originalId);
      if(previous){
        if(previous.originalSha256!==row.originalSha256)
          conflicts.push(row.originalId+':immutable-hash-conflict');
        else previous.sources.push(source);
      }else originals.set(row.originalId,{...row,sources:[source]});
    }
  }
  const breakdown=Object.fromEntries(KINDS.map(x=>[x,0]));
  let verifiedOriginals=0;
  for(const [originalId,row] of originals){
    let receipt;
    try{receipt=await readOwnerProof(schoolId,row);}
    catch{unverified.push(originalId);continue;}
    if(!receipt||receipt.readbackSource!=='signed-school-drive'||
      receipt.schoolId!==schoolId||receipt.originalId!==originalId||
      receipt.originalSha256!==row.originalSha256||
      receipt.driveVerified!==true||
      typeof receipt.providerReceiptId!=='string'||
      !OP.test(receipt.providerReceiptId)||!stamp(receipt.verifiedAt)){
      unverified.push(originalId);continue;
    }
    if(receipt.fileSha256!==undefined&&
      receipt.fileSha256!==row.originalSha256){
      conflicts.push(originalId+':file-hash-mismatch');continue;
    }
    if(receipt.fileBytes!==undefined&&
      (!Number.isSafeInteger(receipt.fileBytes)||receipt.fileBytes<0||
       row.fileBytes!==receipt.fileBytes)){
      conflicts.push(originalId+':file-size-mismatch');continue;
    }
    verifiedOriginals++;
    if(receipt.verifiedAt>=hourStart&&receipt.verifiedAt<hourEnd)
      breakdown[kindOf(row.source)]++;
    if(receipt.originalVerifiedAtUnknown===true)undated.push(originalId);
  }
  const verifiedCount=Object.values(breakdown).reduce((a,b)=>a+b,0);
  const complete=missingSources.length===0&&conflicts.length===0&&
    unverified.length===0&&undated.length===0;
  return {version:1,scope:'all-original-owner-drive-readbacks',
    schoolId,hourStart,hourEnd,verifiedCount,breakdown,
    originalCount:originals.size,verifiedOriginals,
    missingSourceCount:missingSources.length,
    unverifiedCount:unverified.length,conflictCount:conflicts.length,
    unknownTimestampCount:undated.length,
    missingSources,unverifiedOriginalIds:unverified,conflicts,
    coverage:complete?'complete':'partial',complete,partial:!complete,
    authority:'requires-authenticated-school-owner-adapters'};
}
module.exports={SOURCES,KINDS,reconcileBackupCoverage};

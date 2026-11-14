import {checkedR2Admission,verifiedR2PurgeDue,r2MayPurge,R2_SCHOOL_DATA_BYTES,R2_SYSTEM_RESERVE_BYTES,R2_TOTAL_BYTES} from './r2-capacity.mjs';
import {demand} from './protocol';
type StageRow={key:string,school:string,lane:string,receipt_id:string,bytes:number,sha256:string,category:string,state:string,accepted_at:number,accepted_final:number,verified_at:number,purge_due:number};
const schoolPattern=/^vs-[a-f0-9]{32}$/;
const hex=/^[a-f0-9]{64}$/;
const lanePattern=/^(?:records|notices|live|attendance-[a-f0-9]{2}|file-[a-f0-9]{64})$/;
const fail=(message:string,status=503):never=>{throw Object.assign(Error(message),{status});};
function init(storage:DurableObjectStorage){
 storage.sql.exec("CREATE TABLE IF NOT EXISTS r2_staged (key TEXT PRIMARY KEY,school TEXT NOT NULL,lane TEXT NOT NULL,receipt_id TEXT NOT NULL,bytes INTEGER NOT NULL,sha256 TEXT NOT NULL,category TEXT NOT NULL,state TEXT NOT NULL,accepted_at INTEGER NOT NULL,verified_at INTEGER NOT NULL DEFAULT 0,purge_due INTEGER NOT NULL DEFAULT 0)");
 if(!storage.sql.exec<{name:string}>('PRAGMA table_info(r2_staged)').toArray().some(c=>c.name==='accepted_final'))
  storage.sql.exec("ALTER TABLE r2_staged ADD COLUMN accepted_final INTEGER NOT NULL DEFAULT 0");
 storage.sql.exec("CREATE INDEX IF NOT EXISTS r2_verified_cleanup ON r2_staged(state,purge_due)");
 storage.sql.exec("CREATE INDEX IF NOT EXISTS r2_original_receipt ON r2_staged(school,lane,receipt_id)");
}
function usage(storage:DurableObjectStorage){
 const rows=storage.sql.exec<{category:string;used:number}>("SELECT category,coalesce(sum(bytes),0) AS used FROM r2_staged WHERE state!='purged' GROUP BY category").toArray();
 return {schoolBytes:rows.find(r=>r.category==='school')?.used??0,systemBytes:rows.find(r=>r.category==='system')?.used??0};
}
export function r2BudgetStatus(storage:DurableObjectStorage){
 init(storage);const u=usage(storage);
 const states=storage.sql.exec<{state:string;bytes:number;objects:number}>("SELECT state,sum(bytes) AS bytes,count(*) AS objects FROM r2_staged GROUP BY state").toArray();
 return {...u,reservedBytes:states.find(r=>r.state==='reserved')?.bytes??0,storedBytes:states.find(r=>r.state==='stored')?.bytes??0,verifiedBytes:states.find(r=>r.state==='verified')?.bytes??0,purgedObjects:states.find(r=>r.state==='purged')?.objects??0,schoolLimitBytes:R2_SCHOOL_DATA_BYTES,reservedSystemBytes:R2_SYSTEM_RESERVE_BYTES,totalLimitBytes:R2_TOTAL_BYTES,storageClass:'Standard',scope:'private-R2-staging-bucket'};
}
// This object must be called only from an authenticated school-lane Worker
// Durable Object, never through a public R2 endpoint.
async function stageR2Unlocked(storage:DurableObjectStorage,bucket:R2Bucket|undefined,
 school:string,lane:string,receiptId:string,segment:number,buffer:ArrayBuffer,category:'school'|'system'='school'){
 demand(schoolPattern.test(school)&&lanePattern.test(lane)&&hex.test(receiptId)&&
  Number.isSafeInteger(segment)&&segment>=0&&segment<=20*1024*1024&&
  buffer instanceof ArrayBuffer&&buffer.byteLength>0&&buffer.byteLength<=512*1024,
  'Invalid private R2 staging identity',400);
 if(!bucket)throw Object.assign(Error('Private R2 bucket unavailable'),{status:503});
 init(storage);
 const key='saarthi-v1/'+school+'/'+lane+'/'+receiptId+'/'+segment;
 const bytes=new Uint8Array(buffer),sha256=[...new Uint8Array(await crypto.subtle.digest('SHA-256',buffer))].map(x=>x.toString(16).padStart(2,'0')).join('');
 let existing=storage.sql.exec<StageRow>('SELECT * FROM r2_staged WHERE key=?',key).toArray()[0];
 if(existing){
  demand(existing.school===school&&existing.lane===lane&&existing.receipt_id===receiptId&&
   existing.sha256===sha256&&existing.bytes===bytes.byteLength&&existing.category===category,
   'Immutable R2 operation ID conflict',409);
  if(['stored','verified','purged'].includes(existing.state))return {accepted:true,receiptId,lane,bytes:bytes.byteLength,alreadyStaged:true,driveVerified:existing.state!=='stored'};
 }else{
  storage.transactionSync(()=>{
   // This global, single Durable Object serializes all staging admissions.
   // Reservations count even when an R2 write failed or is being retried.
   const check=usage(storage),status=checkedR2Admission(check.schoolBytes,check.systemBytes,bytes.byteLength,category);
   if(!status.accepted)fail('School R2 capacity reached; local work retained',507);
   storage.sql.exec("INSERT INTO r2_staged(key,school,lane,receipt_id,bytes,sha256,category,state,accepted_at) VALUES(?,?,?,?,?,?,?,'reserved',?)",
    key,school,lane,receiptId,bytes.byteLength,sha256,category,Date.now());
  });
  existing=storage.sql.exec<StageRow>('SELECT * FROM r2_staged WHERE key=?',key).toArray()[0];
 }
 // R2 put precedes a user-visible Cloudflare ACK. If this fails, the DO's
 // durable reservation remains. On identical retry it rechecks/reputs R2.
 try{
  const current=await bucket.head(key);
  if(!current||current.size!==bytes.byteLength||current.customMetadata?.sha256!==sha256){
   const stored=await bucket.put(key,buffer,{customMetadata:{schema:'saarthi-r2-stage-v1',sha256}});
   if(!stored||stored.size!==bytes.byteLength)fail('R2 staging did not confirm bytes');
  }
  storage.sql.exec("UPDATE r2_staged SET state='stored',accepted_at=? WHERE key=? AND state='reserved'",Date.now(),key);
 }catch(error){fail('Private R2 staging unavailable; local work retained');}
 return {accepted:true,receiptId,lane,bytes:bytes.byteLength,alreadyStaged:existing.state!=='reserved',driveVerified:false};
}
const objectLocks=new WeakMap<DurableObjectStorage,Map<string,Promise<unknown>>>();
async function withObjectLock<T>(storage:DurableObjectStorage,key:string,work:()=>Promise<T>):Promise<T>{
 let locks=objectLocks.get(storage);if(!locks){locks=new Map();objectLocks.set(storage,locks);}
 const prior=locks.get(key)||Promise.resolve();
 const pending=prior.catch(()=>{}).then(work);locks.set(key,pending);
 try{return await pending;}finally{if(locks.get(key)===pending)locks.delete(key);}
}
export async function stageR2(storage:DurableObjectStorage,bucket:R2Bucket|undefined,
 school:string,lane:string,receiptId:string,segment:number,buffer:ArrayBuffer,category:'school'|'system'='school'){
 const key='saarthi-v1/'+school+'/'+lane+'/'+receiptId+'/'+segment;
 return withObjectLock(storage,key,()=>stageR2Unlocked(storage,bucket,school,lane,receiptId,segment,buffer,category));
}
// Seal retention at the original owner's durable acceptance, not at an early
// failed reservation or the first part of a long-running multipart upload.
export function acceptR2Original(storage:DurableObjectStorage,school:string,lane:string,receiptId:string){
 demand(schoolPattern.test(school)&&lanePattern.test(lane)&&hex.test(receiptId),'Invalid original acceptance',400);
 init(storage);const at=Date.now();
 storage.transactionSync(()=>{
  const rows=storage.sql.exec<StageRow>("SELECT * FROM r2_staged WHERE school=? AND lane=? AND receipt_id=? AND accepted_final=0 AND state IN ('stored','verified')",school,lane,receiptId).toArray();
  for(const row of rows){const verified=row.verified_at?Math.max(row.verified_at,at):0;
   storage.sql.exec('UPDATE r2_staged SET accepted_at=?,accepted_final=1,verified_at=?,purge_due=? WHERE key=?',
     at,verified,verified?verifiedR2PurgeDue(at,verified):0,row.key);
  }
 });
 return {accepted:true};
}
export async function markR2Verified(storage:DurableObjectStorage,school:string,lane:string,receiptId:string,verifiedAt=Date.now()){
 demand(schoolPattern.test(school)&&lanePattern.test(lane)&&hex.test(receiptId)&&
  Number.isSafeInteger(verifiedAt)&&verifiedAt>0,'Invalid original receipt',400);
 init(storage);
 const rows=storage.sql.exec<StageRow>("SELECT * FROM r2_staged WHERE school=? AND lane=? AND receipt_id=? AND state IN ('stored','verified')",school,lane,receiptId).toArray();
 let due:number|null=null;
 storage.transactionSync(()=>{
  for(const row of rows){
   const at=row.verified_at||verifiedAt;
   const expire=row.accepted_final===1?verifiedR2PurgeDue(row.accepted_at,at):0;
   storage.sql.exec("UPDATE r2_staged SET state='verified',verified_at=?,purge_due=? WHERE key=? AND state IN ('stored','verified')",at,expire,row.key);
   if(expire>0)due=due===null?expire:Math.min(due,expire);
  }
 });
 return {verifiedObjects:rows.length,nextCleanupAt:due};
}
export async function sweepR2Verified(storage:DurableObjectStorage,bucket:R2Bucket|undefined,now=Date.now()){
 if(!bucket)throw Object.assign(Error('Private R2 bucket unavailable'),{status:503});
 init(storage);const rows=storage.sql.exec<StageRow>("SELECT * FROM r2_staged WHERE state='verified' AND purge_due>0 AND purge_due<=? ORDER BY purge_due LIMIT 100",now).toArray();
 let removed=0,cleanupFailed=false;
 for(const row of rows){
  if(!r2MayPurge(row,now))continue;
  try{
   await withObjectLock(storage,row.key,async()=>{
   await bucket.delete(row.key);
   storage.sql.exec("UPDATE r2_staged SET state='purged' WHERE key=? AND state='verified' AND verified_at=? AND purge_due=?",row.key,row.verified_at,row.purge_due);
   });
   removed++;
  }catch{cleanupFailed=true;break;} // Keep accounted bytes and retry. Never purge unverified.
 }
 const next=storage.sql.exec<{due:number}>("SELECT min(purge_due) AS due FROM r2_staged WHERE state='verified' AND purge_due>0").toArray()[0]?.due??null;
 return {removed,nextCleanupAt:cleanupFailed?now+60_000:next,more:!cleanupFailed&&rows.length===100,cleanupFailed};
}

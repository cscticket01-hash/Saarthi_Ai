import {demand,digest,operationPattern} from './protocol';
import {Buffer} from 'node:buffer';
type Json=Record<string,unknown>;
type Row={seq:number;id:string;fingerprint:string;payload:string;state:string;due:number;claim:string;claim_until:number;response:string|null;resources:string|null;created:number;verified_at:number;purge_due:number};
export const verifiedPayloadTtlMs=24*60*60*1000;
export const verifiedPayloadExpired=(state:string,verifiedAt:number,purgeDue:number,now:number)=>state==='completed'&&verifiedAt>0&&purgeDue>=verifiedAt+verifiedPayloadTtlMs&&now>=purgeDue;
export const spoolLane=(lane:string)=>lane==='records'||/^file-[a-f0-9]{64}$/.test(lane);
const collections=new Set(['students_directory','teachers_directory','attendance_logs','teacher_attendance','attendance_records','teacher_schedules','school_calendar','exam_results','teacher_salary','school_config','school_settings','fee_settings','fee_ledger','fee_payments','school_expenses','student_scan_index','scanner_devices','documents','backups','exams','exam_center_results']);
export function canonical(value:unknown):string {
 if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';
 if(value&&typeof value==='object')return '{'+Object.keys(value).sort().map(k=>JSON.stringify(k)+':'+canonical((value as Json)[k])).join(',')+'}';
 return JSON.stringify(value);
}
export function initSpool(storage:DurableObjectStorage){
 storage.sql.exec("CREATE TABLE IF NOT EXISTS edge_ops(seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT UNIQUE NOT NULL,fingerprint TEXT NOT NULL,payload TEXT NOT NULL,state TEXT NOT NULL,due INTEGER NOT NULL,claim TEXT NOT NULL DEFAULT '',claim_until INTEGER NOT NULL DEFAULT 0,response TEXT)");
 storage.sql.exec('CREATE TABLE IF NOT EXISTS edge_chunks(offset INTEGER PRIMARY KEY,size INTEGER NOT NULL,sha256 TEXT NOT NULL,body BLOB NOT NULL)');
 const columns=storage.sql.exec<{name:string}>('PRAGMA table_info(edge_ops)').toArray();
 if(!columns.some(c=>c.name==='resources'))storage.sql.exec('ALTER TABLE edge_ops ADD COLUMN resources TEXT');
 if(!columns.some(c=>c.name==='created'))storage.sql.exec('ALTER TABLE edge_ops ADD COLUMN created INTEGER NOT NULL DEFAULT 0');
 if(!columns.some(c=>c.name==='verified_at'))storage.sql.exec('ALTER TABLE edge_ops ADD COLUMN verified_at INTEGER NOT NULL DEFAULT 0');
 if(!columns.some(c=>c.name==='purge_due'))storage.sql.exec('ALTER TABLE edge_ops ADD COLUMN purge_due INTEGER NOT NULL DEFAULT 0');
}
// Unknown/legacy, person, document and financial dependencies stay barriers.
// Only these independent record types may overtake a retry of another key.
const independent=new Set(['school_expenses','attendance_records','attendance_logs','teacher_attendance']);
const recordIdentity=(request:Json):Json=>request.action==='managed_records_batch'?{action:request.action,operations:(request.operations as Json[]).map(recordIdentity)}:Object.fromEntries(['action','collection','id','operation','syncProtocol','operationId','expectedRecordRevision'].filter(key=>request[key]!==undefined).map(key=>[key,request[key]]));
function resources(request:Json):string {
 const ops=request.action==='managed_records_batch'?request.operations as Json[]:[request];
 if(ops.some(op=>!independent.has(String(op.collection))))return '*';
 return JSON.stringify([...new Set(ops.map(op=>JSON.stringify([op.collection,op.id])))].sort());
}
function schedule(storage:DurableObjectStorage,limit:number,at:number):{ids:string[];due:number|null}{
 const rows=storage.sql.exec<Pick<Row,'id'|'state'|'due'|'claim_until'|'resources'>>("SELECT id,state,due,claim_until,resources FROM edge_ops WHERE state IN ('pending','retry','processing') ORDER BY seq LIMIT 512").toArray();
 const blocked=new Set<string>(),result:string[]=[];let due:number|null=null;
 for(const row of rows){
  const keys=row.resources&&row.resources!=='*'?JSON.parse(row.resources) as string[]:['*'];
  const barrier=keys.includes('*');
  const availableAt=Math.max(row.due,row.state==='processing'?row.claim_until:0);
  if((!barrier||blocked.size===0)&&!keys.some(k=>blocked.has(k))){
   due=due===null?availableAt:Math.min(due,availableAt);
   if(availableAt<=at){result.push(row.id);if(result.length>=limit)break;}
  }
  if(barrier)break;
  for(const key of keys)blocked.add(key);
 }
 return {ids:result,due};
}
function recordRequest(request:Json,school:string){
 demand(request.action==='managed_records'&&collections.has(String(request.collection))&&['write','delete'].includes(String(request.operation))&&request.syncProtocol===2&&typeof request.id==='string'&&request.id.length>0&&request.id.length<=200&&!request.id.includes('/')&&!['.','..','__proto__','prototype','constructor'].includes(request.id)&&/^[A-Za-z0-9_-]{16,100}$/.test(String(request.operationId))&&typeof request.expectedRecordRevision==='string'&&request.expectedRecordRevision.length<=100,'Invalid versioned record');
 if(request.operation==='write')demand(request.data&&typeof request.data==='object'&&(request.data as Json).schoolId===school,'Foreign record',403);
}
export async function spoolCommand(storage:DurableObjectStorage,school:string,lane:string,b:Json,wake:(at:number)=>Promise<void>):Promise<unknown>{
 const get=(id:string)=>storage.sql.exec<Row>('SELECT * FROM edge_ops WHERE id=?',id).toArray()[0];
 const action=String(b.command||''),id=String(b.id||'');
 async function seal(id:string){const latest=get(id);const manifest=JSON.parse(latest.payload) as Json;
  if(manifest.received===manifest.sizeBytes&&latest.state==='receiving'&&Number(manifest.verifyingUntil||0)<=Date.now()){
   storage.sql.exec('UPDATE edge_ops SET payload=? WHERE id=?',JSON.stringify({...manifest,verifyingUntil:Date.now()+30000}),id);
   const stream=new crypto.DigestStream('SHA-256'),writer=stream.getWriter();let received=0;
   for(const chunk of storage.sql.exec<{offset:number;size:number;body:ArrayBuffer}>('SELECT offset,size,body FROM edge_chunks ORDER BY offset')){
    demand(chunk.offset===received,'File chunk gap',409);await writer.write(new Uint8Array(chunk.body));received+=chunk.size;
   }
   await writer.close();const actual=[...new Uint8Array(await stream.digest)].map(x=>x.toString(16).padStart(2,'0')).join('');demand(received===manifest.sizeBytes&&actual===manifest.sha256,'File hash mismatch',409);
   if(get(id).state==='receiving')storage.sql.exec("UPDATE edge_ops SET state='pending',due=? WHERE id=?",Date.now(),id);
   await wake(Date.now()+250);
  }

 }
 const receipt=(row:Row)=>({id:row.id,state:row.state,due:row.due,response:row.response?JSON.parse(row.response):null});
 if(action==='expireVerified'){
  // This cleanup runs only from an authenticated existing school-lane alarm;
  // a stale unverified request can stay queued past 24h without data loss.
  return storage.transactionSync(()=>{
   const eligible=storage.sql.exec<Row>("SELECT * FROM edge_ops WHERE state='completed' AND verified_at>0 AND purge_due>0 AND purge_due<=? AND (payload!='' OR ?=1) ORDER BY seq LIMIT 200",Date.now(),lane.startsWith('file-')?1:0).toArray();
   let cleared=0;
   for(const row of eligible){
    if(!verifiedPayloadExpired(row.state,row.verified_at,row.purge_due,Date.now()))continue;
    if(lane.startsWith('file-')){
     storage.sql.exec("UPDATE edge_chunks SET body=x''");
     // Keep the immutable manifest/Drive identity for a safe idempotent retry.
     storage.sql.exec("UPDATE edge_ops SET purge_due=0 WHERE id=? AND state='completed'",row.id);
    }else{
     storage.sql.exec("UPDATE edge_ops SET payload='',purge_due=0 WHERE id=? AND state='completed' AND verified_at=?",row.id,row.verified_at);
    }
    cleared++;
   }
   const next=storage.sql.exec<{due:number}>("SELECT min(purge_due) AS due FROM edge_ops WHERE state='completed' AND verified_at>0 AND purge_due>0").toArray()[0]?.due;
   return {expired:cleared,nextCleanupAt:next??null};
  });
 }
 if(action==='retention'){
  const next=storage.sql.exec<{due:number}>("SELECT min(purge_due) AS due FROM edge_ops WHERE state='completed' AND verified_at>0 AND purge_due>0").toArray()[0]?.due;
  return {retentionHours:24,nextCleanupAt:next??null};
 }
 if(action==='capabilities')return {edgeDeliveryVersion:1,recordSchedulingVersion:1,maxFileBytes:20*1024*1024,chunkBytes:512*1024};
 if(action==='stats')return {...storage.sql.exec<{pending:number;due:number}>("SELECT count(*) AS pending,min(due) AS due FROM edge_ops WHERE state IN ('pending','retry','processing')").toArray()[0],...(lane==='records'?{due:schedule(storage,512,Date.now()).due}:{}),...storage.sql.exec<{needsAttention:number}>("SELECT count(*) AS needsAttention FROM edge_ops WHERE state='needsAttention'").toArray()[0]};
 if(action==='pending'){
  demand(b.limit===1||lane==='records'&&b.limit===2);
  if(lane==='records')return schedule(storage,Number(b.limit),Date.now()).ids.map(get);
  const row=storage.sql.exec<Row>("SELECT * FROM edge_ops WHERE state IN ('pending','retry','processing') ORDER BY seq LIMIT 1").toArray()[0];return row&&row.due<=Date.now()?[row]:[];
 }
 if(action==='enqueue'){
  demand(lane==='records'&&operationPattern.test(id)&&b.request&&typeof b.request==='object');const request=b.request as Json;demand(JSON.stringify(request).length<=300000,'Record request too large',413);
  if(request.action==='managed_records_batch'){
   demand(Array.isArray(request.operations)&&request.operations.length>0&&request.operations.length<=10);
   const ids=new Set();for(const op of request.operations as Json[]){recordRequest(op,school);demand(!ids.has(op.operationId));ids.add(op.operationId);}
  }else recordRequest(request,school);
  const identity=request.action==='managed_records_batch'?(request.operations as Json[]).map(op=>[op.collection,op.id,op.operationId]):[request.collection,request.id,request.operationId];
  demand(await digest(JSON.stringify([school,request.action,identity]))===id,'Operation identity mismatch');
  const fingerprint=await digest(canonical(request));const old=get(id);
  if(old){demand(old.fingerprint===fingerprint,'Sync operation ID conflict',409);if(['pending','retry','processing'].includes(old.state))await wake(Math.max(Date.now()+250,old.due));return receipt(old);}
  const count=storage.sql.exec<{n:number}>("SELECT count(*) AS n FROM edge_ops WHERE state!='completed'").toArray()[0].n;demand(count<512,'School delivery backlog full; local work retained',503);
  const at=Date.now();storage.sql.exec("INSERT INTO edge_ops(id,fingerprint,payload,state,due,resources,created) VALUES(?,?,?,'pending',?,?,?)",id,fingerprint,JSON.stringify(request),at,resources(request),at);await wake(at+250);return receipt(get(id));
 }
 if(action==='putSmall'){
  // Atomically stage a small photo and its SHA-256 proof in one Durable Object
  // command. This is a Cloudflare ACK, never a verified Google Drive ACK.
  demand(lane.startsWith('file-')&&operationPattern.test(id)&&lane==='file-'+id&&b.manifest&&typeof b.manifest==='object');
  const m=b.manifest as Json;
  demand(typeof m.uploadKey==='string'&&/^[A-Za-z0-9_-]{1,150}$/.test(m.uploadKey)&&await digest(JSON.stringify([school,m.uploadKey]))===id&&typeof m.sha256==='string'&&operationPattern.test(m.sha256)&&Number.isSafeInteger(m.sizeBytes)&&Number(m.sizeBytes)>0&&Number(m.sizeBytes)<=256*1024&&typeof m.name==='string'&&m.name.length>0&&m.name.length<=200&&typeof m.mime==='string'&&/^[-\w.+]+\/[-\w.+]+$/.test(m.mime)&&!m.mime.startsWith('application/vnd.google-apps.'),'Invalid small file manifest');
  demand(typeof b.base64==='string'&&b.base64.length>0&&b.base64.length<=349528&&/^[A-Za-z0-9+/]*={0,2}$/.test(b.base64),'Invalid small file encoding');
  const bytes=new Uint8Array(Buffer.from(b.base64 as string,'base64'));
  demand(bytes.length===m.sizeBytes&&Buffer.from(bytes).toString('base64')===b.base64,'Small file byte length mismatch');
  const actual=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
  demand(actual===m.sha256,'Small file hash mismatch',409);
  const fingerprint=await digest(canonical(m)),old=get(id);
  if(old){
   demand(old.fingerprint===fingerprint,'Sync operation ID conflict',409);
   demand(old.state!=='receiving','Resumable upload must keep its existing chunk owner',409);
   if(['pending','retry','processing'].includes(old.state))await wake(Math.max(Date.now()+250,old.due));
   return {...receipt(old),manifest:JSON.parse(old.payload)};
  }
  const at=Date.now(),manifest=JSON.stringify({...m,received:bytes.length,driveOffset:0});
  storage.transactionSync(()=>{
   storage.sql.exec("INSERT INTO edge_ops(id,fingerprint,payload,state,due,created) VALUES(?,?,?,'pending',?,?)",id,fingerprint,manifest,at,at);
   storage.sql.exec('INSERT INTO edge_chunks(offset,size,sha256,body) VALUES(?,?,?,?)',0,bytes.length,actual,bytes.buffer);
  });
  await wake(at+250);
  return {...receipt(get(id)),manifest:JSON.parse(get(id).payload)};
 }
 if(action==='begin'){
  demand(lane.startsWith('file-')&&operationPattern.test(id)&&lane==='file-'+id&&b.manifest&&typeof b.manifest==='object');const m=b.manifest as Json;
  demand(typeof m.uploadKey==='string'&&/^[A-Za-z0-9_-]{1,150}$/.test(m.uploadKey)&&await digest(JSON.stringify([school,m.uploadKey]))===id&&typeof m.sha256==='string'&&operationPattern.test(m.sha256)&&Number.isSafeInteger(m.sizeBytes)&&Number(m.sizeBytes)>0&&Number(m.sizeBytes)<=20*1024*1024&&typeof m.name==='string'&&m.name.length>0&&m.name.length<=200&&typeof m.mime==='string'&&/^[-\w.+]+\/[-\w.+]+$/.test(m.mime)&&!m.mime.startsWith('application/vnd.google-apps.'),'Invalid file manifest');
  const fingerprint=await digest(canonical(m)),old=get(id);if(old){demand(old.fingerprint===fingerprint,'Sync operation ID conflict',409);if(['pending','retry','processing'].includes(old.state))await wake(Math.max(Date.now()+250,old.due));return {...receipt(old),manifest:JSON.parse(old.payload)};}
  storage.sql.exec("INSERT INTO edge_ops(id,fingerprint,payload,state,due) VALUES(?,?,?,'receiving',?)",id,fingerprint,JSON.stringify({...m,received:0,driveOffset:0}),Number.MAX_SAFE_INTEGER);return {...receipt(get(id)),manifest:JSON.parse(get(id).payload)};
 }
 demand(operationPattern.test(id),'Invalid receipt ID');const row=get(id);demand(row,'Delivery receipt unavailable',404);
 if(action==='status'){if(lane.startsWith('file-'))await seal(id);const current=get(id);return {...receipt(current),...(lane.startsWith('file-')?{manifest:JSON.parse(current.payload)}:{})};}
 if(action==='bundleProof'){
  // The existing file Durable Object is the only authority for its bytes.
  // This signed internal proof never claims a Google Drive ACK.
  demand(lane==='file-'+id,'File proof requires the original file owner',400);
  await seal(id);
  const current=get(id),manifest=JSON.parse(current.payload) as Json;
  demand(['pending','retry','processing','completed'].includes(current.state),'Staged file is not durable',412);
  const size=Number(manifest.sizeBytes);
  // PDF proof can also certify a <=150 KiB TEST marksheet. ID/photo limits
  // remain independently enforced by the verified-media bundle preflight.
  const mediaMax=manifest.mime==='application/pdf'?150*1024:
    ['image/jpeg','image/png','image/webp'].includes(String(manifest.mime))?40*1024:0;
  demand(Number.isSafeInteger(size)&&size>0&&size<=mediaMax&&manifest.received===size&&
    typeof manifest.sha256==='string'&&operationPattern.test(manifest.sha256)&&
    typeof manifest.uploadKey==='string'&&
    await digest(JSON.stringify([school,manifest.uploadKey]))===id,'Staged file manifest incomplete',412);
  // Drive identity is independently signed, scoped and durable even after
  // the 24h verified-only byte purge. Archive-only proof may survive a purge;
  // cloud staging proof MUST NOT survive without its original bytes.
  const result=current.response?((JSON.parse(current.response) as Json).result as Json):null;
  const driveVerified=current.state==='completed'&&current.verified_at>0&&
    result?.success===true&&result.schoolId===school&&
    result.uploadResumableVersion===1&&result.uploadKey===manifest.uploadKey&&
    result.sha256===manifest.sha256&&result.sizeBytes===size&&
    result.committed===true&&result.offset===size&&
    typeof result.fileId==='string'&&/^[A-Za-z0-9_-]{1,200}$/.test(result.fileId);
  const chunks=storage.sql.exec<{offset:number;size:number;body:ArrayBuffer}>(
    'SELECT offset,size,body FROM edge_chunks ORDER BY offset').toArray();
  const purged=chunks.length===1&&chunks[0].offset===0&&
    chunks[0].size===size&&chunks[0].body.byteLength===0&&
    current.purge_due===0&&current.verified_at>0;
  if(purged){
   demand(b.requireDrive===true&&driveVerified,
     'Temporary Cloudflare bytes expired; signed Drive proof required',412);
   return {version:1,schoolId:school,id,uploadKey:manifest.uploadKey,
     sha256:manifest.sha256,sizeBytes:size,mime:manifest.mime,staged:false,
     driveVerified:true,fileId:result!.fileId};
  }
  demand(chunks.length===1&&chunks[0].offset===0&&chunks[0].size===size&&
    chunks[0].body.byteLength===size,'Staged file bytes unavailable',412);
  const bytes=new Uint8Array(chunks[0].body);
  const actual=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))]
    .map(x=>x.toString(16).padStart(2,'0')).join('');
  demand(actual===manifest.sha256,'Staged file SHA-256 mismatch',409);
  if(manifest.mime==='application/pdf'){
    demand(bytes.length>=16&&[0x25,0x50,0x44,0x46,0x2d].every((v,i)=>bytes[i]===v)&&
      Buffer.from(bytes.subarray(Math.max(0,bytes.length-2048))).toString('latin1').includes('%%EOF'),
      'Staged ID PDF is incomplete',412);
  }else if(manifest.mime==='image/jpeg'){
    demand(size>=6&&bytes[0]===0xff&&bytes[1]===0xd8&&bytes[2]===0xff&&
      bytes[size-2]===0xff&&bytes[size-1]===0xd9,'Staged JPEG is incomplete',412);
  }else if(manifest.mime==='image/png'){
    demand(size>=20&&[137,80,78,71,13,10,26,10].every((v,i)=>bytes[i]===v)&&
      [73,69,78,68,174,66,96,130].every((v,i)=>bytes[size-8+i]===v),
      'Staged PNG is incomplete',412);
  }else if(manifest.mime==='image/webp'){
    demand(size>=20&&Buffer.from(bytes.subarray(0,4)).toString('ascii')==='RIFF'&&
      Buffer.from(bytes.subarray(8,12)).toString('ascii')==='WEBP'&&
      new DataView(bytes.buffer,bytes.byteOffset,bytes.byteLength).getUint32(4,true)+8===size,
      'Staged WebP is incomplete',412);
  }else demand(false,'Unsupported atomic bundle media type',412);
  // No "completed" label alone can stand in for a verified Drive receipt.
  if(b.requireDrive===true)demand(driveVerified,'Google Drive verified media receipt required',412);
  return {version:1,schoolId:school,id,uploadKey:manifest.uploadKey,
    sha256:manifest.sha256,sizeBytes:size,mime:manifest.mime,staged:true,
    driveVerified, ...(driveVerified?{fileId:result!.fileId}: {})};
 }
 if(action==='projection'){
  demand(lane==='records','Record projection unavailable',400);
  const saved=row.response?JSON.parse(row.response):{};
  return {id:row.id,state:row.state,due:row.due,authoritative:false,...(['pending','retry','processing'].includes(row.state)?{request:JSON.parse(row.payload)}:{identity:saved.identity||(row.payload?recordIdentity(JSON.parse(row.payload)):null)})};
 }
 if(action==='part'){
  demand(lane==='file-'+id&&Number.isSafeInteger(b.offset)&&Number(b.offset)>=0&&typeof b.base64==='string'&&b.base64.length>0&&b.base64.length<=699052&&/^[A-Za-z0-9+/]*={0,2}$/.test(b.base64)&&typeof b.chunkSha256==='string'&&operationPattern.test(b.chunkSha256));
  const bytes=new Uint8Array(Buffer.from(b.base64,'base64'));demand(bytes.length>0&&bytes.length<=512*1024&&Buffer.from(bytes).toString('base64')===b.base64);const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');demand(hash===b.chunkSha256,'Chunk hash mismatch',409);
  const m=JSON.parse(get(id).payload) as Json;const offset=Number(b.offset);demand(offset+bytes.length<=Number(m.sizeBytes)&&(offset+bytes.length===m.sizeBytes||bytes.length%(256*1024)===0));
  const prior=storage.sql.exec<{sha256:string;size:number}>('SELECT sha256,size FROM edge_chunks WHERE offset=?',offset).toArray()[0];
  if(prior)demand(prior.sha256===hash&&prior.size===bytes.length,'Chunk replay conflict',409);
  else {
   demand(row.state==='receiving'&&offset===m.received,'Upload offset conflict',409);
   storage.transactionSync(()=>{storage.sql.exec('INSERT INTO edge_chunks(offset,size,sha256,body) VALUES(?,?,?,?)',offset,bytes.length,hash,bytes.buffer);storage.sql.exec('UPDATE edge_ops SET payload=? WHERE id=?',JSON.stringify({...m,received:offset+bytes.length}),id);});
  }
  const latest=get(id),manifest=JSON.parse(latest.payload) as Json;
  await seal(id);
  return {...receipt(get(id)),manifest:JSON.parse(get(id).payload)};
 }
 if(action==='readPart'){
  demand(lane==='file-'+id&&Number.isSafeInteger(b.offset));const manifest=JSON.parse(row.payload) as Json;const offset=Number(b.offset);
  demand(offset>=0&&offset<Number(manifest.sizeBytes));const end=Math.min(Number(manifest.sizeBytes),offset+512*1024);const bytes=new Uint8Array(end-offset);let copied=0;
  for(const chunk of storage.sql.exec<{offset:number;size:number;body:ArrayBuffer}>('SELECT offset,size,body FROM edge_chunks WHERE offset+size>? AND offset<? ORDER BY offset',offset,end)){
   demand(chunk.body.byteLength===chunk.size,'Staged bytes unavailable',409);const from=Math.max(offset,chunk.offset),to=Math.min(end,chunk.offset+chunk.size);const slice=new Uint8Array(chunk.body).subarray(from-chunk.offset,to-chunk.offset);bytes.set(slice,from-offset);copied+=slice.length;
  }
  demand(copied===bytes.length,'Staged file gap',409);const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
  return {offset,sizeBytes:bytes.length,sha256:hash,base64:Buffer.from(bytes).toString('base64')};
 }
 if(action==='claim'){
  if(!['pending','retry','processing'].includes(row.state)||row.due>Date.now()||row.state==='processing'&&row.claim_until>Date.now())return false;
  // Re-evaluate dependencies after any awaited broker round-trip, not just at
  // selection. A forged/stale claim cannot jump an earlier same-record job.
  if(lane==='records'&&!schedule(storage,512,Date.now()).ids.includes(id))return false;
  demand(typeof b.claim==='string'&&b.claim.length>0&&b.claim.length<=100&&Number.isSafeInteger(b.expires)&&Number(b.expires)>Date.now()&&Number(b.expires)<=Date.now()+180000);
  storage.sql.exec("UPDATE edge_ops SET state='processing',claim=?,claim_until=?,due=? WHERE id=?",b.claim,Number(b.expires),Number(b.expires),id);return true;
 }
 if(action==='finish'){
  if(row.claim!==b.claim||!row.claim)return false;const values=b.values as Json;demand(values&&['completed','retry','needsAttention'].includes(String(values.state))&&Number.isSafeInteger(values.nextAttemptAt));
  if(values.state==='completed'||values.result){
   const result=values.result as Json;demand(result&&typeof result==='object'&&result.success===true&&result.schoolId===school,'Verified Drive result required');
   const original=JSON.parse(row.payload) as Json;
   if(lane.startsWith('file-'))demand(result.uploadResumableVersion===1&&result.uploadKey===original.uploadKey&&result.sha256===original.sha256&&result.sizeBytes===original.sizeBytes&&result.committed===true&&result.offset===original.sizeBytes&&/^[A-Za-z0-9_-]{1,200}$/.test(String(result.fileId||'')),'Unverified Drive file receipt');
   else if(original.action==='managed_records_batch'){
    demand(result.syncProtocol===2&&result.recordWriteBatchVersion===1&&Array.isArray(result.acknowledgements)&&result.acknowledgements.length===(original.operations as Json[]).length,'Unverified batch receipt');
    const seen=new Set();for(const ack of result.acknowledgements as Json[]){demand((original.operations as Json[]).some(op=>op.operationId===ack.operationId)&&!seen.has(ack.operationId)&&typeof ack.success==='boolean'&&(!ack.success||typeof ack.recordRevision==='string'&&!!ack.recordRevision&&!/^(live-|cf-)/.test(ack.recordRevision)),'Unverified operation receipt');seen.add(ack.operationId);}
   }else demand(result.syncProtocol===2&&typeof result.recordRevision==='string'&&!!result.recordRevision&&!/^(live-|cf-)/.test(result.recordRevision),'Unverified record receipt');
  }
  if(values.payloadPurged===true){
   demand(lane==='records'&&values.state==='completed','Only verified record delivery may purge payloads');
   const original=JSON.parse(row.payload) as Json,result=values.result as Json;
   demand(canonical(values.identity)===canonical(recordIdentity(original)),'Payload cleanup identity mismatch');
   const requests=original.action==='managed_records_batch'?original.operations as Json[]:[original];
   const receipts=original.action==='managed_records_batch'?result.acknowledgements as Json[]:[result];
   demand(receipts.length===requests.length&&receipts.every((receipt,index)=>{
    const request=requests[index],source=receipt.recordSource as Json;
    return receipt.success===true&&receipt.schoolId===school&&receipt.syncProtocol===2&&receipt.record===null&&source?.version===1&&source.collection===request.collection&&source.id===request.id&&source.operationId===request.operationId&&source.recordRevision===receipt.recordRevision&&typeof source.recordRevision==='string'&&source.recordRevision.length>0&&source.recordRevision.length<=100&&!/^(live-|cf-)/.test(source.recordRevision)&&typeof source.payloadHash==='string'&&operationPattern.test(source.payloadHash);
   }),'Verified canonical source metadata required');
  }
  storage.transactionSync(()=>{
   const stored=values.payloadPurged===true?{...values,partial:{}}:values;
   // An immutable Drive proof is required before the 24h retention timer
   // starts. Retry/needsAttention never acquires an expiry deadline.
   const verified=values.state==='completed'&&(values.payloadPurged===true||lane.startsWith('file-'));
   const verifiedAt=verified?Date.now():0,expiry=verified?verifiedAt+verifiedPayloadTtlMs:0;
   storage.sql.exec("UPDATE edge_ops SET state=?,due=?,claim='',claim_until=0,response=?,verified_at=?,purge_due=? WHERE id=?",String(values.state),Number(values.nextAttemptAt),JSON.stringify(stored),verifiedAt,expiry,id);
   // Original byte/request payload remains until the existing alarm expires.
  });
  if(values.state==='retry')await wake(Number(values.nextAttemptAt));
  if(values.state==='completed'&&(values.payloadPurged===true||lane.startsWith('file-')))await wake(Date.now()+verifiedPayloadTtlMs);
  return true;
 }
 throw Object.assign(Error('Unknown delivery command'),{status:400});
}

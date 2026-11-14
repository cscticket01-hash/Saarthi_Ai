import {initSpool,spoolCommand,spoolLane,canonical} from './spool';
import {stageR2,markR2Verified,sweepR2Verified,r2BudgetStatus} from './r2-stage';
import {Buffer} from 'node:buffer';
import {mobileRequest} from './mobile';
import {initLive,liveCommand} from './live-records';
import {liveSchoolEnabled} from './live-rollout';
import {liveSocketGrant,LiveSocketGrant} from './live-socket';
import {DurableObject} from 'cloudflare:workers';
import {authenticated,boundedBody,demand,digest,operationPattern,schoolPattern,signature} from './protocol';
type Json=Record<string,unknown>;
type Job={id:string;kind:string;payload:string;state:string;due:number;claim:string;claim_until:number;created:number;response:string|null;revision:string|null};
export class SyncLane extends DurableObject<Env>{
 constructor(ctx:DurableObjectState,env:Env){super(ctx,env);ctx.blockConcurrencyWhile(async()=>{
  initSpool(ctx.storage);
  ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY,value TEXT NOT NULL)');
  ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS jobs (seq INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT UNIQUE NOT NULL,kind TEXT NOT NULL,payload TEXT NOT NULL,state TEXT NOT NULL,due INTEGER NOT NULL,claim TEXT NOT NULL DEFAULT \'\',claim_until INTEGER NOT NULL DEFAULT 0,created INTEGER NOT NULL,response TEXT,revision TEXT)');
  ctx.storage.sql.exec('CREATE INDEX IF NOT EXISTS due_jobs ON jobs(state,due,seq)');
  ctx.storage.sql.exec('CREATE INDEX IF NOT EXISTS revision_jobs ON jobs(revision)');
  ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS lanes (name TEXT PRIMARY KEY,due INTEGER NOT NULL,attention INTEGER NOT NULL DEFAULT 0)');
  if(!ctx.storage.sql.exec<{name:string}>('PRAGMA table_info(lanes)').toArray().some(c=>c.name==='attention'))ctx.storage.sql.exec('ALTER TABLE lanes ADD COLUMN attention INTEGER NOT NULL DEFAULT 0');
  ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY,body TEXT NOT NULL)');
 });}
 private meta(key:string):string|undefined{return this.ctx.storage.sql.exec<{value:string}>('SELECT value FROM metadata WHERE key=?',key).toArray()[0]?.value;}
 private setMeta(key:string,value:string){this.ctx.storage.sql.exec('INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value',key,value);}
 private job(id:string):Job|undefined{return this.ctx.storage.sql.exec<Job>('SELECT * FROM jobs WHERE id=?',id).toArray()[0];}
 // One account-wide Durable Object coordinates all TEST bucket reservations.
 // These are internal Durable Object RPC methods, never public HTTP routes.
 async stageR2Object(school:string,lane:string,id:string,offset:number,bytes:ArrayBuffer){
  demand(!this.meta('identity'),'R2 budget actor cannot be a school data lane',403);
  demand(!this.meta('r2BudgetActor')||this.meta('r2BudgetActor')==='v1','R2 budget identity rejected',403);
  this.setMeta('r2BudgetActor','v1');
  return stageR2(this.ctx.storage,this.env.R2_STAGE,school,lane,id,offset,bytes);
 }
 async r2OriginalVerified(school:string,lane:string,id:string){
  demand(this.meta('r2BudgetActor')==='v1'&&!this.meta('identity'),'R2 budget actor is unavailable',403);
  const result=await markR2Verified(this.ctx.storage,school,lane,id);
  if(result.nextCleanupAt!==null)await this.wake(result.nextCleanupAt);
  return result;
 }
 async r2CapacityStatus(){
  demand(this.meta('r2BudgetActor')==='v1'&&!this.meta('identity'),'R2 budget actor is unavailable',403);
  return r2BudgetStatus(this.ctx.storage);
 }
 async command(school:string,lane:string,b:Json):Promise<unknown>{
  demand(schoolPattern.test(school)&&(/^(?:attendance-[a-f0-9]{2}|notices|delivery|live)$/.test(lane)||spoolLane(lane)));
  const identity=school+'/'+lane;demand(!this.meta('identity')||this.meta('identity')===identity,'School scope rejected',403);this.setMeta('identity',identity);
  if(lane==='live'){
   demand(liveSchoolEnabled(this.env as Env&{LIVE_SYNC_SCHOOLS?:string;LIVE_SYNC_TEST_SCHOOL_ID?:string},school),'Live authority is not enabled for this school',412);
   initLive(this.ctx.storage);
   const staged=this.env.R2_STAGING_ENABLED==='true';
   const budget=()=>this.env.LANES.getByName('saarthi-account-r2-staging-budget-v1');
   if(staged&&b.command==='commit'){
    demand(this.env.R2_STAGE!==undefined,'Private R2 bucket binding required',503);
    demand(typeof b.operationId==='string'&&/^[A-Za-z0-9_-]{16,100}$/.test(b.operationId)&&
     typeof b.collection==='string'&&typeof b.id==='string'&&b.id.length>0&&
     ['write','delete','patch'].includes(String(b.operation))&&
     typeof b.expectedRevision==='string','Invalid original live R2 admission',400);
    const active=this.ctx.storage.sql.exec<{state:string}>(
     'SELECT state FROM live_collections WHERE collection=?',String(b.collection)).toArray()[0];
    demand(active?.state==='active','Verified live collection not active',412);
    const prior=this.ctx.storage.sql.exec<{state:string}>(
     "SELECT state FROM live_backup WHERE operation_id=? AND collection=? AND id=? ORDER BY seq DESC LIMIT 1",
     String(b.operationId),String(b.collection),String(b.id)).toArray()[0];
    if(prior?.state!=='verified'){
     const encoded=new TextEncoder().encode(JSON.stringify(b));
     demand(encoded.byteLength>0&&encoded.byteLength<=256000,'Original live record too large',413);
     await budget().stageR2Object(school,'live',
      await digest(JSON.stringify([school,'live',b.operationId])),0,encoded.buffer as ArrayBuffer);
    }
   }
   const verifiedLive=b.command==='backupFinish'&&b.verified===true&&
    Number.isSafeInteger(b.sequence)&&Number(b.sequence)>0;
   const verifiedOp=verifiedLive?
    this.ctx.storage.sql.exec<{operation_id:string}>(
     "SELECT operation_id FROM live_backup WHERE seq=? AND state='processing'",Number(b.sequence)).toArray()[0]?.operation_id:null;
   if(b.command==='bundlePrepare'){
    // Read-only preflight on the existing per-file DOs. No new file queue,
    // no new record authority and, crucially, NO bundle commit/visible ACK.
    demand(/^[A-Za-z0-9_-]{16,100}$/.test(String(b.bundleId||''))&&Array.isArray(b.media)&&
      b.media.length>=1&&b.media.length<=2&&
      (b.requireDrive===undefined||typeof b.requireDrive==='boolean'),'Invalid media bundle manifest');
    const media=b.media as Json[],seen=new Set<string>(),ids=new Set<string>(),proofs:Json[]=[];
    // One existing file lane per PDF. Fee receipts and marksheets cannot
    // masquerade as an ID card or attach an unrelated portrait.
    const primary=String(media[0]?.kind||'');
    demand(['idCard','receipt','marksheet'].includes(primary)&&
      (primary==='idCard'||media.length===1),
      'Only an ID with optional photo, or one original financial PDF is allowed',412);
    for(const item of media){
     demand(item&&typeof item==='object'&&!Array.isArray(item)&&
       Object.keys(item).every(k=>['kind','id','uploadKey','sha256','sizeBytes','mime'].includes(k)),
       'Invalid media proof request');
     const kind=String(item.kind||''),id=String(item.id||'');
     demand((kind===primary||(primary==='idCard'&&kind==='photo'))&&!seen.has(kind)&&
       operationPattern.test(id)&&typeof item.uploadKey==='string'&&
       /^[A-Za-z0-9_-]{1,150}$/.test(item.uploadKey)&&
       id===await digest(JSON.stringify([school,item.uploadKey])),'Untrusted staged file identity',409);
     const limit=kind==='idCard'?85*1024:kind==='receipt'?30*1024:
       kind==='marksheet'?150*1024:40*1024;
     const allowed=(kind==='photo'?
       ['image/jpeg','image/png','image/webp'].includes(String(item.mime)):
       item.mime==='application/pdf')&&Number.isSafeInteger(item.sizeBytes)&&
       Number(item.sizeBytes)>0&&Number(item.sizeBytes)<=limit;
     demand(allowed&&typeof item.sha256==='string'&&operationPattern.test(item.sha256)&&
       !ids.has(id),'Media size, kind or digest rejected',413);
     seen.add(kind);ids.add(id);
     const proof=await this.env.LANES.getByName(school+'/file-'+id)
       .command(school,'file-'+id,{command:'bundleProof',id,requireDrive:b.requireDrive===true}) as Json;
     demand(proof.staged===true&&proof.version===1&&proof.schoolId===school&&
       proof.id===id&&proof.uploadKey===item.uploadKey&&
       proof.sha256===item.sha256&&proof.sizeBytes===item.sizeBytes&&
       proof.mime===item.mime&&
       (b.requireDrive!==true||proof.driveVerified===true&&
        typeof proof.fileId==='string'&&/^[A-Za-z0-9_-]{1,200}$/.test(proof.fileId)),
       'Staged file bytes or Drive receipt do not match bundle manifest',409);
     proofs.push({kind,id,sha256:proof.sha256,sizeBytes:proof.sizeBytes,mime:proof.mime,
       driveVerified:proof.driveVerified===true,...(proof.driveVerified===true?{fileId:proof.fileId}:{})});
    }
    demand(seen.has(primary),'Original PDF proof is required for atomic bundle',412);
    const manifestHash=await digest(canonical({schoolId:school,bundleId:b.bundleId,media:media}));
    return {bundleProtocol:1,schoolId:school,bundleId:b.bundleId,
      mediaReady:true,archiveReady:proofs.every(p=>p.driveVerified===true),manifestHash,proofs};
   }
   if(b.command==='bundleArchive'){
    // Internal backup barrier: staged bytes can be delivered instantly to
    // peers, but the document must never claim a Drive backup until every
    // original file-lane reports its matching verified Drive receipt.
    const manifest=liveCommand(this.ctx.storage,school,
      {command:'bundleArchiveManifest',bundleId:b.bundleId}) as Json;
    const archived:Json[]=[];
    for(const item of manifest.files as Json[]){
      const id=String(item.id);
      const proof=await this.env.LANES.getByName(school+'/file-'+id)
        .command(school,'file-'+id,{command:'bundleProof',id,requireDrive:true}) as Json;
      demand(proof.schoolId===school&&proof.version===1&&
        typeof proof.staged==='boolean'&&proof.driveVerified===true&&proof.id===item.id&&
        proof.sha256===item.sha256&&proof.sizeBytes===item.sizeBytes&&
        proof.mime===item.mime&&typeof proof.fileId==='string'&&
        /^[A-Za-z0-9_-]{1,200}$/.test(proof.fileId),
        'Archive has no matching immutable Drive file receipt',412);
      archived.push({...item,fileId:proof.fileId});
    }
    return {bundleProtocol:1,schoolId:school,bundleId:b.bundleId,
      mediaManifestHash:manifest.mediaManifestHash,archiveReady:true,files:archived};
   }
   let verifiedMedia:Json|undefined;
   if(b.command==='bundlePublish'){
    // Only signed, hash-verified staged bytes can authorize peer visibility.
    // Drive is an asynchronous backup, never a prerequisite for Cloudflare ACK.
    demand(Object.keys(b).every(k=>['command','schoolId','lane','bundleId',
      'operations','media','mediaManifestHash'].includes(k))&&
      typeof b.mediaManifestHash==='string'&&/^[a-f0-9]{64}$/.test(b.mediaManifestHash),
      'Invalid atomic person bundle request');
    const prior=liveCommand(this.ctx.storage,school,{command:'bundleReceipt',
      bundleId:b.bundleId,operations:b.operations,media:b.media,
      mediaManifestHash:b.mediaManifestHash});
    if(prior.found===true)return prior.receipt;
    verifiedMedia=await this.command(school,'live',{command:'bundlePrepare',
      bundleId:b.bundleId,media:b.media,requireDrive:false}) as Json;
    demand(verifiedMedia.mediaReady===true&&
      verifiedMedia.manifestHash===b.mediaManifestHash,'Staged media manifest changed',409);
    b={...b,command:'bundleCommit'};
   }
   if(b.command==='commit'||b.command==='bundleCommit'||b.command==='backupFinish')await this.wake(Date.now()+250);
   const result=liveCommand(this.ctx.storage,school,b,Date.now(),false,verifiedMedia);
   // The signed backupFinish owner has already atomically checked Drive
   // revision, current claim, event and immutable original live operation.
   // Mark the R2 original only AFTER that verified transaction succeeds.
   if(staged&&verifiedLive&&verifiedOp&&result.accepted===true){
    await budget().r2OriginalVerified(school,'live',
     await digest(JSON.stringify([school,'live',verifiedOp])));
   }
   if(b.command==='backupFinish'&&b.verified===true&&result.accepted===true){
    const head=liveCommand(this.ctx.storage,school,{command:'head'});
    if(Number(head.cursor)>10000)liveCommand(this.ctx.storage,school,{command:'compact',before:Number(head.cursor)-10000});
   }
   if(b.command==='commit'||b.command==='bundleCommit')for(const socket of this.ctx.getWebSockets()){
    const grant=socket.deserializeAttachment() as LiveSocketGrant;
    try{if(grant.schoolId!==school||grant.expiresAt<=Date.now())socket.close(1008,'Refresh school authorization');else socket.send(JSON.stringify({liveProtocol:1,schoolId:school,cursor:result.cursor}));}catch{}
   }
   return result;
  }
  if(spoolLane(lane)){
   const cmd=String(b.command||''),id=String(b.id||'');
   const staged=this.env.R2_STAGING_ENABLED==='true';
   const budget=()=>this.env.LANES.getByName('saarthi-account-r2-staging-budget-v1');
   if(staged){
    demand(this.env.R2_STAGE!==undefined,'Private R2 bucket binding required',503);
    if(lane==='records'&&cmd==='enqueue'){
     const request=b.request as Json|undefined;
     demand(request&&typeof request==='object'&&
      ['managed_records','managed_records_batch'].includes(String(request.action))&&
      /^[a-f0-9]{64}$/.test(id),'Invalid original record R2 admission',400);
     const ops=request.action==='managed_records_batch'?request.operations as Json[]:[request];
     demand(Array.isArray(ops)&&ops.length>0&&ops.length<=10&&ops.every(op=>
      op&&op.syncProtocol===2&&['write','delete'].includes(String(op.operation))&&
      typeof op.id==='string'&&typeof op.collection==='string'&&
      /^[A-Za-z0-9_-]{16,100}$/.test(String(op.operationId))&&
      (op.operation!=='write'||(op.data as Json)?.schoolId===school)),
      'Invalid original school record',400);
     const identity=request.action==='managed_records_batch'?
      ops.map(op=>[op.collection,op.id,op.operationId]):[request.collection,request.id,request.operationId];
     demand(await digest(JSON.stringify([school,request.action,identity]))===id,'Original R2 identity mismatch',409);
     const encoded=new TextEncoder().encode(JSON.stringify(request));
     demand(encoded.byteLength>0&&encoded.byteLength<=300000,'Original record too large',413);
     await budget().stageR2Object(school,lane,id,0,encoded.buffer as ArrayBuffer);
    }
    if(lane.startsWith('file-')&&(cmd==='putSmall'||cmd==='part')){
     demand(/^file-[a-f0-9]{64}$/.test(lane)&&lane==='file-'+id&&
      typeof b.base64==='string'&&b.base64.length>0&&b.base64.length<=699052&&
      /^[A-Za-z0-9+/]*={0,2}$/.test(b.base64),'Invalid original file R2 chunk',400);
     const bytes=Buffer.from(b.base64 as string,'base64');
     demand(bytes.length>0&&bytes.length<=512*1024&&bytes.toString('base64')===b.base64,
      'Invalid original file bytes',400);
     const offset=cmd==='putSmall'?0:Number(b.offset);
     demand(Number.isSafeInteger(offset)&&offset>=0,'Invalid original file offset',400);
     const hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].
      map(x=>x.toString(16).padStart(2,'0')).join('');
     if(cmd==='putSmall'){
      const manifest=b.manifest as Json|undefined;
      demand(manifest&&typeof manifest.uploadKey==='string'&&
       id===await digest(JSON.stringify([school,manifest.uploadKey]))&&
       hash===manifest.sha256&&bytes.length===manifest.sizeBytes&&bytes.length<=256*1024,
       'Small original file digest mismatch',409);
     }else{
      const original=this.ctx.storage.sql.exec<{payload:string;state:string}>(
       'SELECT payload,state FROM edge_ops WHERE id=?',id).toArray()[0];
      demand(original&&original.state==='receiving'&&
       hash===b.chunkSha256,'Original file part rejected',409);
      const manifest=JSON.parse(original.payload) as Json;
      demand(offset+bytes.length<=Number(manifest.sizeBytes),
       'Original file chunk exceeds manifest',409);
     }
     await budget().stageR2Object(school,lane,id,offset,
      bytes.buffer.slice(bytes.byteOffset,bytes.byteOffset+bytes.byteLength) as ArrayBuffer);
    }
   }
   const result=await spoolCommand(this.ctx.storage,school,lane,b,at=>this.wake(at));
   if(staged&&cmd==='finish'&&result===true&&(b.values as Json)?.state==='completed'){
    const values=b.values as Json,ack=values.result as Json|undefined;
    const allAccepted=lane==='records'&&ack?.success===true&&ack.schoolId===school&&
      (ack.recordWriteBatchVersion!==1||
       Array.isArray(ack.acknowledgements)&&(ack.acknowledgements as Json[]).every(x=>x.success===true));
    const fileAccepted=lane.startsWith('file-')&&ack?.success===true&&ack.schoolId===school&&
      ack.committed===true&&typeof ack.fileId==='string';
    if(allAccepted||fileAccepted)await budget().r2OriginalVerified(school,lane,id);
   }
   return result;
  }
  const action=String(b.command||''),id=String(b.id||'');
  // Legacy notices and encrypted attendance have their own already-durable
  // school-lane owner. Stage exactly their immutable original request before
  // their existing visible Cloudflare ACK, not before Google Drive delivery.
  const stageOther=this.env.R2_STAGING_ENABLED==='true'&&
   ((lane==='notices'&&action==='write')||(lane.startsWith('attendance-')&&action==='create'));
  const budget=()=>this.env.LANES.getByName('saarthi-account-r2-staging-budget-v1');
  if(stageOther){
   demand(this.env.R2_STAGE!==undefined,'Private R2 bucket binding required',503);
   if(lane==='notices'){
    const request=b.request as Json|undefined;
    demand(!this.meta('retired')&&!!this.meta('initialized')&&request&&
     request.action==='managed_records'&&request.collection==='school_notices'&&
     ['write','delete'].includes(String(request.operation))&&request.syncProtocol===2&&
     typeof request.id==='string'&&request.id.length>0&&request.id.length<=200&&
     !request.id.includes('/')&&typeof request.operationId==='string'&&
     /^[A-Za-z0-9_-]{16,100}$/.test(request.operationId)&&
     typeof request.expectedRecordRevision==='string'&&
     (request.operation==='delete'||(request.data as Json)?.schoolId===school),
     'Invalid original notice R2 admission',400);
    const key=await digest(JSON.stringify([school,request.operationId]));
    const prior=this.job(key);
    if(prior){
     const saved=JSON.parse(prior.payload) as Json;
     demand(saved.fingerprint===await digest(JSON.stringify(request)),
      'Sync operation ID conflict',409);
    }
    const encoded=new TextEncoder().encode(JSON.stringify(request));
    demand(encoded.byteLength>0&&encoded.byteLength<=300000,'Original notice too large',413);
    // A replay of a completed, Drive-verified job must not resurrect expired
    // 24h staged bytes or consume fresh capacity.
    if(prior?.state!=='completed'||!(prior.response&&
       typeof (JSON.parse(prior.response) as Json)?.driveRevision==='string'))
     await budget().stageR2Object(school,lane,key,0,encoded.buffer as ArrayBuffer);
   }else{
    const row=b.row as Json|undefined;
    demand(row&&row.schoolId===school&&row.operationId===id&&
     /^[a-f0-9]{64}$/.test(id)&&id.slice(0,2)===lane.slice(-2),
     'Invalid original attendance R2 admission',400);
    const encoded=new TextEncoder().encode(JSON.stringify(row));
    demand(encoded.byteLength>0&&encoded.byteLength<=300000,
     'Original attendance request too large',413);
    await budget().stageR2Object(school,lane,id,0,encoded.buffer as ArrayBuffer);
   }
  }
  if(action==='retireNoticeCache'){
   demand(lane==='notices'&&liveSchoolEnabled(this.env as Env&{LIVE_SYNC_SCHOOLS?:string;LIVE_SYNC_TEST_SCHOOL_ID?:string},school),'Isolated live notice owner required',412);
   const owner=await this.env.LANES.getByName(school+'/live').command(school,'live',{command:'head'}) as {collections:{collection:string;state:string}[]};
   demand(owner.collections.some(row=>row.collection==='school_notices'&&row.state==='active'),'Verified live notice baseline required',409);
   demand(this.ctx.storage.sql.exec<{n:number}>("SELECT count(*) AS n FROM jobs WHERE state!='completed'").toArray()[0].n===0,'Legacy notice delivery pending',409);
   this.ctx.storage.transactionSync(()=>{this.ctx.storage.sql.exec('DELETE FROM records');this.ctx.storage.sql.exec("UPDATE jobs SET payload='' WHERE state='completed'");this.setMeta('retired','drive');});
   return {retired:true};
  }
  if(action==='schedule'){demand(lane==='delivery'&&typeof b.sourceLane==='string'&&(/^(?:attendance-[a-f0-9]{2}|notices)$/.test(b.sourceLane)||spoolLane(b.sourceLane)));this.ctx.storage.sql.exec('INSERT INTO lanes(name,due) VALUES(?,?) ON CONFLICT(name) DO UPDATE SET due=min(lanes.due,excluded.due)',b.sourceLane,Date.now());await this.wake(Date.now()+250);return true;}
  if(action==='stats'&&lane==='delivery')return this.ctx.storage.sql.exec<{pendingPartitions:number;needsAttention:number}>('SELECT count(*) AS pendingPartitions,coalesce(sum(attention),0) AS needsAttention FROM lanes').toArray()[0];
  if(action==='stats'){const stats=this.ctx.storage.sql.exec<{pending:number;due:number}>('SELECT count(*) AS pending,min(due) AS due FROM jobs WHERE state IN (\'pending\',\'retry\',\'processing\')').toArray()[0];const attention=this.ctx.storage.sql.exec<{needsAttention:number}>('SELECT count(*) AS needsAttention FROM jobs WHERE state=\'needsAttention\'').toArray()[0];return {...stats,...attention};}
  if(action==='get'){demand(operationPattern.test(id));return this.job(id)||null;}
  if(action==='pending'){
   const limit=Number(b.limit);demand(Number.isInteger(limit)&&limit>=1&&limit<=200);
   // Preserve FIFO notice revisions; a retry cannot be overtaken by a newer edit.
   const rows=this.ctx.storage.sql.exec<Job>('SELECT * FROM jobs WHERE state IN (\'pending\',\'retry\',\'processing\') ORDER BY seq LIMIT ?',limit).toArray();
   return lane==='notices'?rows.slice(0,1).filter(r=>r.due<=Date.now()):rows.filter(r=>r.due<=Date.now());
  }
  if(action==='claim'){
   const row=this.job(id);if(!row||!['pending','retry','processing'].includes(row.state)||row.due>Date.now()||row.state==='processing'&&row.claim_until>Date.now())return false;
   demand(typeof b.claim==='string'&&b.claim.length<=100&&Number.isSafeInteger(b.expires)&&Number(b.expires)>Date.now()&&Number(b.expires)<=Date.now()+180000);
   this.ctx.storage.sql.exec('UPDATE jobs SET state=\'processing\',claim=?,claim_until=?,due=? WHERE id=?',b.claim,Number(b.expires),Number(b.expires),id);return true;
  }
  if(action==='finish'){
   const row=this.job(id);if(!row||row.claim!==b.claim||!row.claim)return false;
   const values=b.values as Json;demand(values&&['completed','retry','needsAttention'].includes(String(values.state))&&Number.isSafeInteger(values.nextAttemptAt));
   let clearedPayload:string|undefined;
   if(values.attendancePayloadPurged===true){
    const original=JSON.parse(row.payload) as Json,receipt=values.attendanceOwnerReceipt as Json;
    demand(lane.startsWith('attendance-')&&values.state==='completed'&&receipt?.version===1&&receipt.driveVerified===true&&receipt.schoolId===school&&receipt.operationId===id&&receipt.day===original.day&&receipt.mode===original.mode&&['student','teacher'].includes(String(receipt.role))&&typeof receipt.documentId==='string'&&receipt.documentId.length>0&&receipt.documentId.length<=200&&!receipt.documentId.includes('/')&&operationPattern.test(String(receipt.requestHash))&&operationPattern.test(String(receipt.payloadHash)),'Verified attendance owner required');
    demand(Object.keys(receipt).every(key=>['version','schoolId','operationId','role','documentId','day','mode','requestHash','payloadHash','driveVerified'].includes(key)),'Unexpected attendance receipt payload');
    demand(await digest(canonical(original.payload))===receipt.payloadHash,'Attendance payload proof mismatch',409);
    demand(this.job(id)?.claim===b.claim&&row.claim_until>Date.now(),'Attendance claim changed',409);
    clearedPayload=JSON.stringify({schoolId:school,operationId:id,day:original.day,mode:original.mode,payload:null,createdAt:original.createdAt});
   }
   this.ctx.storage.transactionSync(()=>{
    this.ctx.storage.sql.exec('UPDATE jobs SET state=?,due=?,claim=\'\',claim_until=0,response=? WHERE id=?',String(values.state),Number(values.nextAttemptAt),JSON.stringify(values),id);
    if(clearedPayload!==undefined)this.ctx.storage.sql.exec('UPDATE jobs SET payload=? WHERE id=?',clearedPayload,id);
   });
   if(values.state==='retry')await this.wake(Number(values.nextAttemptAt));
   // Only the already-checked original attendance owner proof may release R2
   // retention; a generic completed job, or a notice with no Drive revision,
   // is NOT verification and must stay staged.
   if(this.env.R2_STAGING_ENABLED==='true'&&values.state==='completed'){
    const verifiedAttendance=lane.startsWith('attendance-')&&
      values.attendancePayloadPurged===true&&
      (values.attendanceOwnerReceipt as Json|undefined)?.driveVerified===true;
    const revision=String(values.driveRevision||'');
    const verifiedNotice=lane==='notices'&&
      revision.length>0&&!/^(live-|cf-)/.test(revision)&&
      typeof values.completedAt==='number'&&Number.isSafeInteger(values.completedAt);
    if(verifiedAttendance||verifiedNotice)
     await budget().r2OriginalVerified(school,lane,id);
   }
   return true;
  }
  if(action==='create'){
   demand(lane.startsWith('attendance-')&&operationPattern.test(id));const row=b.row as Json;demand(row&&row.schoolId===school&&row.operationId===id&&id.slice(0,2)===lane.slice(-2));
   if(this.job(id))return false;
   this.ctx.storage.sql.exec('INSERT INTO jobs(id,kind,payload,state,due,created) VALUES(?,\'attendance\',?,\'pending\',?,?)',id,JSON.stringify(row),Date.now(),Number(row.createdAt));await this.wake(Date.now()+250);return true;
  }
  demand(lane==='notices');
  demand(!this.meta('retired')||!['seed','snapshot','write'].includes(action),'Legacy notice cache retired; use verified school owner',412);
  if(action==='seed'){
   if(this.meta('initialized'))return {seeded:false};const records=b.records as Record<string,Json>;demand(records&&typeof records==='object'&&Object.keys(records).length<=10000);
   this.ctx.storage.transactionSync(()=>{for(const [key,value]of Object.entries(records)){demand(key.length>0&&key.length<=200&&!key.includes('/')&&!['.','..','__proto__','prototype','constructor'].includes(key)&&value.schoolId===school);this.ctx.storage.sql.exec('INSERT INTO records(id,body) VALUES(?,?)',key,JSON.stringify(value));}this.setMeta('revision',String(b.revision||'legacy'));this.setMeta('initialized','1');});return {seeded:true};
  }
  if(action==='snapshot'){
   const initialized=!!this.meta('initialized'),records:Record<string,Json>={};
   for(const row of this.ctx.storage.sql.exec<{id:string;body:string}>('SELECT id,body FROM records LIMIT 10001'))records[row.id]=JSON.parse(row.body) as Json;
   demand(Object.keys(records).length<=10000,'Notice snapshot too large',413);return {initialized,records,revision:this.meta('revision')||'legacy'};
  }
  if(action==='receipt'){
   demand(typeof b.revision==='string');const row=this.ctx.storage.sql.exec<Job>('SELECT * FROM jobs WHERE revision=?',b.revision).toArray()[0];
   return row?{state:row.state,response:row.response?JSON.parse(row.response):null}:null;
  }
  if(action==='write'){
   demand(this.meta('initialized'),'Notice baseline required',409);const request=b.request as Json;demand(request&&['write','delete'].includes(String(request.operation))&&request.syncProtocol===2&&typeof request.id==='string'&&request.id.length>0&&request.id.length<=200&&!request.id.includes('/')&&!['.','..','__proto__','prototype','constructor'].includes(request.id)&&/^[A-Za-z0-9_-]{16,100}$/.test(String(request.operationId)));
   const key=await digest(JSON.stringify([school,request.operationId]));const fingerprint=await digest(JSON.stringify(request));const prior=this.job(key);
   if(prior){const saved=JSON.parse(prior.payload) as Json;demand(saved.fingerprint===fingerprint,'Sync operation ID conflict',409);return saved.ack;}
   const revision='cf-'+crypto.randomUUID(),collectionRevision='cf-'+crypto.randomUUID();
   const ack=this.ctx.storage.transactionSync(()=>{
    const currentRow=this.ctx.storage.sql.exec<{body:string}>('SELECT body FROM records WHERE id=?',String(request.id)).toArray()[0];const current=currentRow?JSON.parse(currentRow.body) as Json:null;
    demand((current?String(current._syncRevision||''):'')===request.expectedRecordRevision,'Record revision conflict',409);
    let data=request.operation==='delete'?{schoolId:school,_syncDeleted:true}:structuredClone(request.data) as Json;
    demand(data&&data.schoolId===school);const patch=data._syncFieldPatch as Json|undefined;
    if(patch){demand(current&&!current._syncDeleted&&patch.version===1&&patch.set&&typeof patch.set==='object'&&!Array.isArray(patch.set)&&Array.isArray(patch.remove)&&Object.keys(patch.set).length+patch.remove.length<=256);for(const field of [...Object.keys(patch.set),...patch.remove as string[]]){demand(typeof field==='string'&&field.length>0&&field.length<=200&&!['id','schoolId','createdAt','__proto__','prototype','constructor'].includes(field)&&!field.startsWith('_sync'));}data={...current,...patch.set as Json};for(const field of patch.remove as string[]){demand(typeof field==='string'&&!['id','schoolId','createdAt','__proto__','prototype','constructor'].includes(field)&&!field.startsWith('_sync'));delete data[field];}}
    delete data._syncFieldPatch;const fields={...(current?._syncFieldRevisions as Record<string,string>||{})};
    for(const field of new Set([...Object.keys(current||{}),...Object.keys(data)])){if(field.startsWith('_sync')||field==='id'||field==='schoolId')continue;if(JSON.stringify(current?.[field])!==JSON.stringify(data[field]))fields[field]=revision;}
    const record={...data,id:request.id,schoolId:school,_syncRevision:revision,_syncOperationId:request.operationId,_syncFieldRevisions:fields};
    const result={success:true,schoolId:school,syncProtocol:2,recordRevision:revision,collectionRevision,record:record,cloudflareAccepted:true,driveState:'pending'};
    const payload={request,fingerprint,ack:result,record,baseRevision:request.expectedRecordRevision};
    this.ctx.storage.sql.exec('INSERT INTO jobs(id,kind,payload,state,due,created,revision) VALUES(?,\'notice\',?,\'pending\',?,?,?)',key,JSON.stringify(payload),Date.now(),Date.now(),revision);
    this.ctx.storage.sql.exec('INSERT INTO records(id,body) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body',String(request.id),JSON.stringify(record));this.setMeta('revision',collectionRevision);return result;
   });await this.wake(Date.now()+250);return ack;
  }
  throw Object.assign(new Error('Unknown sync command'),{status:400});
 }
 private async wake(at:number){const existing=await this.ctx.storage.getAlarm();if(existing===null||existing>at)await this.ctx.storage.setAlarm(Math.max(Date.now()+100,at));}
 async fetch(request:Request):Promise<Response>{
  return this.connectLive(await liveSocketGrant(request,this.env.EDGE_KEY));
 }
 async connectLive(grant:LiveSocketGrant):Promise<Response>{
  demand(liveSchoolEnabled(this.env as Env&{LIVE_SYNC_SCHOOLS?:string;LIVE_SYNC_TEST_SCHOOL_ID?:string},grant.schoolId)&&grant.expiresAt>Date.now(),'Live stream unavailable',412);
  const identity=grant.schoolId+'/live';demand(!this.meta('identity')||this.meta('identity')===identity,'School scope rejected',403);this.setMeta('identity',identity);initLive(this.ctx.storage);
  for(const socket of this.ctx.getWebSockets()){const old=socket.deserializeAttachment() as LiveSocketGrant;if(old.expiresAt<=Date.now())socket.close(1008,'Refresh school authorization');}
  demand(this.ctx.getWebSockets().length<100,'Live connection limit',429);
  const pair=new WebSocketPair();this.ctx.acceptWebSocket(pair[1]);pair[1].serializeAttachment(grant);
  pair[1].send(JSON.stringify(liveCommand(this.ctx.storage,grant.schoolId,{command:'head'})));
  return new Response(null,{status:101,webSocket:pair[0],headers:{'Sec-WebSocket-Protocol':'vidya-live-v1'}});
 }
 webSocketMessage(socket:WebSocket,message:string|ArrayBuffer):void{
  const grant=socket.deserializeAttachment() as LiveSocketGrant;
  if(grant.expiresAt<=Date.now()){socket.close(1008,'Refresh school authorization');return;}
  if(typeof message!=='string'||message!=='head'){socket.close(1008,'Unsupported live message');return;}
  socket.send(JSON.stringify(liveCommand(this.ctx.storage,grant.schoolId,{command:'head'})));
 }
 async alarm(){
  if(this.meta('r2BudgetActor')==='v1'){
   try{const result=await sweepR2Verified(this.ctx.storage,this.env.R2_STAGE);
    if(result.nextCleanupAt!==null)await this.wake(result.more?Date.now()+1000:result.nextCleanupAt);
   }catch{await this.wake(Date.now()+60_000);} // Retry, never delete unverified data.
   return;
  }
  const identity=this.meta('identity');if(!identity)return;const [school,lane]=identity.split('/');
  if(lane==='live'){
   const raw=JSON.stringify({action:'managed/live/drain',schoolId:school}),time=String(Date.now());
   try{const response=await fetch(this.env.BROKER_URL,{method:'POST',headers:{'Content-Type':'application/json','Authorization':'Bearer cloudflare-delivery','X-Vidya-Time':time,'X-Vidya-Signature':await signature(this.env.EDGE_KEY,time+'\n'+raw)},body:raw,signal:AbortSignal.timeout(110000)});await response.body?.cancel();}catch{}
   // Reuse the Durable Object alarm for age-based cleanup. Never delete
   // unverified/retrying backups even if their original upload is >24h old.
   let cleanupDue:number|null=null;
   try{
    const sweep=liveCommand(this.ctx.storage,school,{command:'expireVerified'}) as {expired:number;nextCleanupAt:number|null};
    cleanupDue=sweep.nextCleanupAt;
    if(sweep.expired>=200)cleanupDue=Date.now()+1000;
   }catch{cleanupDue=Date.now()+60_000;} // Keep payloads, retry safe sweep.
   const rows=this.ctx.storage.sql.exec<{due:number}>("SELECT min(b.due) AS due FROM live_backup b WHERE b.state IN ('pending','retry','processing') AND NOT EXISTS(SELECT 1 FROM live_backup earlier WHERE earlier.collection=b.collection AND earlier.id=b.id AND earlier.seq<b.seq AND earlier.state!='verified')").toArray();
   const pendingDue=rows[0]?.due??null;
   const due=pendingDue===null?cleanupDue:cleanupDue===null?pendingDue:Math.min(pendingDue,cleanupDue);
   if(due!==null)await this.ctx.storage.setAlarm(Math.max(Date.now()+1000,due));return;
  }
  if(lane!=='delivery'){
   if(spoolLane(lane)){
    try{
     const expired=await spoolCommand(this.ctx.storage,school,lane,{command:'expireVerified'},at=>this.wake(at)) as {expired:number;nextCleanupAt:number|null};
     if(expired.nextCleanupAt!==null)await this.wake(expired.expired>=200?Date.now()+1000:expired.nextCleanupAt);
    }catch{await this.wake(Date.now()+60_000);} // Do not delete on failed proof.
   }
   await this.env.LANES.getByName(school+'/delivery').command(school,'delivery',{command:'schedule',sourceLane:lane});return;
  }
  const next=this.ctx.storage.sql.exec<{name:string;due:number}>('SELECT name,due FROM lanes WHERE due < 9007199254740991 ORDER BY due,name LIMIT 1').toArray()[0];
  const backoff=Number(this.meta('deliveryBackoff')||0);if(backoff>Date.now()){await this.ctx.storage.setAlarm(backoff);return;}
  if(!next)return;if(next.due>Date.now()){await this.ctx.storage.setAlarm(next.due);return;}
  const raw=JSON.stringify({action:'managed/cloudflare/drain',schoolId:school,lane:next.name}),time=String(Date.now());
  let delay=30_000;
  try{const response=await fetch(this.env.BROKER_URL,{method:'POST',headers:{'Content-Type':'application/json','Authorization':'Bearer cloudflare-delivery','X-Vidya-Time':time,'X-Vidya-Signature':await signature(this.env.EDGE_KEY,time+'\n'+raw)},body:raw,signal:AbortSignal.timeout(110000)});if(response.ok)delay=250;await response.body?.cancel();}catch{ /* Durable rows remain; retry after broker outage. */ }
  if(delay>=30000)this.setMeta('deliveryBackoff',String(Date.now()+delay));else this.setMeta('deliveryBackoff','0');
  const stats=await this.env.LANES.getByName(school+'/'+next.name).command(school,next.name,{command:'stats'}) as {pending:number;due:number;needsAttention:number};
  if(stats.pending===0&&stats.needsAttention===0)this.ctx.storage.sql.exec('DELETE FROM lanes WHERE name=?',next.name);
  else this.ctx.storage.sql.exec('UPDATE lanes SET due=?,attention=? WHERE name=?',stats.pending===0?Number.MAX_SAFE_INTEGER:Math.max(Date.now()+delay,stats.due),stats.needsAttention,next.name);
  const due=this.ctx.storage.sql.exec<{due:number}>('SELECT min(due) AS due FROM lanes WHERE due < 9007199254740991').toArray()[0]?.due;
  if(due!==null&&due!==undefined)await this.ctx.storage.setAlarm(Math.max(Date.now()+100,due));
 }

}
export default {
 async fetch(request:Request,env:Env):Promise<Response>{
  const headers={'Cache-Control':'no-store','Content-Type':'application/json','X-Content-Type-Options':'nosniff'};
  try{
   const url=new URL(request.url);if(url.pathname==='/healthz'&&request.method==='GET')return Response.json({service:'vidya-saarthi-cloudflare-sync',version:2,edgeDeliveryVersion:1,attendancePartitions:256},{headers});
   if(url.pathname==='/live'&&request.method==='GET'){
    const grant=await liveSocketGrant(request,env.EDGE_KEY);
    demand(liveSchoolEnabled(env as Env&{LIVE_SYNC_SCHOOLS?:string;LIVE_SYNC_TEST_SCHOOL_ID?:string},grant.schoolId),'Live authority is not enabled',412);
    return env.LANES.getByName(grant.schoolId+'/live').fetch(request);
   }
   if(request.method==='POST'&&url.pathname==='/mobile')return Response.json(await mobileRequest(request,env),{headers});
   demand(request.method==='POST'&&url.pathname==='/internal','Not found',404);const raw=await boundedBody(request,800000);
   demand(await authenticated(env.EDGE_KEY,raw,request.headers),'Sync authorization rejected',401);
   const body=JSON.parse(raw) as Json,school=String(body.schoolId||''),lane=String(body.lane||'');demand(schoolPattern.test(school)&&(/^(?:attendance-[a-f0-9]{2}|notices|delivery|live)$/.test(lane)||spoolLane(lane)));
   demand(raw.length<=(/^file-[a-f0-9]{64}$/.test(lane)?800000:400000),'Request too large',413);
   try{
    const value=await env.LANES.getByName(school+'/'+lane).command(school,lane,body);
    return Response.json({success:true,schoolId:school,value},{headers});
   }catch(error){
    // Only an authenticated, routed notice WRITE can attest that this exact
    // attempt failed a precondition before writing. The broker requires this
    // school binding; without it a known rejection leaves an uncertain marker.
    // Do not attach this proof to auth, delete, delivery or other-lane errors.
    const e=error as Error&{status?:number},notice=body.request as Json|undefined;
    if(lane==='notices'&&body.command==='write'&&notice?.collection==='school_notices'&&
       notice.operation==='write'&&e.status===409&&
       ['Record revision conflict','Sync operation ID conflict'].includes(e.message))
     return Response.json({success:false,schoolId:school,message:e.message},{status:409,headers});
    throw error;
   }
  }catch(error){
  const e=error as Error&{status?:number};const status=e.status||503;
  // Fixed, non-sensitive fail-closed signal. A 507 is never a cloud ACK.
  if(status===507)return Response.json({success:false,code:'R2_CAPACITY_EXCEEDED',
    message:'Cloudflare 8 GB school data capacity reached; local work retained.'},{status:507,headers});
  return Response.json({success:false,message:status<500?e.message:'Cloudflare sync unavailable; pending work retained.'},{status,headers});
 }
 }
} satisfies ExportedHandler<Env>;

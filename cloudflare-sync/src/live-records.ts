import {createHash,randomUUID} from 'node:crypto';
import {canonical} from './spool';
import {demand,schoolPattern} from './protocol';
type Json=Record<string,unknown>;
type Row={collection:string;id:string;body:string;revision:string;drive_revision:string;payload_hash:string};
type Job={seq:number;collection:string;id:string;operation_id:string;operation:string;body:string;state:string;due:number;claim:string;claim_until:number;drive_revision:string|null};
// Rollout intentionally starts with independent administrative records. Person,
// financial-ledger, attendance and document lifecycles retain their old owners.
export const liveCollections=new Set(['school_expenses','school_calendar','school_notices','school_settings']);
const hash=(v:unknown)=>createHash('sha256').update(canonical(v)).digest('hex');
const business=(v:Json)=>Object.fromEntries(Object.entries(v).filter(([k])=>!k.startsWith('_sync')));
const payloadHash=(v:Json)=>hash({deleted:v._syncDeleted===true,data:business(v)});
const byteLength=(v:string)=>new TextEncoder().encode(v).byteLength;
const validId=(v:unknown):v is string=>typeof v==='string'&&v.length>0&&v.length<=200&&!v.includes('/')&&!['.','..','__proto__','prototype','constructor'].includes(v);
const opId=(v:unknown):v is string=>typeof v==='string'&&/^[A-Za-z0-9_-]{16,100}$/.test(v);
function clean(v:unknown,depth=0):void{
 demand(depth<=12,'Record too deeply nested');
 if(Array.isArray(v)){for(const x of v)clean(x,depth+1);return;}
 if(v&&typeof v==='object')for(const [k,x]of Object.entries(v)){
  demand(!['__proto__','prototype','constructor'].includes(k)&&!(/password|token|secret|private_key|base64|localpath/i.test(k)&&k!=='mobileLinkToken'),'Invalid record field');clean(x,depth+1);
 }
 if(typeof v==='string')demand(!v.startsWith('data:'),'Media uses the existing file pipeline');
}
export function initLive(storage:DurableObjectStorage){
 storage.sql.exec('CREATE TABLE IF NOT EXISTS live_collections(collection TEXT PRIMARY KEY,state TEXT NOT NULL,fingerprint TEXT NOT NULL,expected_count INTEGER NOT NULL,source_revision TEXT NOT NULL)');
 storage.sql.exec('CREATE TABLE IF NOT EXISTS live_records(collection TEXT NOT NULL,id TEXT NOT NULL,body TEXT NOT NULL,revision TEXT NOT NULL,drive_revision TEXT NOT NULL,PRIMARY KEY(collection,id))');
 if(!storage.sql.exec<{name:string}>('PRAGMA table_info(live_records)').toArray().some(c=>c.name==='payload_hash')){
  storage.sql.exec("ALTER TABLE live_records ADD COLUMN payload_hash TEXT NOT NULL DEFAULT ''");
  for(const row of storage.sql.exec<Row>("SELECT * FROM live_records WHERE body!=''").toArray())storage.sql.exec('UPDATE live_records SET payload_hash=? WHERE collection=? AND id=?',payloadHash(JSON.parse(row.body)),row.collection,row.id);
 }
 storage.sql.exec('CREATE TABLE IF NOT EXISTS live_events(seq INTEGER PRIMARY KEY AUTOINCREMENT,collection TEXT NOT NULL,id TEXT NOT NULL,body TEXT NOT NULL,operation_id TEXT UNIQUE NOT NULL,fingerprint TEXT NOT NULL,receipt TEXT NOT NULL)');
 storage.sql.exec('CREATE TABLE IF NOT EXISTS live_operations(operation_id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,receipt TEXT NOT NULL)');
 storage.sql.exec("CREATE TABLE IF NOT EXISTS live_backup(seq INTEGER PRIMARY KEY,collection TEXT NOT NULL,id TEXT NOT NULL,operation_id TEXT NOT NULL,operation TEXT NOT NULL,body TEXT NOT NULL,state TEXT NOT NULL,due INTEGER NOT NULL,claim TEXT NOT NULL DEFAULT '',claim_until INTEGER NOT NULL DEFAULT 0,drive_revision TEXT)");
 storage.sql.exec('CREATE INDEX IF NOT EXISTS live_backup_owner ON live_backup(collection,id,seq)');
 storage.sql.exec('CREATE TABLE IF NOT EXISTS live_device_receipts(device TEXT PRIMARY KEY,cursor INTEGER NOT NULL,observed_at INTEGER NOT NULL)');
}
export function liveCommand(storage:DurableObjectStorage,school:string,b:Json,now=Date.now()):Json{
 demand(schoolPattern.test(school),'Invalid school');
 const sql=storage.sql,command=b.command,col=String(b.collection||'');
 const collection=()=>demand(liveCollections.has(col),'Collection not admitted to live authority',412);
 const head=()=>sql.exec<{n:number}>('SELECT coalesce(max(seq),0) AS n FROM live_events').toArray()[0].n;
 const state=()=>sql.exec<{state:string;fingerprint:string;expected_count:number;source_revision:string}>('SELECT * FROM live_collections WHERE collection=?',col).toArray()[0];
 const row=(id:string)=>sql.exec<Row>('SELECT * FROM live_records WHERE collection=? AND id=?',col,id).toArray()[0];
 if(command==='seedBegin'){
  collection();demand(typeof b.fingerprint==='string'&&/^[a-f0-9]{64}$/.test(b.fingerprint)&&Number.isSafeInteger(b.count)&&Number(b.count)>=0&&Number(b.count)<=100000&&typeof b.sourceRevision==='string'&&b.sourceRevision.length>0&&b.sourceRevision.length<=100,'Invalid seed');
  const old=state();if(old){demand(old.fingerprint===b.fingerprint&&old.expected_count===b.count&&old.source_revision===b.sourceRevision,'Seed identity changed; retain existing state',409);return {state:old.state};}
  sql.exec("INSERT INTO live_collections VALUES(?,'seeding',?,?,?)",col,b.fingerprint,Number(b.count),b.sourceRevision);return {state:'seeding'};
 }
 if(command==='seedPage'){
  collection();const s=state();demand(s?.state==='seeding'&&s.fingerprint===b.fingerprint,'Seed not writable',409);
  demand(Array.isArray(b.rows)&&b.rows.length<=100,'Seed page too large');
  storage.transactionSync(()=>{for(const entry of b.rows as Json[]){
   demand(validId(entry.id)&&entry.data&&typeof entry.data==='object'&&!Array.isArray(entry.data),'Invalid seed row');
   const data=entry.data as Json;clean(data);demand(data.schoolId===school&&typeof data._syncRevision==='string'&&data._syncRevision.length>0&&!/^(live-|cf-)/.test(data._syncRevision),'Unverified source row');
   const body=canonical(data),old=row(entry.id);demand(!old||old.body===body,'Seed replay differs',409);
   if(!old)sql.exec('INSERT INTO live_records(collection,id,body,revision,drive_revision,payload_hash) VALUES(?,?,?,?,?,?)',col,entry.id,body,data._syncRevision,data._syncRevision,payloadHash(data));
  }demand(sql.exec<{n:number}>('SELECT count(*) AS n FROM live_records WHERE collection=?',col).toArray()[0].n<=s.expected_count,'Seed count exceeded',409);});return {state:'seeding'};
 }
 if(command==='seedSeal'){
  collection();return storage.transactionSync(()=>{
   const s=state();demand(s&&s.fingerprint===b.fingerprint,'Seed identity mismatch',409);if(s.state==='active')return {state:'active'};
   const records:Record<string,Json>={};for(const r of sql.exec<Row>('SELECT * FROM live_records WHERE collection=? ORDER BY id',col))records[r.id]=JSON.parse(r.body);
   demand(Object.keys(records).length===s.expected_count&&hash(records)===s.fingerprint,'Incomplete or changed seed',409);
   sql.exec("UPDATE live_collections SET state='active' WHERE collection=?",col);
   sql.exec("UPDATE live_records SET body='' WHERE collection=?",col);return {state:'active'};
  });
 }
 if(command==='read'){
  collection();demand(state()?.state==='active','Verified baseline required',412);demand(validId(b.id),'Invalid record ID');
  const r=row(b.id);return {liveProtocol:1,schoolId:school,record:r&&r.body?JSON.parse(r.body):null,cursor:head(),...(r?{recordRevision:r.revision,driveRevision:r.drive_revision,payloadHash:r.payload_hash,source:r.body?'cloudflare':'drive'}:{source:'missing'})};
 }
 if(command==='commit'){
  collection();demand(state()?.state==='active','Verified baseline required',412);
  demand(validId(b.id)&&opId(b.operationId)&&['write','delete','patch'].includes(String(b.operation))&&typeof b.expectedRevision==='string'&&b.expectedRevision.length<=100,'Invalid live operation');
  clean(b.data);demand(byteLength(JSON.stringify(b))<=256000,'Live record too large',413);
  demand(b.createIntent===undefined||typeof b.createIntent==='boolean','Invalid create intent');
  const fingerprint=hash({collection:col,id:b.id,operation:b.operation,operationId:b.operationId,expectedRevision:b.expectedRevision,data:b.data??null,...(b.createIntent===true?{createIntent:true}:{})});
  return storage.transactionSync(()=>{
   const prior=sql.exec<{fingerprint:string;receipt:string}>('SELECT fingerprint,receipt FROM live_operations WHERE operation_id=?',String(b.operationId)).toArray()[0];
   if(prior){demand(prior.fingerprint===fingerprint,'Sync operation ID conflict',409);return JSON.parse(prior.receipt) as Json;}
   const current=row(String(b.id));
   // A purged baseline is supplied only by the broker's signed point read.
   // Verify it inside the same CAS transaction without caching it permanently.
   const baseline=b.baseline as Json|undefined;
   if(current&&!current.body)demand(baseline&&baseline.schoolId===school&&baseline._syncRevision===current.drive_revision&&payloadHash(baseline)===current.payload_hash,'Verified Drive baseline required',428);
   const old:Json=current?(current.body?JSON.parse(current.body):{...baseline,_syncRevision:current.revision}):{};let data:Json;
   if(current&&b.createIntent===true&&b.operation==='write'&&b.expectedRevision===''){
    demand(b.data&&typeof b.data==='object'&&!Array.isArray(b.data)&&(b.data as Json).schoolId===school&&old._syncDeleted!==true&&payloadHash(b.data as Json)===current.payload_hash,'Offline create differs; retain both versions for review',409);
    const backup=sql.exec<{state:string}>('SELECT state FROM live_backup WHERE collection=? AND id=? ORDER BY seq DESC LIMIT 1',col,String(b.id)).toArray()[0];
    const backedUp=!backup||backup.state==='verified';
    const receipt={liveProtocol:1,schoolId:school,cloudState:'committed',backupState:backedUp?'verified':'pending',recordRevision:current.revision,operationId:b.operationId,cursor:head(),record:backedUp?null:old,duplicate:true,resolution:'cloudRetained',reconcileRequired:true,...(backedUp?{source:'drive',driveRevision:current.drive_revision,payloadHash:current.payload_hash}:{})};
    sql.exec('INSERT INTO live_operations VALUES(?,?,?)',String(b.operationId),fingerprint,JSON.stringify(receipt));return receipt;
   }
   demand((current?.revision||'')===b.expectedRevision,'Record revision conflict',409);
   if(b.operation==='delete')data={schoolId:school,_syncDeleted:true};
   else {
    demand(b.data&&typeof b.data==='object'&&!Array.isArray(b.data)&&(b.data as Json).schoolId===school,'Foreign record',403);
    demand(!old._syncDeleted,'Explicit lifecycle recovery required',409);
    if(b.operation==='patch'){
     const patch=b.data as Json;demand(current&&patch.set&&typeof patch.set==='object'&&!Array.isArray(patch.set)&&Array.isArray(patch.remove),'Patch baseline required');
     const keys=[...Object.keys(patch.set),...(patch.remove as string[])];demand(keys.length<=256&&keys.every(k=>typeof k==='string'&&k.length>0&&k.length<=200&&!['id','schoolId','createdAt'].includes(k)&&!k.startsWith('_sync')),'Invalid patch');
     demand((patch.remove as string[]).every(k=>!Object.hasOwn(patch.set as object,k)),'Overlapping patch');
     data={...old,...patch.set as Json};for(const k of patch.remove as string[])delete data[k];
    }else data={...b.data as Json};
    demand(!Object.keys(b.data as Json).some(k=>k.startsWith('_sync')),'Client cannot set sync metadata');
   }
   if(current&&(b.operation==='delete'&&old._syncDeleted===true||b.operation!=='delete'&&old._syncDeleted!==true&&canonical(business(old))===canonical(business(data)))){
    const backup=sql.exec<{state:string}>('SELECT state FROM live_backup WHERE collection=? AND id=? ORDER BY seq DESC LIMIT 1',col,String(b.id)).toArray()[0];
    const backedUp=!backup||backup.state==='verified';
    const receipt={liveProtocol:1,schoolId:school,cloudState:'committed',backupState:backedUp?'verified':'pending',recordRevision:current.revision,operationId:b.operationId,cursor:head(),record:backedUp?null:old,unchanged:true,...(backedUp?{source:'drive',driveRevision:current.drive_revision,payloadHash:current.payload_hash,reconcileRequired:true}:{})};
    sql.exec('INSERT INTO live_operations VALUES(?,?,?)',String(b.operationId),fingerprint,JSON.stringify(receipt));return receipt;
   }
   demand(head()<1000000,'Live history capacity reached; retain local work',503);
   const revision='live-'+randomUUID();data={...business(data),...(b.operation==='delete'?{_syncDeleted:true}:{}),schoolId:school,_syncRevision:revision,_syncOperationId:b.operationId};
   const body=canonical(data);
   sql.exec('INSERT INTO live_events(collection,id,body,operation_id,fingerprint,receipt) VALUES(?,?,?,?,?,?)',col,String(b.id),body,String(b.operationId),fingerprint,'');
   const seq=head(),receipt={liveProtocol:1,schoolId:school,cloudState:'committed',backupState:'pending',recordRevision:revision,operationId:b.operationId,cursor:seq,record:data};
   sql.exec('UPDATE live_events SET receipt=? WHERE seq=?',JSON.stringify(receipt),seq);
   sql.exec('INSERT INTO live_operations VALUES(?,?,?)',String(b.operationId),fingerprint,JSON.stringify(receipt));
   sql.exec('INSERT INTO live_records(collection,id,body,revision,drive_revision,payload_hash) VALUES(?,?,?,?,?,?) ON CONFLICT(collection,id) DO UPDATE SET body=excluded.body,revision=excluded.revision,payload_hash=excluded.payload_hash',col,String(b.id),body,revision,current?.drive_revision||'',payloadHash(data));
   sql.exec("INSERT INTO live_backup(seq,collection,id,operation_id,operation,body,state,due) VALUES(?,?,?,?,?,?,'pending',?)",seq,col,String(b.id),String(b.operationId),b.operation==='delete'?'delete':'write',body,now);
   return receipt;
  });
 }
 if(command==='changes'){
  demand(Number.isSafeInteger(b.after)&&Number(b.after)>=0&&Number(b.after)<=head(),'Invalid cursor; snapshot required',409);
  const events:Json[]=[];let bytes=0;
  for(const r of sql.exec<{seq:number;collection:string;id:string;body:string}>('SELECT seq,collection,id,body FROM live_events WHERE seq>? ORDER BY seq LIMIT 100',Number(b.after))){
   const size=byteLength(r.body);if(bytes+size>300000&&events.length)break;bytes+=size;events.push({sequence:r.seq,collection:r.collection,id:r.id,...(r.body?{record:JSON.parse(r.body)}:{source:'drive',record:null})});
  }
  const cursor=events.length?Number(events[events.length-1].sequence):Number(b.after);return {liveProtocol:1,schoolId:school,events,cursor,head:head(),more:cursor<head()};
 }
 if(command==='snapshot'||command==='rollbackSnapshot'){
  collection();demand(state()?.state==='active'||command==='rollbackSnapshot'&&state()?.state==='legacy','Verified baseline required',412);demand((b.after===undefined||typeof b.after==='string')&&Number.isSafeInteger(b.at)&&b.at===head(),'Snapshot changed; restart snapshot',409);
  const records:Json[]=[];let bytes=0;
  for(const r of sql.exec<Row>('SELECT * FROM live_records WHERE collection=? AND id>? ORDER BY id LIMIT 100',col,String(b.after||''))){const size=byteLength(r.body);if(bytes+size>300000&&records.length)break;bytes+=size;records.push({id:r.id,record:r.body?JSON.parse(r.body):null,...(!r.body?{source:'drive',driveRevision:r.drive_revision,recordRevision:r.revision,payloadHash:r.payload_hash}:{})});}
  return {liveProtocol:1,schoolId:school,cursor:b.at,records,next:records.length?records[records.length-1].id:null};
 }
 if(command==='rollbackSeal'){
  collection();return storage.transactionSync(()=>{
   demand(Number.isSafeInteger(b.cursor)&&b.cursor===head(),'Rollback snapshot changed',409);
   demand(typeof b.fingerprint==='string'&&/^[a-f0-9]{64}$/.test(b.fingerprint),'Invalid rollback proof');
   const current=state();demand(current&&['active','legacy'].includes(current.state),'Rollback state unavailable',409);
   demand(sql.exec<{n:number}>("SELECT count(*) AS n FROM live_backup WHERE collection=? AND state!='verified'",col).toArray()[0].n===0,'Drive backup still pending',409);
   const rows=sql.exec<Row>('SELECT * FROM live_records WHERE collection=? ORDER BY id',col).toArray();
   demand(rows.every(r=>r.body===''&&r.drive_revision.length>0),'Temporary data still pending',409);
   const fingerprint=hash(rows.map(r=>({id:r.id,recordRevision:r.revision,driveRevision:r.drive_revision,payloadHash:r.payload_hash})));
   demand(fingerprint===b.fingerprint,'Rollback verification differs',409);
   sql.exec("UPDATE live_collections SET state='legacy' WHERE collection=?",col);
   return {liveProtocol:1,schoolId:school,collection:col,state:'legacy',cursor:head(),fingerprint,driveVerified:true,pending:0,needsAttention:0};
  });
 }
 if(command==='head')return {liveProtocol:1,schoolId:school,cursor:head(),collections:sql.exec<{collection:string;state:string;cursor:number}>('SELECT c.collection,c.state,coalesce(max(e.seq),0) AS cursor FROM live_collections c LEFT JOIN live_events e ON e.collection=c.collection GROUP BY c.collection,c.state').toArray()};
 if(command==='received'){
  demand(typeof b.device==='string'&&/^[a-f0-9]{64}$/.test(b.device)&&Number.isSafeInteger(b.cursor)&&Number(b.cursor)>=0&&Number(b.cursor)<=head(),'Invalid device receipt');
  sql.exec('INSERT INTO live_device_receipts VALUES(?,?,?) ON CONFLICT(device) DO UPDATE SET cursor=max(cursor,excluded.cursor),observed_at=excluded.observed_at',b.device,Number(b.cursor),now);return {received:true};
 }
 if(command==='backupClaim')return storage.transactionSync(()=>{
  const job=sql.exec<Job>("SELECT b.* FROM live_backup b WHERE b.state IN ('pending','retry','processing') AND b.due<=? AND NOT EXISTS(SELECT 1 FROM live_backup earlier WHERE earlier.collection=b.collection AND earlier.id=b.id AND earlier.seq<b.seq AND earlier.state!='verified') ORDER BY b.seq LIMIT 1",now).toArray()[0];
  if(!job)return {job:null};const claim=randomUUID();sql.exec("UPDATE live_backup SET state='processing',claim=?,claim_until=?,due=? WHERE seq=?",claim,now+120000,now+120000,job.seq);
  const current=sql.exec<Row>('SELECT * FROM live_records WHERE collection=? AND id=?',job.collection,job.id).toArray()[0];
  const data=JSON.parse(job.body) as Json;for(const k of Object.keys(data))if(k.startsWith('_sync'))delete data[k];
  return {job:{seq:job.seq,claim,request:{action:'managed_records',collection:job.collection,id:job.id,operation:job.operation,syncProtocol:2,operationId:job.operation_id,expectedRecordRevision:current.drive_revision,...(job.operation==='write'?{data}:{})}}};
 });
 if(command==='backupFinish')return storage.transactionSync(()=>{
  demand(Number.isSafeInteger(b.sequence)&&typeof b.claim==='string','Invalid backup receipt');
  const job=sql.exec<Job>('SELECT * FROM live_backup WHERE seq=?',Number(b.sequence)).toArray()[0];
  if(!job||job.state!=='processing'||job.claim!==b.claim||job.claim_until<=now)return {accepted:false};
  if(b.verified===true){
   demand(typeof b.driveRevision==='string'&&b.driveRevision.length>0&&b.driveRevision.length<=100&&!b.driveRevision.startsWith('live-')&&!b.driveRevision.startsWith('cf-'),'Unverified backup revision');
   sql.exec("UPDATE live_backup SET state='verified',drive_revision=?,claim='',claim_until=0,due=? WHERE seq=?",b.driveRevision,Number.MAX_SAFE_INTEGER,job.seq);
   sql.exec('UPDATE live_records SET drive_revision=? WHERE collection=? AND id=?',b.driveRevision,job.collection,job.id);
   const event=sql.exec<{receipt:string}>('SELECT receipt FROM live_events WHERE seq=?',job.seq).toArray()[0];
   const receipt=JSON.parse(event.receipt) as Json;
   const reference={...receipt,record:null,backupState:'verified',source:'drive',driveRevision:b.driveRevision,payloadHash:payloadHash(JSON.parse(job.body)),reconcileRequired:true};
   sql.exec("UPDATE live_events SET body='',receipt=? WHERE seq=?",JSON.stringify(reference),job.seq);
   sql.exec("UPDATE live_operations SET receipt=json_set(receipt,'$.record',null,'$.backupState','verified','$.source','drive','$.driveRevision',?,'$.payloadHash',?,'$.reconcileRequired',json('true')) WHERE json_extract(receipt,'$.recordRevision')=?",String(b.driveRevision),String(reference.payloadHash),String(receipt.recordRevision));
   sql.exec("UPDATE live_backup SET body='' WHERE seq=?",job.seq);
   // Old backup completion must never remove an unbacked newer local version.
   sql.exec("UPDATE live_records SET body='' WHERE collection=? AND id=? AND revision=?",job.collection,job.id,String(receipt.recordRevision));
  }else{
   demand(Number.isSafeInteger(b.retryAt)&&Number(b.retryAt)>now&&Number(b.retryAt)<=now+86400000,'Invalid backup retry');
   sql.exec("UPDATE live_backup SET state=?,due=?,claim='',claim_until=0 WHERE seq=?",b.review===true?'review':'retry',b.review===true?Number.MAX_SAFE_INTEGER:Number(b.retryAt),job.seq);
  }return {accepted:true};
 });
 if(command==='stats')return {liveProtocol:1,schoolId:school,cursor:head(),backups:sql.exec<{state:string;count:number;due:number}>('SELECT state,count(*) AS count,min(due) AS due FROM live_backup GROUP BY state').toArray(),payloadCopies:sql.exec<{records:number;events:number;backups:number;operations:number}>("SELECT (SELECT count(*) FROM live_records WHERE body!='') AS records,(SELECT count(*) FROM live_events WHERE body!='') AS events,(SELECT count(*) FROM live_backup WHERE body!='') AS backups,(SELECT count(*) FROM live_operations WHERE json_type(receipt,'$.record')='object') AS operations").toArray()[0]};
 throw Object.assign(Error('Unknown live command'),{status:400});
}

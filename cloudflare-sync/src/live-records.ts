import {domainCollections,personCollections,validateDomainCandidate,validatePersonCandidate} from './domain-policy';
import {createHash,randomUUID} from 'node:crypto';
import {canonical} from './spool';
import {demand,schoolPattern} from './protocol';
type Json=Record<string,unknown>;
type Row={collection:string;id:string;body:string;revision:string;drive_revision:string;payload_hash:string};
type Job={accepted_at:number;seq:number;collection:string;id:string;operation_id:string;operation:string;body:string;state:string;due:number;claim:string;claim_until:number;drive_revision:string|null};
// Collection support is negotiated separately from activation. Native lifecycle
// collections require the broker's dependency migration fence before admission.
export const liveCollections=new Set(['school_expenses','school_calendar','school_notices','school_settings',...domainCollections,...personCollections,'documents','student_scan_index','scanner_devices','school_config']);
const hash=(v:unknown)=>createHash('sha256').update(canonical(v)).digest('hex');
const business=(v:Json)=>Object.fromEntries(Object.entries(v).filter(([k])=>!k.startsWith('_sync')));
const payloadHash=(v:Json)=>hash({deleted:v._syncDeleted===true,data:business(v)});
const byteLength=(v:string)=>new TextEncoder().encode(v).byteLength;
export const cloudflareVerifiedRetentionMs=24*60*60*1000;
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
 // Existing replicas get the new event boundary columns without dropping any history.
 for(const [name,definition] of [['bundle_id','TEXT'],['bundle_size','INTEGER NOT NULL DEFAULT 0'],['bundle_index','INTEGER NOT NULL DEFAULT -1']] as const){
  if(!storage.sql.exec<{name:string}>('PRAGMA table_info(live_events)').toArray().some(c=>c.name===name))
   storage.sql.exec('ALTER TABLE live_events ADD COLUMN '+name+' '+definition);
 }
 storage.sql.exec('CREATE INDEX IF NOT EXISTS live_events_bundle ON live_events(bundle_id) WHERE bundle_id IS NOT NULL');
 storage.sql.exec('CREATE TABLE IF NOT EXISTS live_operations(operation_id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,receipt TEXT NOT NULL)');
 storage.sql.exec('CREATE TABLE IF NOT EXISTS live_bundles(bundle_id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,receipt TEXT NOT NULL)');
 storage.sql.exec("CREATE INDEX IF NOT EXISTS live_bundles_mobile_owner ON live_bundles(json_extract(receipt,'$.owner.role'),json_extract(receipt,'$.owner.personId'))");
 storage.sql.exec("CREATE TABLE IF NOT EXISTS live_backup(seq INTEGER PRIMARY KEY,collection TEXT NOT NULL,id TEXT NOT NULL,operation_id TEXT NOT NULL,operation TEXT NOT NULL,body TEXT NOT NULL,state TEXT NOT NULL,due INTEGER NOT NULL,claim TEXT NOT NULL DEFAULT '',claim_until INTEGER NOT NULL DEFAULT 0,drive_revision TEXT)");
 storage.sql.exec('CREATE INDEX IF NOT EXISTS live_backup_owner ON live_backup(collection,id,seq)');
 if(!storage.sql.exec<{name:string}>('PRAGMA table_info(live_backup)').toArray().some(c=>c.name==='accepted_at'))storage.sql.exec('ALTER TABLE live_backup ADD COLUMN accepted_at INTEGER NOT NULL DEFAULT 0');
 if(!storage.sql.exec<{name:string}>('PRAGMA table_info(live_backup)').toArray().some(c=>c.name==='verified_at'))storage.sql.exec('ALTER TABLE live_backup ADD COLUMN verified_at INTEGER NOT NULL DEFAULT 0');
 storage.sql.exec("CREATE TABLE IF NOT EXISTS live_record_owners(collection TEXT NOT NULL,id TEXT NOT NULL,body TEXT NOT NULL,PRIMARY KEY(collection,id))");
 if(!storage.sql.exec<{name:string}>('PRAGMA table_info(live_backup)').toArray().some(c=>c.name==='request_metadata'))storage.sql.exec("ALTER TABLE live_backup ADD COLUMN request_metadata TEXT NOT NULL DEFAULT '{}'");
 storage.sql.exec('CREATE TABLE IF NOT EXISTS live_backup_dependencies(sequence INTEGER NOT NULL,predecessor INTEGER NOT NULL,PRIMARY KEY(sequence,predecessor))');
 storage.sql.exec('CREATE TABLE IF NOT EXISTS live_device_receipts(device TEXT PRIMARY KEY,cursor INTEGER NOT NULL,observed_at INTEGER NOT NULL)');
 storage.sql.exec('CREATE TABLE IF NOT EXISTS live_collection_cursors(collection TEXT PRIMARY KEY,cursor INTEGER NOT NULL)');
 storage.sql.exec('INSERT OR IGNORE INTO live_collection_cursors SELECT collection,max(seq) FROM live_events GROUP BY collection');
 storage.sql.exec('CREATE TABLE IF NOT EXISTS live_retention(id INTEGER PRIMARY KEY,floor INTEGER NOT NULL)');
 storage.sql.exec('INSERT OR IGNORE INTO live_retention VALUES(1,0)');
}
const ownerFields=new Set(['schoolId','id','mobileStableId','teacherId','personId','studentId','studentDocId','studentDocumentId','teacherDocId','teacherDocumentId','documentId','oldStudentId','previousStudentId','previousStudentIds','employeeId','staffId','role','ownerRole','active','inactive','status','class','studentClass','section','rollNo','roll','replacesStudentGeneration','_syncDeleted','_syncDeletedOwner','_syncRetiredTeacherId','_syncRetiredStudentGenerations','_syncRetiredTeacherGenerations']);
function ownerMetadata(data:Json,id:string):Json {return {...Object.fromEntries(Object.entries(data).filter(([key])=>ownerFields.has(key))),id};}
function saveOwner(storage:DurableObjectStorage,col:string,id:string,data:Json){storage.sql.exec('INSERT INTO live_record_owners VALUES(?,?,?) ON CONFLICT(collection,id) DO UPDATE SET body=excluded.body',col,id,canonical(ownerMetadata(data,id)));}
function findOwner(storage:DurableObjectStorage,col:string,id:string):Json|null {
 const exact=storage.sql.exec<{body:string}>('SELECT body FROM live_record_owners WHERE collection=? AND id=?',col,id).toArray()[0];if(exact)return JSON.parse(exact.body) as Json;
 const matches=storage.sql.exec<{body:string}>("SELECT body FROM live_record_owners WHERE collection=? AND (json_extract(body,'$.mobileStableId')=? OR json_extract(body,'$.teacherId')=? OR json_extract(body,'$._syncDeletedOwner')=?) LIMIT 2",col,id,id,id).toArray();
 demand(matches.length<=1,'Ambiguous parent identity',409);return matches.length?JSON.parse(matches[0].body) as Json:null;
}
function appendLive(storage:DurableObjectStorage,school:string,col:string,id:string,operationId:string,operation:string,data:Json,now:number,fingerprint:string,metadata:Json={},bundleId:string|null=null,bundleSize=0,bundleIndex=-1){
 const sql=storage.sql,current=sql.exec<Row>('SELECT * FROM live_records WHERE collection=? AND id=?',col,id).toArray()[0];
 const revision='live-'+randomUUID(),lifecycle=Object.fromEntries(Object.entries(data).filter(([key])=>['_syncDeletedOwner','_syncRetiredTeacherId','_syncRetiredStudentGenerations','_syncRetiredTeacherGenerations'].includes(key)));
 data={...business(data),...lifecycle,...(operation==='delete'?{_syncDeleted:true}:{}),schoolId:school,_syncRevision:revision,_syncOperationId:operationId};const body=canonical(data);
 sql.exec('INSERT INTO live_events(collection,id,body,operation_id,fingerprint,receipt,bundle_id,bundle_size,bundle_index) VALUES(?,?,?,?,?,?,?,?,?)',col,id,body,operationId,fingerprint,'',bundleId,bundleSize,bundleIndex);
 const seq=sql.exec<{n:number}>("SELECT coalesce((SELECT seq FROM sqlite_sequence WHERE name='live_events'),0) AS n").toArray()[0].n;
 const receipt={liveProtocol:1,schoolId:school,cloudState:'committed',backupState:'pending',recordRevision:revision,operationId,cursor:seq,record:data};
 sql.exec('INSERT INTO live_collection_cursors VALUES(?,?) ON CONFLICT(collection) DO UPDATE SET cursor=excluded.cursor',col,seq);
 sql.exec('UPDATE live_events SET receipt=? WHERE seq=?',JSON.stringify(receipt),seq);sql.exec('INSERT INTO live_operations VALUES(?,?,?)',operationId,fingerprint,JSON.stringify(receipt));
 sql.exec('INSERT INTO live_records(collection,id,body,revision,drive_revision,payload_hash) VALUES(?,?,?,?,?,?) ON CONFLICT(collection,id) DO UPDATE SET body=excluded.body,revision=excluded.revision,payload_hash=excluded.payload_hash',col,id,body,revision,current?.drive_revision||'',payloadHash(data));
 sql.exec("INSERT INTO live_backup(seq,collection,id,operation_id,operation,body,state,due,accepted_at,request_metadata) VALUES(?,?,?,?,?,?,'pending',?,?,?)",seq,col,id,operationId,operation==='delete'?'delete':'write',body,now,now,canonical(metadata));saveOwner(storage,col,id,data);
 return {seq,receipt};
}
function ownsChild(kind:string,parentId:string,parent:Json,col:string,id:string,row:Json):boolean {
 const generation=String(parent.mobileStableId||parent.teacherId||parentId),teacher=row.role==='teacher'||row.ownerRole==='teacher';
 if(row._syncDeleted)return false;
 if(kind==='students_directory'){
  if(row.personId!=null)return row.personId===generation&&!teacher;
  if(teacher)return false;
  const aliases=[parentId,...(Array.isArray(parent.previousStudentIds)?parent.previousStudentIds:[])];
  return ['studentId','studentDocId','studentDocumentId','documentId','oldStudentId','previousStudentId'].some(key=>typeof row[key]==='string'&&aliases.includes(row[key]))||col==='student_scan_index'&&aliases.includes(id);
 }
 if(row.personId!=null)return row.personId===generation&&(teacher||typeof row.teacherId==='string');
 return typeof row.teacherId==='string'&&[parent.teacherId,parentId].includes(row.teacherId)||['teacherDocId','teacherDocumentId'].some(key=>row[key]===parentId);
}
function retireChildren(storage:DurableObjectStorage,school:string,col:string,id:string,parent:Json,operationId:string,now:number):number[]{
 const targets:{collection:string;id:string;data:Json}[]=[];
 for(const row of storage.sql.exec<{collection:string;id:string;body:string}>("SELECT collection,id,body FROM live_record_owners WHERE collection NOT IN ('students_directory','teachers_directory','staff_payroll_directory')")){
  const data=JSON.parse(row.body) as Json;if(!ownsChild(col,id,parent,row.collection,row.id,data))continue;
  demand(targets.length<5000,'Person cascade exceeds atomic limit; original work retained',413);
  demand(storage.sql.exec<{state:string}>('SELECT state FROM live_collections WHERE collection=?',row.collection).toArray()[0]?.state==='active','Person dependency baseline required',412);
  targets.push({collection:row.collection,id:row.id,data});
 }
 const predecessors:number[]=[];for(const target of targets){
  const childId='cascade-'+hash([operationId,target.collection,target.id]);
  const data={schoolId:school,_syncDeleted:true,_syncDeletedOwner:String(parent.mobileStableId||parent.teacherId||id)};
  const appended=appendLive(storage,school,target.collection,target.id,childId,'delete',data,now,hash([operationId,target.collection,target.id,'delete']),{deleteEverywhereVersion:1});predecessors.push(appended.seq);
 }
 return predecessors;
}
export function liveCommand(storage:DurableObjectStorage,school:string,b:Json,now=Date.now(),withinBundle=false,verifiedMedia?:Json,bundleId?:string,bundleSize=0,bundleIndex=-1):Json{
 demand(schoolPattern.test(school),'Invalid school');
 const sql=storage.sql,command=b.command,col=String(b.collection||'');
 const collection=()=>demand(liveCollections.has(col),'Collection not admitted to live authority',412);
 const head=()=>sql.exec<{n:number}>("SELECT coalesce((SELECT seq FROM sqlite_sequence WHERE name='live_events'),0) AS n").toArray()[0].n;
 const state=()=>sql.exec<{state:string;fingerprint:string;expected_count:number;source_revision:string}>('SELECT * FROM live_collections WHERE collection=?',col).toArray()[0];
 const row=(id:string)=>sql.exec<Row>('SELECT * FROM live_records WHERE collection=? AND id=?',col,id).toArray()[0];
 if(command==='seedBegin'){
  collection();demand(typeof b.fingerprint==='string'&&/^[a-f0-9]{64}$/.test(b.fingerprint)&&Number.isSafeInteger(b.count)&&Number(b.count)>=0&&Number(b.count)<=100000&&typeof b.sourceRevision==='string'&&b.sourceRevision.length>0&&b.sourceRevision.length<=100,'Invalid seed');
  const old=state();if(old){
   if(old.fingerprint===b.fingerprint&&old.expected_count===b.count&&old.source_revision===b.sourceRevision)return {state:old.state};
   demand(old.state==='seeding'&&b.replaceSeeding===true,'Seed identity changed; retain existing state',409);
   return storage.transactionSync(()=>{
    demand(sql.exec<{n:number}>('SELECT count(*) AS n FROM live_events WHERE collection=?',col).toArray()[0].n===0&&sql.exec<{n:number}>('SELECT count(*) AS n FROM live_backup WHERE collection=?',col).toArray()[0].n===0,'Committed collection cannot reseed',409);
    sql.exec('DELETE FROM live_records WHERE collection=?',col);sql.exec('UPDATE live_collections SET fingerprint=?,expected_count=?,source_revision=? WHERE collection=?',b.fingerprint,Number(b.count),b.sourceRevision,col);return {state:'seeding'};
   });
  }
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
   saveOwner(storage,col,entry.id,data);
   demand(col!=='school_settings'||entry.id!=='staff_payroll_directory','Staff lifecycle has its own owner',412);
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
  demand(col!=='school_settings'||b.id!=='staff_payroll_directory','Staff lifecycle has its own owner',412);
  collection();demand(state()?.state==='active','Verified baseline required',412);demand(validId(b.id),'Invalid record ID');
  const r=row(b.id);return {liveProtocol:1,schoolId:school,record:r&&r.body?JSON.parse(r.body):null,cursor:head(),...(r?{recordRevision:r.revision,driveRevision:r.drive_revision,payloadHash:r.payload_hash,source:r.body?'cloudflare':'drive'}:{source:'missing'})};
 }
 // A published file capability is valid only while its exact document
 // revision remains the current non-deleted school record. A later delete or
 // replacement must instantly retire the old Cloudflare read authority.
 const currentBundleDocument=(receipt:Json,bundleId:string):boolean=>{
  const refs=sql.exec<{id:string;revision:string;body:string;bundle_index:number}>(
   "SELECT r.id,r.revision,r.body,e.bundle_index FROM live_events e JOIN live_records r ON r.collection=e.collection AND r.id=e.id WHERE e.bundle_id=? AND e.collection='documents' LIMIT 2",
   bundleId).toArray();
  const a=receipt.acknowledgements;
  // Financial receipts have three original records (payment, ledger, PDF).
  // The current document must still be the *last* verified bundle member.
  return refs.length===1&&Array.isArray(a)&&a.length>=2&&a.length<=3&&
   refs[0].bundle_index===a.length-1&&
   refs[0].revision===(a[a.length-1] as Json).recordRevision&&
   (!refs[0].body||JSON.parse(refs[0].body)._syncDeleted!==true);
 };
 if(command==='ownerBundle'){
  // Internal only; the broker first verifies the student's own signed school
  // session. Query only the original school Durable Object's published receipts.
  demand(['student','teacher'].includes(String(b.role))&&
    typeof b.personId==='string'&&validId(b.personId),
    'Invalid mobile bundle owner',400);
  const row=sql.exec<{receipt:string}>(
   "SELECT receipt FROM live_bundles WHERE json_extract(receipt,'$.owner.role')=? AND json_extract(receipt,'$.owner.personId')=? ORDER BY rowid DESC LIMIT 1",
   String(b.role),String(b.personId)).toArray()[0];
  if(!row)return {bundleProtocol:1,schoolId:school,found:false};
  const saved=JSON.parse(row.receipt) as Json,files=saved.files as Json[];
  demand(saved.cloudState==='committed'&&saved.mediaReady===true&&
    saved.owner&&Array.isArray(files),'Published mobile bundle unavailable',412);
  if(!currentBundleDocument(saved,String(saved.bundleId)))
   return {bundleProtocol:1,schoolId:school,found:false};
  const card=files.filter(f=>f.kind==='idCard');
  demand(card.length===1&&typeof card[0].id==='string'&&
    /^[a-f0-9]{64}$/.test(card[0].id),'Published ID card proof unavailable',412);
  const photos=files.filter(f=>f.kind==='photo');
  demand(photos.length<=1&&photos.every(p=>
    typeof p.id==='string'&&/^[a-f0-9]{64}$/.test(p.id)&&
    typeof p.sha256==='string'&&/^[a-f0-9]{64}$/.test(p.sha256)&&
    ['image/jpeg','image/png','image/webp'].includes(String(p.mime))&&
    Number.isSafeInteger(p.sizeBytes)&&Number(p.sizeBytes)>0&&
    Number(p.sizeBytes)<=40*1024),
    'Published school portrait proof unavailable',412);
  return {bundleProtocol:1,schoolId:school,found:true,
    bundleId:saved.bundleId,id:card[0].id,sha256:card[0].sha256,
    sizeBytes:card[0].sizeBytes,mime:card[0].mime,
    archiveReady:saved.archiveReady===true,
    noPhoto:photos.length===0,
    ...(photos.length===1?{portrait:{
      id:photos[0].id,sha256:photos[0].sha256,mime:photos[0].mime,
      sizeBytes:photos[0].sizeBytes,
    }}:{})};
 }
 if(command==='ownerFinancialBundle'){
  // Internal school DO lookup. The broker MUST first verify the student's
  // signed session. A document ID alone is never sufficient authorization.
  demand(['feeReceipt','marksheet'].includes(String(b.role))&&
    typeof b.personId==='string'&&validId(b.personId)&&
    typeof b.documentId==='string'&&validId(b.documentId),
    'Invalid authenticated financial document identity',400);
  const row=sql.exec<{receipt:string}>(
   "SELECT b.receipt FROM live_bundles b JOIN live_events e ON e.bundle_id=b.bundle_id WHERE json_extract(b.receipt,'$.owner.role')=? AND json_extract(b.receipt,'$.owner.personId')=? AND e.collection='documents' AND e.id=? ORDER BY b.rowid DESC LIMIT 1",
   String(b.role),String(b.personId),String(b.documentId)).toArray()[0];
  if(!row)return {bundleProtocol:1,schoolId:school,found:false};
  const saved=JSON.parse(row.receipt) as Json,files=saved.files as Json[];
  if(saved.schoolId!==school||saved.cloudState!=='committed'||
     saved.mediaReady!==true||!Array.isArray(files)||
     !currentBundleDocument(saved,String(saved.bundleId)))
    return {bundleProtocol:1,schoolId:school,found:false};
  const kind=b.role==='feeReceipt'?'receipt':'marksheet';
  const pdf=files.filter(f=>f.kind===kind);
  demand(pdf.length===1&&pdf[0].mime==='application/pdf'&&
    typeof pdf[0].id==='string'&&/^[a-f0-9]{64}$/.test(pdf[0].id as string)&&
    typeof pdf[0].sha256==='string'&&/^[a-f0-9]{64}$/.test(pdf[0].sha256 as string)&&
    Number.isSafeInteger(pdf[0].sizeBytes)&&Number(pdf[0].sizeBytes)>0&&
    Number(pdf[0].sizeBytes)<=(kind==='receipt'?30*1024:150*1024),
    'Authenticated financial PDF proof unavailable',412);
  return {bundleProtocol:1,schoolId:school,found:true,
    bundleId:saved.bundleId,documentId:b.documentId,kind,id:pdf[0].id,
    sha256:pdf[0].sha256,sizeBytes:pdf[0].sizeBytes,mime:pdf[0].mime,
    archiveReady:saved.archiveReady===true};
 }
 if(command==='bundleArchiveManifest'){
  // Internal immutable publication identity for the backup delivery worker.
  demand(opId(b.bundleId),'Invalid bundle archive identity',400);
  const saved=sql.exec<{receipt:string}>(
    'SELECT receipt FROM live_bundles WHERE bundle_id=?',String(b.bundleId)).toArray()[0];
  demand(saved,'Published bundle required before archive handoff',404);
  const receipt=JSON.parse(saved.receipt) as Json;
  demand(receipt.schoolId===school&&receipt.cloudState==='committed'&&
    receipt.mediaReady===true&&Array.isArray(receipt.files)&&
    (receipt.files as Json[]).length>=1,'Invalid published archive manifest',412);
  return {bundleProtocol:1,schoolId:school,bundleId:b.bundleId,
    mediaManifestHash:receipt.mediaManifestHash,
    files:(receipt.files as Json[]).map(f=>({kind:f.kind,id:f.id,
      sha256:f.sha256,sizeBytes:f.sizeBytes,mime:f.mime}))};
 }
 if(command==='bundleMedia'){
  // The published atomic group is the sole capability to retrieve the
  // original school-scoped Cloudflare bytes. Unpublished/staged files are
  // never addressable by guessing an upload ID.
  demand(opId(b.bundleId)&&['idCard','photo','receipt','marksheet'].includes(String(b.kind))&&
    typeof b.id==='string'&&/^[a-f0-9]{64}$/.test(b.id),
    'Invalid atomic media lookup',400);
  const row=sql.exec<{receipt:string}>(
    'SELECT receipt FROM live_bundles WHERE bundle_id=?',String(b.bundleId)).toArray()[0];
  demand(row,'Atomic media bundle is not published',404);
  const receipt=JSON.parse(row.receipt) as Json;
  demand(receipt.schoolId===school&&receipt.cloudState==='committed'&&
    receipt.mediaReady===true&&Array.isArray(receipt.files),
    'Atomic media bundle is unavailable',412);
  demand(currentBundleDocument(receipt,String(b.bundleId)),
    'The published ID was replaced or deleted',409);
  const found=(receipt.files as Json[]).filter(f=>f.id===b.id&&f.kind===b.kind);
  demand(found.length===1&&/^[a-f0-9]{64}$/.test(String(found[0].sha256||''))&&
    Number.isSafeInteger(found[0].sizeBytes)&&Number(found[0].sizeBytes)>0&&
    Number(found[0].sizeBytes)<=(b.kind==='photo'?40*1024:
      b.kind==='receipt'?30*1024:b.kind==='marksheet'?150*1024:85*1024),
    'Requested media is not part of the published atomic group',403);
  return {bundleProtocol:1,schoolId:school,bundleId:b.bundleId,
    id:b.id,kind:b.kind,sha256:found[0].sha256,
    sizeBytes:found[0].sizeBytes,mime:found[0].mime,
    archiveReady:receipt.archiveReady===true,
    ownerRole:(receipt.owner as Json)?.role,personId:(receipt.owner as Json)?.personId,
    ...(typeof found[0].fileId==='string'?{fileId:found[0].fileId}:{})};
 }
 if(command==='bundleReceipt'){
  demand(opId(b.bundleId)&&Array.isArray(b.operations)&&Array.isArray(b.media)&&
    typeof b.mediaManifestHash==='string','Invalid bundle replay identity');
  const fingerprint=hash({schoolId:school,bundleId:b.bundleId,operations:b.operations,
    media:b.media,mediaManifestHash:b.mediaManifestHash});
  const prior=sql.exec<{fingerprint:string;receipt:string}>(
    'SELECT fingerprint,receipt FROM live_bundles WHERE bundle_id=?',String(b.bundleId)).toArray()[0];
  if(!prior)return {found:false,bundleProtocol:1,schoolId:school};
  demand(prior.fingerprint===fingerprint,'Atomic bundle replay changed',409);
  const receipt=JSON.parse(prior.receipt) as Json;
  const listed=receipt.acknowledgements as Json[];
  demand(Array.isArray(listed)&&listed.length===(b.operations as Json[]).length,
    'Atomic receipt lost operation boundary',412);
  const states=listed.map((ack,index)=>{
   const expected=(b.operations as Json[])[index];
   demand(ack.operationId===expected.operationId&&
     typeof ack.recordRevision==='string','Atomic operation identity changed',409);
   const backup=sql.exec<{state:string;drive_revision:string|null;verified_at:number}>(
     'SELECT state,drive_revision,verified_at FROM live_backup WHERE operation_id=? AND collection=? AND id=? ORDER BY seq DESC LIMIT 1',
     String(expected.operationId),String(expected.collection),String(expected.id)).toArray()[0];
   demand(backup,'Atomic operation has no durable backup job',412);
   return {operationId:expected.operationId,
     recordRevision:ack.recordRevision,collection:expected.collection,id:expected.id,
     backupState:backup.state,
     driveVerified:backup.state==='verified'&&
       typeof backup.drive_revision==='string'&&backup.drive_revision.length>0,
     ...(backup.state==='verified'&&typeof backup.drive_revision==='string'?
       {driveRevision:backup.drive_revision,verifiedAt:backup.verified_at}:{})};
  });
  return {found:true,bundleProtocol:1,schoolId:school,
    receipt,backups:states,driveVerified:states.every(r=>r.driveVerified===true),
    cloudState:receipt.cloudState,mediaReady:receipt.mediaReady===true};
 }
 if(command==='bundleCommit'){
  // First safe increment of the existing live authority: atomic *record*
  // groups. Uploaded photo/PDF bytes are not in this transaction, so media
  // collections and people/financial lifecycles remain closed until a signed
  // cross-lane staged-file manifest owner has been verified. No new queue.
  demand(!withinBundle,'Nested bundle rejected');
  demand(opId(b.bundleId)&&Array.isArray(b.operations)&&b.operations.length>=2&&b.operations.length<=5,'Invalid atomic bundle');
  demand(b.files===undefined&&b.fileReferences===undefined,'Unverified media references',412);
  if(verifiedMedia){
   demand(Array.isArray(b.media)&&b.media.length>=1&&b.media.length<=2&&
     verifiedMedia.mediaReady===true&&
     verifiedMedia.manifestHash===b.mediaManifestHash&&
     Array.isArray(verifiedMedia.proofs)&&verifiedMedia.proofs.length===b.media.length,
     'Immutable staged media proof required',412);
  }else demand(b.media===undefined&&b.mediaManifestHash===undefined,
    'Media bundle staging not yet verified',412);
  demand(byteLength(JSON.stringify(b))<=256000,'Atomic bundle too large',413);
  const allowed=verifiedMedia?new Set(['students_directory','teachers_directory','fee_payments','fee_ledger','exam_results','exam_center_results','documents']):
   new Set(['school_notices','school_calendar','school_settings','school_expenses']);
  let archiveFiles:Json[]=[],bundleOwner:Json|undefined;
  if(verifiedMedia){
   const ops=b.operations as Json[];
   const kind=String((verifiedMedia.proofs as Json[])[0]?.kind||'');
   const personKind=kind==='idCard',feeKind=kind==='receipt',examKind=kind==='marksheet';
   const count=feeKind?3:2;
   demand((personKind||feeKind||examKind)&&ops.length===count&&
     ops.every(op=>op.operation==='write')&&
     ops[count-1].collection==='documents',
     'Original business record and PDF must commit in one complete group',412);
   const first=ops[0],last=ops[count-1],head=first.data as Json,
     child=last.data as Json;
   demand(head&&child&&head.schoolId===school&&child.schoolId===school&&
     [head,child].every(d=>!Object.hasOwn(d,'bundleMedia')&&!Object.hasOwn(d,'bundleId')),
     'Client cannot supply verified media metadata',403);
   const proofs=verifiedMedia.proofs as Json[];
   demand(proofs[0].kind===kind&&proofs.every(p=>
     typeof p.sha256==='string'&&/^[a-f0-9]{64}$/.test(p.sha256)&&
     (p.driveVerified!==true ||
       typeof p.fileId==='string'&&/^[A-Za-z0-9_-]{1,200}$/.test(p.fileId)))&&
     (personKind?(proofs.length===1||proofs.length===2&&proofs[1].kind==='photo'):
       proofs.length===1&&proofs[0].mime==='application/pdf'),
     'Original media proof does not match bundle type',412);
   if(personKind){
     // A bundled Person MUST NOT contain another photo source outside the
     // immutable staged portrait. Otherwise a peer could display or back up
     // a different image while the bundle receipt claims one atomic photo.
     // Keep empty optional input fields for legacy no-photo creates.
     const unstagedPortrait=(value:unknown,depth=0):boolean=>{
       if(depth>12)return true;
       if(typeof value==='string')return value.trimStart().startsWith('data:image/');
       if(Array.isArray(value))return value.some(item=>unstagedPortrait(item,depth+1));
       if(value&&typeof value==='object'){
         for(const [key,item] of Object.entries(value as Record<string,unknown>)){
           if(/^(?:photo(?:url|base64|fileid|path|uri|mimetype|sourcehash)|portrait(?:url|base64|fileid|path|uri)|imagebase64)$/i.test(key)&&
              item!==null&&item!==undefined&&
              (typeof item!=='string'||item.trim().length>0))return true;
           if(unstagedPortrait(item,depth+1))return true;
         }
       }
       return false;
     };
     demand(personCollections.has(String(first.collection))&&
       !Object.hasOwn(head,'atomicPortrait')&&!unstagedPortrait(head),
       'Person photo must be staged with the original atomic portrait',412);
     const teacher=first.collection==='teachers_directory';
     demand(typeof head.mobileStableId==='string'&&
       /^p-[a-f0-9]{32,64}$/.test(head.mobileStableId),
       'Original person generation required for an ID bundle',409);
     const generation=String(head.mobileStableId);
     demand(child.personId===generation&&child.ownerRole===(teacher?'teacher':'student')&&
       child.studentId===first.id&&
       (teacher?child.teacherId===first.id:
         child.teacherId===undefined)&&
       child.documentKind==='idCard'&&child.documentId===last.id&&
       child.documentRevision===last.operationId&&
       child.contentHash===proofs[0].sha256&&
       child.mimeType==='application/pdf'&&
       child.sizeBytes===proofs[0].sizeBytes,
       'ID document must match the exact owner generation and staged PDF',409);
     bundleOwner={role:teacher?'teacher':'student',personId:generation};
   }else{
     demand(head.studentId!==undefined&&typeof head.studentId==='string'&&
       head.studentId.length>0&&head.studentId.length<=200&&
       typeof child.personId==='string'&&child.personId.length>0&&
       (head.personId===undefined||head.personId===child.personId)&&
       child.studentId===head.studentId&&
       child.ownerRole==='student'&&
       child.contentHash===proofs[0].sha256&&
       child.mimeType==='application/pdf',
       'School receipt/marksheet has no matching student or byte hash',409);
     if(feeKind){
       const ledger=ops[1].data as Json;
       demand(first.collection==='fee_payments'&&ops[1].collection==='fee_ledger'&&
         head.paymentId===first.id&&head.receiptDocumentId===last.id&&
         child.documentKind==='feeReceipt'&&
         ledger&&ledger.schoolId===school&&
         ledger.studentId===head.studentId&&
         (ledger.personId===undefined||ledger.personId===child.personId)&&
         ledger.lastPaymentId===first.id&&ledger.month===head.month&&
         typeof head.month==='string'&&head.month.length>0&&
         typeof head.totalPaid==='number'&&Number.isFinite(head.totalPaid)&&
         typeof head.expectedAmount==='number'&&Number.isFinite(head.expectedAmount)&&
         typeof head.installmentAmount==='number'&&Number.isFinite(head.installmentAmount)&&
         head.installmentAmount>0&&head.totalPaid<=head.expectedAmount&&
         ledger.totalPaid===head.totalPaid&&
         ledger.expectedAmount===head.expectedAmount&&
         !Object.hasOwn(ledger,'bundleMedia')&&!Object.hasOwn(ledger,'bundleId'),
         'Fee ledger, original payment and receipt must agree',409);
     }else{
       demand(['exam_results','exam_center_results'].includes(String(first.collection))&&
         child.documentKind==='marksheet'&&
         (child.examResultId===first.id||head.marksheetDocumentId===last.id)&&
         typeof first.id==='string'&&
         first.id.length>0,
         'Exam result and original marksheet must agree',409);
     }
     // These financial owners must not appear as a student ID-card owner.
     bundleOwner={role:feeKind?'feeReceipt':'marksheet',personId:child.personId};
   }
   archiveFiles=proofs.map(p=>({kind:p.kind,id:p.id,
     ...(p.driveVerified===true?{fileId:p.fileId}:{}),
     sha256:p.sha256,sizeBytes:p.sizeBytes,mime:p.mime}));
   demand(child.fileId===undefined||
     (proofs[0].driveVerified===true&&child.fileId===proofs[0].fileId),
     'Original PDF fileId cannot be invented before Drive ACK',409);
  }
  const operationIds=new Set<string>(),recordKeys=new Set<string>();
  for(const item of b.operations as Json[]){
   demand(item&&typeof item==='object'&&!Array.isArray(item),'Invalid bundled record');
   demand(Object.keys(item).every(k=>['collection','id','operation','operationId','expectedRevision','data','createIntent','deleteEverywhereVersion'].includes(k)),'Unknown bundle operation field');
   demand(typeof item.collection==='string'&&allowed.has(item.collection),'Unverified person, document or financial bundle',412);
   demand(validId(item.id)&&opId(item.operationId)&&typeof item.expectedRevision==='string'&&['write','delete','patch'].includes(String(item.operation)),'Invalid bundled operation');
   const key=item.collection+'/'+item.id;
   demand(!recordKeys.has(key)&&!operationIds.has(item.operationId),'Duplicate bundle record/operation',409);
   recordKeys.add(key);operationIds.add(String(item.operationId));
  }
  const fingerprint=hash({schoolId:school,bundleId:b.bundleId,operations:b.operations,
    ...(verifiedMedia?{media:b.media,mediaManifestHash:b.mediaManifestHash}:{})});
  return storage.transactionSync(()=>{
   const prior=sql.exec<{fingerprint:string;receipt:string}>('SELECT fingerprint,receipt FROM live_bundles WHERE bundle_id=?',String(b.bundleId)).toArray()[0];
   if(prior){demand(prior.fingerprint===fingerprint,'Atomic bundle replay changed',409);return JSON.parse(prior.receipt) as Json;}
   // A previously committed single-record operation must never be relabeled
   // as a new atomic bundle: peers could already have seen it independently.
   for(const id of operationIds)demand(
    sql.exec<{operation_id:string}>('SELECT operation_id FROM live_operations WHERE operation_id=?',id).toArray().length===0,
    'An existing operation cannot be repackaged as an atomic bundle',409);
   const acknowledgements=(b.operations as Json[]).map((item,index)=>
    liveCommand(storage,school,{...item,command:'commit',
     ...(verifiedMedia&&['students_directory','teachers_directory'].includes(String((b.operations as Json[])[0].collection))&&index===0&&archiveFiles.length===2?{
       data:{...(item.data as Json),atomicPortrait:{
         bundleId:b.bundleId,documentId:(b.operations as Json[])[1].id,
         role:bundleOwner?.role,
         id:archiveFiles[1].id,sha256:archiveFiles[1].sha256,
         mime:archiveFiles[1].mime,sizeBytes:archiveFiles[1].sizeBytes,
       }}
     }:{}),
     ...(verifiedMedia&&index===(b.operations as Json[]).length-1?{data:{...(item.data as Json),bundleMedia:archiveFiles,
       bundleManifestHash:b.mediaManifestHash,bundleId:b.bundleId,
       ...(archiveFiles[0].fileId?{fileId:archiveFiles[0].fileId}:{})}}:{})},
       now,true,undefined,String(b.bundleId),(b.operations as Json[]).length,index));
   // A no-op or offline duplicate can produce no event. It must never
   // count towards the number of visible records promised by a bundle.
   demand(acknowledgements.every(r=>r.unchanged!==true&&r.duplicate!==true),
     'Atomic bundle contains a no-op or duplicate; reconcile before publishing',409);
   const receipt={bundleProtocol:1,liveProtocol:1,schoolId:school,bundleId:b.bundleId,
    cloudState:'committed',backupState:acknowledgements.every(r=>r.backupState==='verified')?'verified':'pending',
    cursor:head(),manifestHash:fingerprint,
    ...(verifiedMedia?{mediaReady:true,archiveReady:verifiedMedia.archiveReady===true,mediaManifestHash:b.mediaManifestHash,
      files:archiveFiles,owner:bundleOwner}:{}),
    acknowledgements:acknowledgements.map(r=>({operationId:r.operationId,
      recordRevision:r.recordRevision,cloudState:r.cloudState,backupState:r.backupState,
      cursor:r.cursor,unchanged:r.unchanged===true}))};
   sql.exec('INSERT INTO live_bundles VALUES(?,?,?)',String(b.bundleId),fingerprint,JSON.stringify(receipt));
   return receipt;
  });
 }
 if(command==='commit'){
  demand(col!=='school_settings'||b.id!=='staff_payroll_directory','Staff lifecycle has its own owner',412);
  collection();demand(state()?.state==='active','Verified baseline required',412);
  demand(validId(b.id)&&opId(b.operationId)&&['write','delete','patch'].includes(String(b.operation))&&typeof b.expectedRevision==='string'&&b.expectedRevision.length<=100,'Invalid live operation');
  clean(b.data);demand(byteLength(JSON.stringify(b))<=256000,'Live record too large',413);
  demand(b.createIntent===undefined||typeof b.createIntent==='boolean','Invalid create intent');
  const fingerprint=hash({collection:col,id:b.id,operation:b.operation,operationId:b.operationId,expectedRevision:b.expectedRevision,data:b.data??null,...(b.deleteEverywhereVersion===1?{deleteEverywhereVersion:1}:{}),...(b.createIntent===true?{createIntent:true}:{})});
  const commitOne=()=>{
   const prior=sql.exec<{fingerprint:string;receipt:string}>('SELECT fingerprint,receipt FROM live_operations WHERE operation_id=?',String(b.operationId)).toArray()[0];
   if(prior){demand(prior.fingerprint===fingerprint,'Sync operation ID conflict',409);return JSON.parse(prior.receipt) as Json;}
   const current=row(String(b.id));
   // A purged baseline is supplied only by the broker's signed point read.
   // Verify it inside the same CAS transaction without caching it permanently.
   const baseline=b.baseline as Json|undefined;
   if(current&&!current.body)demand(baseline&&baseline.schoolId===school&&baseline._syncRevision===current.drive_revision&&payloadHash(baseline)===current.payload_hash,'Verified Drive baseline required',428);
   const old:Json=current?(current.body?JSON.parse(current.body):{...baseline,_syncRevision:current.revision}):{};let data:Json;
   if(current&&!domainCollections.has(col)&&b.createIntent===true&&b.operation==='write'&&b.expectedRevision===''){
    demand(b.data&&typeof b.data==='object'&&!Array.isArray(b.data)&&(b.data as Json).schoolId===school&&old._syncDeleted!==true&&payloadHash(b.data as Json)===current.payload_hash,'Offline create differs; retain both versions for review',409);
    const backup=sql.exec<{state:string}>('SELECT state FROM live_backup WHERE collection=? AND id=? ORDER BY seq DESC LIMIT 1',col,String(b.id)).toArray()[0];
    const backedUp=!backup||backup.state==='verified';
    const receipt={liveProtocol:1,schoolId:school,cloudState:'committed',backupState:backedUp?'verified':'pending',recordRevision:current.revision,operationId:b.operationId,cursor:head(),record:current.body?old:null,duplicate:true,resolution:'cloudRetained',reconcileRequired:true,...(backedUp?{source:current.body?'cloudflare':'drive',driveRevision:current.drive_revision,payloadHash:current.payload_hash}:{})};
    sql.exec('INSERT INTO live_operations VALUES(?,?,?)',String(b.operationId),fingerprint,JSON.stringify(receipt));return receipt;
   }
   demand((current?.revision||'')===b.expectedRevision,'Record revision conflict',409);
   if(b.operation==='delete')data={schoolId:school,_syncDeleted:true};
   else {
    demand(b.data&&typeof b.data==='object'&&!Array.isArray(b.data)&&(b.data as Json).schoolId===school,'Foreign record',403);
    demand(!old._syncDeleted||personCollections.has(col),'Explicit lifecycle recovery required',409);
    if(b.operation==='patch'){
     const patch=b.data as Json;demand(current&&patch.set&&typeof patch.set==='object'&&!Array.isArray(patch.set)&&Array.isArray(patch.remove),'Patch baseline required');
     const keys=[...Object.keys(patch.set),...(patch.remove as string[])];demand(keys.length<=256&&keys.every(k=>typeof k==='string'&&k.length>0&&k.length<=200&&!['id','schoolId','createdAt'].includes(k)&&!k.startsWith('_sync')),'Invalid patch');
     demand((patch.remove as string[]).every(k=>!Object.hasOwn(patch.set as object,k)),'Overlapping patch');
     data={...old,...patch.set as Json};for(const k of patch.remove as string[])delete data[k];
    }else data={...b.data as Json};
    demand(!Object.keys(b.data as Json).some(k=>k.startsWith('_sync')),'Client cannot set sync metadata');
   }
   const readOwner=(collection:string,id:string)=>findOwner(storage,collection,id);
   const readPeers=(collection:string)=>storage.sql.exec<{body:string}>('SELECT body FROM live_record_owners WHERE collection=?',collection).toArray().map(row=>JSON.parse(row.body) as Json);
   if(domainCollections.has(col))validateDomainCandidate({schoolId:school,collection:col,id:String(b.id),operation:String(b.operation),current:current?old:null,next:data,readOwner});
   if(personCollections.has(col))validatePersonCandidate({schoolId:school,collection:col,id:String(b.id),operation:String(b.operation),current:current?old:null,next:data,readPeers});
   if(current&&(b.operation==='delete'&&old._syncDeleted===true||b.operation!=='delete'&&old._syncDeleted!==true&&canonical(business(old))===canonical(business(data)))){
    const backup=sql.exec<{state:string}>('SELECT state FROM live_backup WHERE collection=? AND id=? ORDER BY seq DESC LIMIT 1',col,String(b.id)).toArray()[0];
    const backedUp=!backup||backup.state==='verified';
    const receipt={liveProtocol:1,schoolId:school,cloudState:'committed',backupState:backedUp?'verified':'pending',recordRevision:current.revision,operationId:b.operationId,cursor:head(),record:current.body?old:null,unchanged:true,...(backedUp?{source:current.body?'cloudflare':'drive',driveRevision:current.drive_revision,payloadHash:current.payload_hash,reconcileRequired:true}:{})};
    sql.exec('INSERT INTO live_operations VALUES(?,?,?)',String(b.operationId),fingerprint,JSON.stringify(receipt));return receipt;
   }
   demand(sql.exec<{n:number}>('SELECT count(*) AS n FROM live_events').toArray()[0].n<1000000,'Live history capacity reached; retain local work',503);
   const parentGeneration=String(old.mobileStableId||old.teacherId||b.id),nextGeneration=String(data.mobileStableId||data.teacherId||b.id);
   // Generation replacement can emit thousands of cascade tombstones.
   // Keep it outside the bounded 2–5-record bundle until its full dependency
   // graph is represented by one immutable manifest.
   if(withinBundle&&personCollections.has(col)&&current)
    demand(nextGeneration===parentGeneration,
      'Person generation replacement requires separate lifecycle repair',412);
   const retiring=personCollections.has(col)&&current&&(b.operation==='delete'||nextGeneration!==parentGeneration);
   const dependencies=retiring?retireChildren(storage,school,col,String(b.id),old,String(b.operationId),now):[];
   if(personCollections.has(col)){
    const retiredKey=col==='students_directory'?'_syncRetiredStudentGenerations':'_syncRetiredTeacherGenerations';
    const retired=new Set(Array.isArray(old[retiredKey])?old[retiredKey] as string[]:[]);if(retiring)retired.add(parentGeneration);
    if(retired.size)data[retiredKey]=[...retired];if(b.operation==='delete'){data._syncDeletedOwner=parentGeneration;if(col==='teachers_directory')data._syncRetiredTeacherId=old.teacherId||b.id;}
   }
   const appended=appendLive(storage,school,col,String(b.id),String(b.operationId),String(b.operation),data,now,fingerprint,{...(b.deleteEverywhereVersion===1?{deleteEverywhereVersion:1}:{}),...(col==='students_directory'&&b.operation==='delete'?{deletedStudentGeneration:parentGeneration}:{})},bundleId||null,bundleSize,bundleIndex);
   for(const predecessor of dependencies)sql.exec('INSERT OR IGNORE INTO live_backup_dependencies VALUES(?,?)',appended.seq,predecessor);
   // Parent registration must be durably handed to Drive before its dependent
   // child can reach the old lifecycle engine. Acceptance at the edge is atomic.
   if(!personCollections.has(col)&&b.operation!=='delete'){
    const teacher=data.role==='teacher'||data.ownerRole==='teacher'||['teacher_salary','teacher_attendance','teacher_schedules'].includes(col);
    const ownerId=String(teacher?(data.teacherId||data.personId||''):(data.studentId||''));
    const ownerCol=teacher?'teachers_directory':'students_directory',owner=ownerId?readOwner(ownerCol,ownerId):null;
    if(owner){const parent=sql.exec<{seq:number}>("SELECT seq FROM live_backup WHERE collection=? AND id=? AND state!='verified' ORDER BY seq DESC LIMIT 1",ownerCol,String(owner.id)).toArray()[0];if(parent)sql.exec('INSERT OR IGNORE INTO live_backup_dependencies VALUES(?,?)',appended.seq,parent.seq);}
   }
   return appended.receipt;
  };
  return withinBundle?commitOne():storage.transactionSync(commitOne);
 }
 if(command==='changes'){
  demand(Number.isSafeInteger(b.after)&&Number(b.after)>=0&&Number(b.after)<=head(),'Invalid cursor; snapshot required',409);
  demand(Number(b.after)>=sql.exec<{floor:number}>('SELECT floor FROM live_retention WHERE id=1').toArray()[0].floor,'Replay history compacted; snapshot required',409);
  // Only emit complete bundle boundaries. Legacy receivers can reconcile each
  // ordinary event, but a person/document bundle must never be split by a
  // 100-event or 300-KiB replay page. Five lookahead rows are enough because
  // the maximum bundle size is five.
  const rows=sql.exec<{seq:number;collection:string;id:string;body:string;bundle_id:string|null;bundle_size:number;bundle_index:number}>(
   'SELECT seq,collection,id,body,bundle_id,bundle_size,bundle_index FROM live_events WHERE seq>? ORDER BY seq LIMIT 105',Number(b.after)).toArray();
  const events:Json[]=[];let bytes=0;
  for(let i=0;i<rows.length;){
   const first=rows[i],count=first.bundle_id?first.bundle_size:1;
   demand(Number.isSafeInteger(count)&&count>=1&&count<=5&&
     (!first.bundle_id||first.bundle_index===0)&&i+count<=rows.length,
     'Atomic replay boundary invalid; recover a verified snapshot',409);
   const group=rows.slice(i,i+count);
   if(first.bundle_id)for(let j=0;j<count;j++)
    demand(group[j].bundle_id===first.bundle_id&&
      group[j].bundle_size===count&&group[j].bundle_index===j&&
      group[j].seq===first.seq+j,
      'Atomic replay group incomplete; recover a verified snapshot',409);
   const groupBytes=group.reduce((total,r)=>total+byteLength(r.body),0);
   demand(groupBytes<=300000,'Atomic replay group exceeds the delivery budget',413);
   if(events.length&&(events.length+count>100||bytes+groupBytes>300000))break;
   bytes+=groupBytes;
   for(const r of group)events.push({sequence:r.seq,collection:r.collection,id:r.id,
    ...(r.bundle_id?{bundleId:r.bundle_id,bundleSize:r.bundle_size,bundleIndex:r.bundle_index}:{}),
    ...(r.body?{record:JSON.parse(r.body)}:{source:'drive',record:null})});
   i+=count;
  }
  const cursor=events.length?Number(events[events.length-1].sequence):Number(b.after);return {liveProtocol:1,schoolId:school,events,cursor,head:head(),more:cursor<head()};
 }
 if(command==='snapshot'||command==='rollbackSnapshot'){
  collection();demand(state()?.state==='active'||command==='rollbackSnapshot'&&state()?.state==='legacy','Verified baseline required',412);demand((b.after===undefined||typeof b.after==='string')&&Number.isSafeInteger(b.at)&&b.at===head(),'Snapshot changed; restart snapshot',409);
  const records:Json[]=[];let bytes=0;
  for(const r of sql.exec<Row>('SELECT * FROM live_records WHERE collection=? AND id>? ORDER BY id LIMIT 100',col,String(b.after||''))){const size=byteLength(r.body);if(bytes+size>300000&&records.length)break;bytes+=size;records.push({id:r.id,record:r.body?JSON.parse(r.body):null,source:r.body?'cloudflare':'drive',driveRevision:r.drive_revision,recordRevision:r.revision,payloadHash:r.payload_hash});}
  return {liveProtocol:1,schoolId:school,cursor:b.at,records,next:records.length?records[records.length-1].id:null};
 }
 if(command==='rollbackSeal'){
  collection();return storage.transactionSync(()=>{
   demand(Number.isSafeInteger(b.cursor)&&b.cursor===head(),'Rollback snapshot changed',409);
   demand(typeof b.fingerprint==='string'&&/^[a-f0-9]{64}$/.test(b.fingerprint),'Invalid rollback proof');
   const current=state();demand(current&&['active','legacy'].includes(current.state),'Rollback state unavailable',409);
   demand(sql.exec<{n:number}>("SELECT count(*) AS n FROM live_backup WHERE collection=? AND state!='verified'",col).toArray()[0].n===0,'Drive backup still pending',409);
   const rows=sql.exec<Row>('SELECT * FROM live_records WHERE collection=? ORDER BY id',col).toArray();
   // An explicit signed rollback may retire a verified 24h cache early,
   // but only after the broker read and hashed the exact Drive state.
   demand(rows.every(r=>r.drive_revision.length>0),'Drive storage not verified',409);
   const fingerprint=hash(rows.map(r=>({id:r.id,recordRevision:r.revision,driveRevision:r.drive_revision,payloadHash:r.payload_hash})));
   demand(fingerprint===b.fingerprint,'Rollback verification differs',409);
   // Rollback is an explicit authority retirement, not TTL garbage collection.
   // Clear only this verified collection in the same transaction as sealing.
   sql.exec("UPDATE live_events SET body='',receipt=json_set(receipt,'$.record',null,'$.source','drive') WHERE collection=?",col);
   sql.exec("UPDATE live_backup SET body='' WHERE collection=? AND state='verified'",col);
   sql.exec("UPDATE live_operations SET receipt=json_set(receipt,'$.record',null,'$.source','drive','$.backupState','verified') WHERE json_extract(receipt,'$.recordRevision') IN (SELECT json_extract(receipt,'$.recordRevision') FROM live_events WHERE collection=?)",col);
   sql.exec("UPDATE live_records SET body='' WHERE collection=? AND drive_revision!=''",col);
   sql.exec("UPDATE live_collections SET state='legacy' WHERE collection=?",col);
   return {liveProtocol:1,schoolId:school,collection:col,state:'legacy',cursor:head(),fingerprint,driveVerified:true,pending:0,needsAttention:0};
  });
 }
 if(command==='capabilities')return {liveProtocol:1,schoolId:school,domainCapabilities:1,personCapabilities:1,collections:[...liveCollections]};
 if(command==='head')return {liveProtocol:1,schoolId:school,cursor:head(),collections:sql.exec<{collection:string;state:string;cursor:number}>('SELECT c.collection,c.state,coalesce(e.cursor,0) AS cursor FROM live_collections c LEFT JOIN live_collection_cursors e ON e.collection=c.collection').toArray()};
 if(command==='operationReceipt'){
  demand(opId(b.operationId),'Invalid operation identity');
  const saved=sql.exec<{fingerprint:string;receipt:string}>('SELECT fingerprint,receipt FROM live_operations WHERE operation_id=?',String(b.operationId)).toArray()[0];
  const receipt=saved?JSON.parse(saved.receipt) as Json:null;
  const backup=receipt?sql.exec<{state:string;verified_at:number;drive_revision:string|null}>("SELECT b.state,b.verified_at,b.drive_revision FROM live_backup b JOIN live_events e ON e.seq=b.seq WHERE json_extract(e.receipt,'$.recordRevision')=? ORDER BY b.seq DESC LIMIT 1",String(receipt.recordRevision)).toArray()[0]:null;
  return {liveProtocol:1,schoolId:school,operationId:b.operationId,found:!!saved,...(saved?{fingerprint:saved.fingerprint,receipt,deliveryState:backup?.state||(receipt?.backupState==='verified'?'verified':'pending'),verifiedAt:backup?.verified_at||0}:{})};
 }
 // Durable Object alarm performs age-based cleanup only after the EXACT backup
 // is verified. All retries/reviews remain intact past the 24-hour threshold.
 if(command==='expireVerified')return storage.transactionSync(()=>{
  const stale=sql.exec<{seq:number;collection:string;id:string;operation_id:string;drive_revision:string;receipt:string}>(
   "SELECT b.seq,b.collection,b.id,b.operation_id,b.drive_revision,e.receipt FROM live_backup b JOIN live_events e ON e.seq=b.seq WHERE b.state='verified' AND b.verified_at>0 AND b.accepted_at>0 AND b.verified_at>=b.accepted_at AND b.accepted_at<=? AND b.body!='' ORDER BY b.seq LIMIT 200",
   now-cloudflareVerifiedRetentionMs).toArray();
  for(const job of stale){
   const rec=JSON.parse(job.receipt) as Json;
   demand(typeof job.drive_revision==='string'&&job.drive_revision.length>0&&rec.recordRevision&&rec.operationId===job.operation_id,'Unverified retention receipt',409);
   const original=sql.exec<{body:string}>('SELECT body FROM live_backup WHERE seq=?',job.seq).toArray()[0]?.body;
   demand(!!original&&payloadHash(JSON.parse(original))===rec.payloadHash,'Backup payload changed; retain',409);
   sql.exec("UPDATE live_events SET body='',receipt=json_set(receipt,'$.record',null,'$.source','drive') WHERE seq=? AND operation_id=?",job.seq,job.operation_id);
   sql.exec("UPDATE live_backup SET body='' WHERE seq=? AND state='verified' AND verified_at>0",job.seq);
   // Exact version may have unchanged/duplicate operation receipts too.
   sql.exec("UPDATE live_operations SET receipt=json_set(receipt,'$.record',null,'$.source','drive','$.backupState','verified') WHERE json_extract(receipt,'$.recordRevision')=?",rec.recordRevision);
   sql.exec("UPDATE live_records SET body='' WHERE collection=? AND id=? AND revision=? AND drive_revision=?",
     job.collection,job.id,rec.recordRevision,job.drive_revision);
  }
  const next=sql.exec<{due:number}>(
   "SELECT min(max(accepted_at+?,verified_at)) AS due FROM live_backup WHERE state='verified' AND verified_at>0 AND accepted_at>0 AND verified_at>=accepted_at AND body!=''",
   cloudflareVerifiedRetentionMs).toArray()[0]?.due;
  return {expired:stale.length,nextCleanupAt:next??null};
 });
 if(command==='retention')return {retentionHours:24,
  ...sql.exec<{nextCleanupAt:number}>("SELECT min(max(accepted_at+?,verified_at)) AS nextCleanupAt FROM live_backup WHERE state='verified' AND verified_at>0 AND accepted_at>0 AND verified_at>=accepted_at AND body!=''",cloudflareVerifiedRetentionMs).toArray()[0]};
 if(command==='compact')return storage.transactionSync(()=>{
  demand(Number.isSafeInteger(b.before)&&Number(b.before)>=0&&Number(b.before)<=head(),'Invalid retention boundary');
  const floor=sql.exec<{floor:number}>('SELECT floor FROM live_retention WHERE id=1').toArray()[0].floor;
  // Only a contiguous prefix whose exact snapshots reached Drive is eligible.
  const rows=sql.exec<{seq:number;state:string;body:string}>("SELECT e.seq,e.body,b.state FROM live_events e LEFT JOIN live_backup b ON b.seq=e.seq WHERE e.seq>? AND e.seq<=? ORDER BY e.seq LIMIT 1000",floor,Number(b.before)).toArray();
  let next=floor;for(const row of rows){if(row.state!=='verified'||row.body!=='')break;next=row.seq;}
  if(next>floor){sql.exec('DELETE FROM live_events WHERE seq<=? AND body=\'\'',next);sql.exec("DELETE FROM live_backup WHERE seq<=? AND state='verified' AND body=''",next);sql.exec('UPDATE live_retention SET floor=? WHERE id=1',next);}
  return {liveProtocol:1,schoolId:school,cursor:head(),floor:next,snapshotRequiredBefore:next};
 });
 if(command==='received'){
  demand(typeof b.device==='string'&&/^[a-f0-9]{64}$/.test(b.device)&&Number.isSafeInteger(b.cursor)&&Number(b.cursor)>=0&&Number(b.cursor)<=head(),'Invalid device receipt');
  sql.exec('INSERT INTO live_device_receipts VALUES(?,?,?) ON CONFLICT(device) DO UPDATE SET cursor=max(cursor,excluded.cursor),observed_at=excluded.observed_at',b.device,Number(b.cursor),now);return {received:true};
 }
 if(command==='backupClaim')return storage.transactionSync(()=>{
  const job=sql.exec<Job>("SELECT b.* FROM live_backup b WHERE b.state IN ('pending','retry','processing') AND b.due<=? AND NOT EXISTS(SELECT 1 FROM live_backup earlier WHERE earlier.collection=b.collection AND earlier.id=b.id AND earlier.seq<b.seq AND earlier.state!='verified') AND NOT EXISTS(SELECT 1 FROM live_backup_dependencies d JOIN live_backup previous ON previous.seq=d.predecessor WHERE d.sequence=b.seq AND previous.state!='verified') ORDER BY b.seq LIMIT 1",now).toArray()[0];
  if(!job)return {job:null};const claim=randomUUID();sql.exec("UPDATE live_backup SET state='processing',claim=?,claim_until=?,due=? WHERE seq=?",claim,now+120000,now+120000,job.seq);
  const current=sql.exec<Row>('SELECT * FROM live_records WHERE collection=? AND id=?',job.collection,job.id).toArray()[0];
  const data=JSON.parse(job.body) as Json;for(const k of Object.keys(data))if(k.startsWith('_sync'))delete data[k];
  return {job:{seq:job.seq,claim,request:{action:'managed_records',collection:job.collection,id:job.id,operation:job.operation,syncProtocol:2,operationId:job.operation_id,expectedRecordRevision:current.drive_revision,...JSON.parse((job as Job&{request_metadata:string}).request_metadata||'{}'),...(job.operation==='write'?{data}:{})}}};
 });
 if(command==='backupFinish')return storage.transactionSync(()=>{
  demand(Number.isSafeInteger(b.sequence)&&typeof b.claim==='string','Invalid backup receipt');
  const job=sql.exec<Job>('SELECT * FROM live_backup WHERE seq=?',Number(b.sequence)).toArray()[0];
  if(!job||job.state!=='processing'||job.claim!==b.claim||job.claim_until<=now)return {accepted:false};
  if(b.verified===true){
   demand(typeof b.driveRevision==='string'&&b.driveRevision.length>0&&b.driveRevision.length<=100&&!b.driveRevision.startsWith('live-')&&!b.driveRevision.startsWith('cf-'),'Unverified backup revision');
   const event=sql.exec<{receipt:string}>('SELECT receipt FROM live_events WHERE seq=?',job.seq).toArray()[0];
   demand(event&&event.receipt,'Live backup event receipt missing',412);
   const receipt=JSON.parse(event.receipt) as Json;
   let finalBody=JSON.parse(job.body) as Json;
   if(b.archiveFiles!==undefined){
    // A signed broker has independently verified every staged file's immutable
    // Drive ACK. Only fileId enrichment is allowed; business fields, version,
    // parent owner and manifest hash cannot be changed by the archive.
    demand(job.collection==='documents'&&job.operation==='write'&&
      Array.isArray(b.archiveFiles)&&Array.isArray(finalBody.bundleMedia),
      'Archive applies only to a staged document',412);
    const old=finalBody.bundleMedia as Json[],next=b.archiveFiles as Json[];
    demand(old.length===next.length&&old.length>=1&&old.length<=2,
      'Published file set differs from Drive receipt',409);
    for(let i=0;i<old.length;i++){
     demand(old[i].kind===next[i].kind&&old[i].id===next[i].id&&
       old[i].sha256===next[i].sha256&&old[i].sizeBytes===next[i].sizeBytes&&
       old[i].mime===next[i].mime&&
       typeof next[i].fileId==='string'&&/^[A-Za-z0-9_-]{1,200}$/.test(String(next[i].fileId))&&
       (old[i].fileId===undefined||old[i].fileId===next[i].fileId),
       'Archive cannot replace staged bytes or original Drive identity',409);
    }
    demand(finalBody.fileId===undefined||finalBody.fileId===next[0].fileId,
      'Archive card ID differs from original staging',409);
    finalBody={...finalBody,bundleMedia:next,fileId:next[0].fileId};
    // Only the exact same live revision gets enriched. A newer user edit,
    // unlike this immutable archive result, must never be overwritten.
    sql.exec('UPDATE live_records SET body=?,payload_hash=? WHERE collection=? AND id=? AND revision=?',
      canonical(finalBody),payloadHash(finalBody),job.collection,job.id,receipt.recordRevision);
    sql.exec('UPDATE live_backup SET body=? WHERE seq=?',canonical(finalBody),job.seq);
   }else{
    demand(!Array.isArray(finalBody.bundleMedia)||
      (finalBody.bundleMedia as Json[]).every(f=>typeof f.fileId==='string'),
      'Unarchived media cannot be marked Drive verified',412);
   }
   sql.exec("UPDATE live_backup SET state='verified',drive_revision=?,claim='',claim_until=0,due=?,verified_at=? WHERE seq=?",b.driveRevision,Number.MAX_SAFE_INTEGER,now,job.seq);
   sql.exec('UPDATE live_records SET drive_revision=? WHERE collection=? AND id=?',b.driveRevision,job.collection,job.id);
   const retentionStart=Number.isSafeInteger(job.accepted_at)&&job.accepted_at>0&&job.accepted_at<=now?job.accepted_at:now;
   const retainedUntil=Math.max(retentionStart+cloudflareVerifiedRetentionMs,now);
   const reference={...receipt,
    ...(b.archiveFiles!==undefined?{record:finalBody}:{}),
    backupState:'verified',source:'cloudflare',driveRevision:b.driveRevision,
    payloadHash:payloadHash(finalBody),reconcileRequired:true,
    retainedUntil};
   sql.exec('UPDATE live_events SET receipt=? WHERE seq=?',JSON.stringify(reference),job.seq);
   if(b.archiveFiles!==undefined){
    // A verified archive enriches the original immutable operation's media
    // pointer. Otherwise the receipt would expose old bytes with a new hash.
    sql.exec("UPDATE live_operations SET receipt=json_set(receipt,'$.record',json(?)) WHERE json_extract(receipt,'$.recordRevision')=?",
      canonical(finalBody),String(receipt.recordRevision));
   }
   sql.exec("UPDATE live_operations SET receipt=json_set(receipt,'$.backupState','verified','$.driveRevision',?,'$.payloadHash',?,'$.retainedUntil',?,'$.reconcileRequired',json('true')) WHERE json_extract(receipt,'$.recordRevision')=?",String(b.driveRevision),String(reference.payloadHash),retainedUntil,String(receipt.recordRevision));
   const metadata=JSON.parse((job as Job&{request_metadata:string}).request_metadata||'{}');
   if(job.operation==='delete'&&metadata.deleteEverywhereVersion===1){
    // Explicit verified deletion overrides ordinary 24-hour cache retention.
    // Sequence fencing preserves any newer accepted generation or pending edit.
    sql.exec("UPDATE live_operations SET receipt=json_set(receipt,'$.record',null,'$.source','drive') WHERE json_extract(receipt,'$.recordRevision') IN (SELECT json_extract(receipt,'$.recordRevision') FROM live_events WHERE collection=? AND id=? AND seq<?)",job.collection,job.id,job.seq);
    sql.exec("UPDATE live_events SET body='',receipt=json_set(receipt,'$.record',null,'$.source','drive') WHERE collection=? AND id=? AND seq<?",job.collection,job.id,job.seq);
    sql.exec("UPDATE live_backup SET body='' WHERE collection=? AND id=? AND seq<? AND state='verified'",job.collection,job.id,job.seq);
   }
   // Retain this exact version's temporary payload for 24 hours following
   // verified Drive ACK. The alarm purges only the verified snapshot later;
   // an unverified newer revision or dependent record is never discarded.
  }else{
   demand(Number.isSafeInteger(b.retryAt)&&Number(b.retryAt)>now&&Number(b.retryAt)<=now+86400000,'Invalid backup retry');
   sql.exec("UPDATE live_backup SET state=?,due=?,claim='',claim_until=0 WHERE seq=?",b.review===true?'review':'retry',b.review===true?Number.MAX_SAFE_INTEGER:Number(b.retryAt),job.seq);
  }return {accepted:true};
 });
 if(command==='backupHistory'){
  const entries=sql.exec<{seq:number;collection:string;id:string;operation_id:string;state:string;accepted_at:number;verified_at:number;drive_revision:string|null;receipt:string}>('SELECT b.seq,b.collection,b.id,b.operation_id,b.state,b.accepted_at,b.verified_at,b.drive_revision,e.receipt FROM live_backup b JOIN live_events e ON e.seq=b.seq ORDER BY b.seq DESC LIMIT 25').toArray().map(row=>({operationId:row.operation_id,collection:row.collection,id:row.id,state:row.state,sequence:row.seq,acceptedAt:row.accepted_at,verifiedAt:row.verified_at,completedAt:row.state==='verified'?row.verified_at:0,recordRevision:String(JSON.parse(row.receipt).recordRevision||''),...(row.state==='verified'?{driveRevision:row.drive_revision}:{})}));
  return {liveProtocol:1,schoolId:school,entries};
 }
 if(command==='stats')return {liveProtocol:1,schoolId:school,cursor:head(),backups:sql.exec<{state:string;count:number;due:number}>('SELECT state,count(*) AS count,min(due) AS due FROM live_backup GROUP BY state').toArray(),payloadCopies:sql.exec<{records:number;events:number;backups:number;operations:number}>("SELECT (SELECT count(*) FROM live_records WHERE body!='') AS records,(SELECT count(*) FROM live_events WHERE body!='') AS events,(SELECT count(*) FROM live_backup WHERE body!='') AS backups,(SELECT count(*) FROM live_operations WHERE json_type(receipt,'$.record')='object') AS operations").toArray()[0]};
 throw Object.assign(Error('Unknown live command'),{status:400});
}

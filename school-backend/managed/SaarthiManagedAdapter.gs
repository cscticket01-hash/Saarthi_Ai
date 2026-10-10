/** Managed Windows storage adapter. Deploy as the SCHOOL account, not developer.
 * No Firebase project/key/password required. Run VS_setupManagedSchool once.
 * Existing legacy sheets/files remain untouched; do not rebind existing roots.
 */
// Operator configuration: set only for a NEW school deployment.
// Existing deployments keep their stored School ID, root and secret.
const VS_SETUP_SCHOOL_ID = '';
const VS_SETUP_CREATE_NEW_STORAGE = false;
// Cleared at every signed request / top-level record batch. Never persisted.
let VS_BACKUP_READ_CACHE = null;

/** Select this no-argument function in the Apps Script editor and Run once.
 * Returns no connection secret. Windows pairs using only the deployed /exec URL.
 */
function VS_prepareSchoolStorage() {
  const p = PropertiesService.getScriptProperties();
  const existing = p.getProperty('VS_MANAGED_SCHOOL_ID');
  const configured = VS_SETUP_SCHOOL_ID.trim();
  const schoolId = configured || existing;
  if (!schoolId) throw new Error('Set VS_SETUP_SCHOOL_ID to the School ID from the developer website');
  if (existing && configured && existing !== configured) throw new Error('School rebinding is blocked');
  if (existing && !p.getProperty('VS_MANAGED_ROOT_ID')) throw new Error('Existing school root is missing; developer recovery required');
  VS_setupManagedSchool(schoolId, {startEmpty: !existing && VS_SETUP_CREATE_NEW_STORAGE === true});
  VS_managedRoot();
  return {success: true, schoolId: schoolId, storageReady: true};
}

function VS_setupManagedSchool(schoolId, options) {
  options = options || {};
  if (!/^vs-[a-f0-9]{32}$/.test(schoolId)) throw new Error('Use School ID from developer website');
  const p = PropertiesService.getScriptProperties(), old = p.getProperty('VS_MANAGED_SCHOOL_ID');
  if (old && old !== schoolId) throw new Error('School rebinding is blocked');
  let rootId = p.getProperty('VS_MANAGED_ROOT_ID');
  if (!rootId) {
    if (options.rootFolderId) {
      const root = DriveApp.getFolderById(options.rootFolderId);
      if (root.getDescription() !== 'VIDYA_MANAGED_SCHOOL:' + schoolId) throw new Error('Existing root must already be verified for this school; no automatic migration');
      rootId = root.getId();
    } else {
      if (options.startEmpty !== true) throw new Error('Use startEmpty:true only for a NEW storage connection. Existing data migration requires review.');
      const root = DriveApp.createFolder('Vidya Saarthi ' + schoolId);
      root.setDescription('VIDYA_MANAGED_SCHOOL:' + schoolId); rootId = root.getId();
    }
  }
  p.setProperty('VS_MANAGED_SCHOOL_ID', schoolId); p.setProperty('VS_MANAGED_ROOT_ID', rootId);
  let secret = p.getProperty('VS_MANAGED_SECRET');
  if (!secret) { secret = Utilities.getUuid().replace(/-/g,'') + Utilities.getUuid().replace(/-/g,''); p.setProperty('VS_MANAGED_SECRET', secret); }
  return {schoolId: schoolId, rootFolderId: rootId, connectionSecret: secret};
}
function VS_managedRoot() {
  const p = PropertiesService.getScriptProperties(), school = p.getProperty('VS_MANAGED_SCHOOL_ID');
  const root = DriveApp.getFolderById(p.getProperty('VS_MANAGED_ROOT_ID'));
  if (!school || root.getDescription() !== 'VIDYA_MANAGED_SCHOOL:' + school) throw new Error('School Drive root mismatch');
  return root;
}
/** Owner-editor inventory only. Never routed through the signed web API.
 * Reads existing IDs/metadata without creating folders, backfilling Sheets,
 * reading record contents, returning connection secrets or moving files.
 * A partial inventory must not be used to approve a migration.
 */
function VS_inventoryManagedStorage() {
  const p=PropertiesService.getScriptProperties(),school=p.getProperty('VS_MANAGED_SCHOOL_ID');
  const root=VS_managedRoot(),pending=[{folder:root,path:[]}],files=[],folders=[],seen={};
  let partial=false;
  while(pending.length) {
    if(files.length+folders.length>=5000){partial=true;break;}
    const item=pending.shift(),id=item.folder.getId();
    if(seen[id]){partial=true;continue;}seen[id]=true;
    folders.push({id:id,path:item.path});
    const children=item.folder.getFolders();
    while(children.hasNext()) {
      if(pending.length+files.length+folders.length>=5000){partial=true;break;}
      const child=children.next();pending.push({folder:child,path:item.path.concat(child.getName())});
    }
    const entries=item.folder.getFiles();
    while(entries.hasNext()) {
      if(files.length+folders.length>=5000){partial=true;break;}
      const file=entries.next();
      files.push({id:file.getId(),parentId:id,path:item.path,name:file.getName(),mimeType:file.getMimeType(),sizeBytes:file.getSize()});
    }
  }
  return {schoolId:school,rootFolderId:root.getId(),workbookId:p.getProperty('VS_MANAGED_SHEET_ID')||null,
    inventoryVersion:1,partial:partial,folders:folders,files:files};
}
function VS_managedVerify(e) {
  const b = JSON.parse(e.postData.contents), p = PropertiesService.getScriptProperties();
  const school = p.getProperty('VS_MANAGED_SCHOOL_ID'), secret = p.getProperty('VS_MANAGED_SECRET');
  if (!secret || b.schoolId !== school || !Number.isSafeInteger(b.timestamp) || Math.abs(Date.now()-b.timestamp)>120000 || !/^[a-f0-9]{48}$/.test(b.nonce||'') || typeof b.payload !== 'string' || b.payload.length > 28*1024*1024) throw new Error('Signed school request required');
  const expected = Utilities.computeHmacSha256Signature(school+'\n'+b.timestamp+'\n'+b.nonce+'\n'+b.payload, secret, Utilities.Charset.UTF_8).map(v=>('0'+((v+256)%256).toString(16)).slice(-2)).join('');
  let difference = 0; if (!/^[a-f0-9]{64}$/.test(b.signature||'')) throw new Error('Invalid request signature');
  for(let n=0;n<64;n++) difference |= expected.charCodeAt(n)^b.signature.charCodeAt(n);
  if(difference) throw new Error('Invalid request signature');
  const lock=LockService.getScriptLock();lock.waitLock(30000);
  try {
    const key='VS_NONCE_'+b.nonce;
    if(p.getProperty(key)) throw new Error('Request already used');
    const all=p.getProperties();let count=0;
    Object.keys(all).filter(k=>k.indexOf('VS_NONCE_')===0).forEach(k=>{if(Number(all[k])<Date.now()-240000)p.deleteProperty(k);else count++;});
    if(count>=1000)throw new Error('Retry storage shortly');p.setProperty(key,String(b.timestamp));
  } finally {lock.releaseLock();}
  return JSON.parse(b.payload);
}
function VS_validateManagedCollection(name) {
  if (!['students_directory','teachers_directory','attendance_logs','teacher_attendance','attendance_records','teacher_schedules','school_notices','school_calendar','exam_results','teacher_salary','school_config','school_settings','fee_settings','fee_ledger','fee_payments','school_expenses','student_scan_index','scanner_devices','documents','backups','exams','exam_center_results','mobile_sessions','mobile_users','mobile_complaints'].includes(name)) throw new Error('Unknown collection');
}
function VS_managedCollection(name) {
  VS_validateManagedCollection(name);
  const root=VS_managedRoot(), folders=root.getFoldersByName('records_'+name);
  if(folders.hasNext()) {const folder=folders.next();if(folders.hasNext())throw new Error('Duplicate collection folders; operator review required');return folder;}
  return root.createFolder('records_'+name);
}
// One authoritative record store: one verified spreadsheet, one tab per collection.
// Legacy JSON files are retained as migration evidence, never deleted by backfill.
function VS_managedFolder(parent,name) {
  const matches=parent.getFoldersByName(name);
  if(matches.hasNext()){const folder=matches.next();if(matches.hasNext())throw new Error('Duplicate storage folder; operator review required');return folder;}
  return parent.createFolder(name);
}
function VS_legacySheet(collection,readContext) {
  VS_validateManagedCollection(collection);
  const p=PropertiesService.getScriptProperties();
  const school=p.getProperty('VS_MANAGED_SCHOOL_ID');let id=p.getProperty('VS_MANAGED_SHEET_ID'),book;
  // This context lives only inside one locked mobile request. Reuse the already
  // ancestry/marker-verified workbook, never a persistent cross-request cache.
  const verified=readContext&&readContext.legacyBook;
  const reuse=verified&&verified.school===school&&verified.id===id;
  const legacy=reuse&&p.getProperty('VS_SHEET_MIGRATED_'+collection)==='1'?null:VS_managedCollection(collection);
  const pending=p.getProperty('VS_MANAGED_SHEET_PENDING');
  if(!id&&pending){const file=DriveApp.getFileById(pending);if(file.getDescription()!=='VIDYA_SCHOOL_DATA:'+school)throw new Error('Pending workbook identity mismatch');file.moveTo(VS_managedFolder(VS_managedRoot(),'School Data'));p.setProperty('VS_MANAGED_SHEET_ID',pending);p.deleteProperty('VS_MANAGED_SHEET_PENDING');id=pending;}
  if(reuse)book=verified.book;
  else if(id){const file=VS_managedFile(id);if(file.getDescription()!=='VIDYA_SCHOOL_DATA:'+school)throw new Error('School workbook identity mismatch');book=SpreadsheetApp.openById(id);}
  else {
    // Recover a create/move crash without creating a second school workbook.
    const target=VS_managedFolder(VS_managedRoot(),'School Data');
    const matches=target.getFilesByName('Vidya Saarthi School Data');
    if(matches.hasNext()){
      const file=matches.next();if(matches.hasNext()||file.getDescription()!=='VIDYA_SCHOOL_DATA:'+school)throw new Error('School workbook requires operator review');
      id=file.getId();book=SpreadsheetApp.openById(id);
    }else{
      book=SpreadsheetApp.create('Vidya Saarthi School Data');id=book.getId();
      const file=DriveApp.getFileById(id);file.setDescription('VIDYA_SCHOOL_DATA:'+school);p.setProperty('VS_MANAGED_SHEET_PENDING',id);file.moveTo(target);
    }
    p.setProperty('VS_MANAGED_SHEET_ID',id);p.deleteProperty('VS_MANAGED_SHEET_PENDING');
  }
  if(readContext)readContext.legacyBook={school:school,id:id,book:book};
  let sheet=book.getSheetByName(collection);
  if(!sheet&&p.getProperty('VS_SHEET_MIGRATED_'+collection)==='1')throw new Error('Verified school tab is missing; operator recovery required');
  if(!sheet){sheet=book.insertSheet(collection);if(sheet.getMaxColumns()<33)sheet.insertColumnsAfter(sheet.getMaxColumns(),33-sheet.getMaxColumns());sheet.getRange(1,1,1,33).setValues([['Record Key','School ID','Revision','Deleted','Operation ID','Display Name'].concat(Array.from({length:27},(_,n)=>'Data '+(n+1)))]);sheet.setFrozenRows(1);}
  const store={sheet:sheet,school:school};
  if(p.getProperty('VS_SHEET_MIGRATED_'+collection)!=='1'){
    const files=legacy.getFiles();let bytes=0,copied=0;const seen={};
    while(files.hasNext()){
      const raw=files.next().getBlob().getDataAsString();bytes+=raw.length;
      if(bytes>20*1024*1024)throw new Error('Collection migration exceeds safe limit');
      const item=JSON.parse(raw);
      if(!item||item.schoolId!==school||typeof item.id!=='string'||!item.data||item.data.schoolId!==school||seen[item.id])throw new Error('Invalid or duplicate legacy record; operator review required');
      seen[item.id]=true;
      const old=VS_sheetItem(store,item.id);
      if(old){if(JSON.stringify(old.data)!==JSON.stringify(item.data))throw new Error('Migration conflict; both versions retained');}
      else {VS_sheetPut(store,item);copied++;if(copied>=100&&files.hasNext())throw new Error('School data organization in progress; retry Sync. Pending data retained');}
    }
    p.setProperty('VS_RECORD_REV_'+collection,Utilities.getUuid());
    p.setProperty('VS_SHEET_MIGRATED_'+collection,'1');
  }
  return store;
}
function VS_sheetItem(store,id) {
  if(store.partitions)return VS_layoutItem(store,id);
  const key=Utilities.base64EncodeWebSafe(id),last=store.sheet.getLastRow();
  if(last<2)return null;
  const matches=store.sheet.getRange(2,1,last-1,1).createTextFinder(key).matchEntireCell(true).matchCase(true).findAll();
  if(matches.length>1)throw new Error('Duplicate Sheet record; operator review required');
  if(!matches.length)return null;
  const row=matches[0].getRow(),values=store.sheet.getRange(row,1,1,33).getValues()[0];
  const item=VS_sheetDecode(store,values);if(item.id!==id)throw new Error('Sheet identity mismatch');item.row=row;return item;
}
function VS_sheetDecode(store,values) {
  const item=JSON.parse(values.slice(6).filter(v=>v!=='').map(v=>JSON.parse(v)).join(''));
  if(!item||item.schoolId!==store.school||!item.data||item.data.schoolId!==store.school||Utilities.base64EncodeWebSafe(item.id)!==values[0]||values[1]!==store.school)throw new Error('Foreign school record');
  return item;
}
function VS_sheetPut(store,item) {
  if(store.partitions)return VS_layoutPut(store,item);
  const text=JSON.stringify({id:item.id,schoolId:item.schoolId,data:item.data,...(item.layoutRedirect?{layoutRedirect:item.layoutRedirect}:{}),...(item.layoutPrevious?{layoutPrevious:item.layoutPrevious}:{})});
  if(text.length>512*1024)throw new Error('Record too large; upload files separately');
  const old=VS_sheetItem(store,item.id),data=item.data;
  // Display cells are inert text; canonical JSON always begins with '{'.
  const label=String(data.name||data.studentName||data.title||data.documentName||'').slice(0,200);
  const values=[Utilities.base64EncodeWebSafe(item.id),store.school,data._syncRevision||'',data._syncDeleted===true?'YES':'NO',data._syncOperationId||'',label&&/^[=+\-@]/.test(label)?"'"+label:label];
  // Quoted fragments cannot be interpreted as Sheet formulas, even when a
  // continuation begins with '='. Rejoining preserves all Unicode code units.
  for(let n=0;n<27;n++){const part=text.slice(n*20000,(n+1)*20000);values.push(part?JSON.stringify(part):'');}
  const row=old?old.row:Math.max(2,store.sheet.getLastRow()+1);
  if(row>store.sheet.getMaxRows())store.sheet.insertRowsAfter(store.sheet.getMaxRows(),Math.max(100,row-store.sheet.getMaxRows()));
  store.sheet.getRange(row,1,1,33).setValues([values]);SpreadsheetApp.flush();
  const saved=VS_sheetItem(store,item.id);
  if(!saved||JSON.stringify(saved.data)!==JSON.stringify(data))throw new Error('School record verification failed');
}
function VS_sheetRecords(store) {
  if(store.partitions)return VS_layoutRecords(store);
  const last=store.sheet.getLastRow(),records=Object.create(null);let bytes=0;
  if(last<2)return records;
  const rows=store.sheet.getRange(2,1,last-1,33).getValues();
  rows.forEach(values=>{if(!values[0])return;bytes+=values.slice(6).join('').length;if(bytes>20*1024*1024)throw new Error('Collection export exceeds safe limit');const item=VS_sheetDecode(store,values);if(records[item.id])throw new Error('Duplicate Sheet record');records[item.id]=item.data;});
  return records;
}
// Delete only the immutable upload belonging to this exact document revision.
// Unkeyed legacy or shared files are retained; no broad Drive delete is possible.
function VS_managedDeletedFile(store,id,data) {
  if(data._syncRecycleUntil && Date.now()<data._syncRecycleUntil)return 'retained-recycle';
  if(!data._syncDeletedFileId)return 'none';
  if(data._syncFileCleanupComplete===true)return 'deleted';
  const file=VS_managedFile(data._syncDeletedFileId);
  const marker=String(file.getDescription()||'');
  const key=Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,id+':'+data.documentRevision).map(v=>('0'+((v+256)%256).toString(16)).slice(-2)).join('');
  if(marker.indexOf('VIDYA_UPLOAD:'+store.school+':'+key+':')!==0)return 'retained-legacy';
  const records=VS_sheetRecords(store);
  if(Object.keys(records).some(other=>other!==id&&!records[other]._syncDeleted&&records[other].fileId===data._syncDeletedFileId))return 'retained-shared';
  file.setTrashed(true);
  if(!file.isTrashed())throw new Error('Document file deletion not acknowledged');
  data._syncFileCleanupComplete=true;VS_sheetPut(store,{id:id,schoolId:store.school,data:data});
  return 'deleted';
}
// Optional reviewed capability. Existing schools keep their deployed behavior
// until their owner explicitly enables VS_RECYCLE_VERSION=1 in isolated testing.
function VS_recycleEnabled() {
  return PropertiesService.getScriptProperties().getProperty('VS_RECYCLE_VERSION')==='1';
}
function VS_recycleSnapshot(collection,id,existing,deletionRevision) {
  const root=VS_managedRoot(),folder=VS_managedFolder(root,'Recycle Bin');
  const deletedAt=Date.now();
  const snapshot={schemaVersion:1,schoolId:existing.schoolId,collection:collection,id:id,
    deletedRevision:deletionRevision,deletedAt:deletedAt,recoverUntil:deletedAt+86400000,
    data:existing.data};
  const text=JSON.stringify(snapshot);if(Utilities.base64Decode(Utilities.base64Encode(text)).length>600*1024)throw new Error('Recycle snapshot exceeds safe limit');
  const file=folder.createFile('Deleted_'+deletionRevision+'.json',text,'application/json');
  file.setDescription('VIDYA_RECYCLE:'+existing.schoolId+':'+deletionRevision+':'+VS_layoutHash(snapshot));
  const read=JSON.parse(file.getBlob().getDataAsString());
  if(JSON.stringify(read)!==text)throw new Error('Recycle snapshot verification failed');
  return {fileId:file.getId(),recoverUntil:snapshot.recoverUntil};
}
function VS_recycleRead(fileId) {
  const school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID');
  const file=VS_managedFile(fileId),blob=file.getBlob();
  if(blob.getBytes().length>600*1024)throw new Error('Recycle snapshot exceeds safe limit');
  const snapshot=JSON.parse(blob.getDataAsString());
  if(snapshot.schemaVersion!==1||snapshot.schoolId!==school||!snapshot.data||snapshot.data.schoolId!==school||
      file.getDescription()!=='VIDYA_RECYCLE:'+school+':'+snapshot.deletedRevision+':'+VS_layoutHash(snapshot)||
      typeof snapshot.recoverUntil!=='number'||typeof snapshot.deletedAt!=='number'||
      snapshot.recoverUntil-snapshot.deletedAt!==86400000)throw new Error('Invalid school recycle snapshot');
  VS_managedCollection(snapshot.collection);
  if(!/^[^/]{1,200}$/.test(snapshot.id||'')||snapshot.id==='.'||snapshot.id==='..')throw new Error('Invalid record ID');
  return {file:file,snapshot:snapshot};
}
function VS_managedRecycle(b) {
  if(!VS_recycleEnabled())throw new Error('Recycle capability not enabled');
  const lock=LockService.getScriptLock();lock.waitLock(30000);
  try {
    if(b.operation==='list') {
      VS_managedCollection(b.collection);
      if(typeof b.after!=='string'||b.after.length>200)throw new Error('Invalid record ID');
      const store=VS_managedSheet(b.collection),records=VS_sheetRecords(store),now=Date.now();
      const ids=Object.keys(records).filter(id=>id>b.after&&records[id]._syncDeleted===true&&records[id]._syncRecycleFileId).sort();
      const entries=ids.slice(0,25).map(id=>{
        const row=records[id],base={id:id,collection:b.collection,fileId:row._syncRecycleFileId,deletedRevision:row._syncRevision};
        try {
          const snap=VS_recycleRead(row._syncRecycleFileId).snapshot;
          if(snap.id!==id||snap.collection!==b.collection||snap.deletedRevision!==row._syncRevision)throw new Error('Record revision conflict');
          const name=snap.data.name||snap.data.documentName||snap.data.title||id;
          return Object.assign(base,{name:typeof name==='string'?name.slice(0,120):id,deletedAt:snap.deletedAt,recoverUntil:snap.recoverUntil,
            status:now>=snap.recoverUntil?'expired':'recoverable',auditRetained:true,deletedBy:'Not recorded'});
        } catch (_) {return Object.assign(base,{name:id,status:'needsReview',auditRetained:true,deletedBy:'Not recorded'});}
      });
      return {entries:entries,serverNow:now,partial:ids.length>25,nextAfter:ids.length>25?ids[24]:null,recycleVersion:1};
    }
    if(!['restore','purge'].includes(b.operation)||typeof b.expectedRecordRevision!=='string'||
        !/^[A-Za-z0-9_-]{16,100}$/.test(b.operationId||''))throw new Error('Invalid sync operation');
    const item=VS_recycleRead(b.fileId),snap=item.snapshot,store=VS_managedSheet(snap.collection),current=VS_sheetItem(store,snap.id);
    if(!current||current.schoolId!==snap.schoolId)throw new Error('Record revision conflict');
    const data=current.data;
    if(b.operation==='restore'&&data._syncRecycleRestoreId===b.operationId&&data._syncRecycleSource===b.fileId&&data._syncRecycleRestoreRevision===b.expectedRecordRevision)
      return {recordRevision:data._syncRevision,syncProtocol:2,restored:true};
    if(b.expectedRecordRevision!==data._syncRevision||data._syncRevision!==snap.deletedRevision||
        data._syncDeleted!==true||data._syncRecycleFileId!==b.fileId)throw new Error('Record revision conflict');
    if(b.operation==='restore') {
      if(Date.now()>=snap.recoverUntil||data._syncFileCleanupComplete===true)throw new Error('Recycle restore window expired');
      if(snap.collection==='documents'&&snap.data.fileId&&VS_managedFile(snap.data.fileId).isTrashed())throw new Error('Original document unavailable; retained snapshot requires review');
      const restored=Object.assign({},snap.data);Object.keys(restored).filter(k=>k.indexOf('_sync')===0).forEach(k=>delete restored[k]);
      restored._syncRevision=Utilities.getUuid();restored._syncRecycleRestoreId=b.operationId;restored._syncRecycleSource=b.fileId;restored._syncRecycleRestoreRevision=b.expectedRecordRevision;
      PropertiesService.getScriptProperties().setProperty('VS_RECORD_REV_'+snap.collection,Utilities.getUuid());
      VS_sheetPut(store,{id:snap.id,schoolId:snap.schoolId,data:restored});
      return {recordRevision:restored._syncRevision,syncProtocol:2,restored:true};
    }
    if(Date.now()<snap.recoverUntil)throw new Error('Recycle retention window active');
    // Accounting audit snapshots are never purged by this generic mechanism.
    if(['fee_payments','fee_ledger','teacher_salary','school_expenses'].includes(snap.collection))return {purged:false,retainedAudit:true};
    const cleanup=VS_managedDeletedFile(store,snap.id,data);
    // Retain explicit tombstones and an audit snapshot. Only an eligible owned,
    // immutable, unshared document binary is purged; snapshots need a separately
    // reviewed school retention policy before permanent erasure.
    return {purged:cleanup==='deleted',fileCleanup:cleanup,retainedSnapshot:true};
  } finally {lock.releaseLock();}
}
/** Owner-only, isolated TEST opt-in. Never purges files, snapshots or accounting evidence. */
function VS_requireTestRecycleScheduler() {
  const p=PropertiesService.getScriptProperties();
  if(p.getProperty('VS_MANAGED_SCHOOL_ID')!=='vs-db8afb01a3be46a983c8284714d06e5d'||!VS_recycleEnabled())throw new Error('Isolated TEST recycle authorization required');
  return p;
}
/** Owner-editor opt-in for the one isolated TEST school. Never API-routed. */
function VS_enableTestRecycle() {
  const p=PropertiesService.getScriptProperties();
  if(p.getProperty('VS_MANAGED_SCHOOL_ID')!=='vs-db8afb01a3be46a983c8284714d06e5d')
    throw new Error('TEST recycle activation requires the isolated TEST school');
  VS_managedRoot(); // Verify existing school storage; never create or rebind it.
  p.setProperty('VS_RECYCLE_VERSION','1');
  const result={success:true,recycleVersion:1,existingStorageRetained:true,destructive:false};
  if(typeof console!=='undefined')console.log(JSON.stringify(result));
  return result;
}
function VS_installTestRecycleExpiryScheduler() {
  VS_requireTestRecycleScheduler();
  const existing=ScriptApp.getProjectTriggers().filter(t=>t.getHandlerFunction()==='VS_testRecycleExpiryTick');
  if(!existing.length)ScriptApp.newTrigger('VS_testRecycleExpiryTick').timeBased().everyHours(1).create();
  return {installed:true,intervalHours:1,destructive:false,scope:'isolated TEST only'};
}
function VS_testRecycleExpiryTick() {
  const p=VS_requireTestRecycleScheduler(),properties=p.getProperties();
  const collections=VS_LAYOUT_COLLECTIONS.filter(c=>properties['VS_RECORD_REV_'+c]).sort();
  if(!collections.length)return {checked:0,expired:0,partial:false,destructive:false};
  const old=Number(p.getProperty('VS_RECYCLE_SWEEP_COLLECTION')||0),index=Number.isSafeInteger(old)&&old>=0?old%collections.length:0;
  const collection=collections[index],cursor=p.getProperty('VS_RECYCLE_SWEEP_AFTER_'+collection)||'';
  const result=VS_managedRecycle({operation:'list',collection:collection,after:cursor});
  const summary={checkedAt:result.serverNow,checked:result.entries.length,expired:result.entries.filter(r=>r.status==='expired').length,
    needsReview:result.entries.filter(r=>r.status==='needsReview').length,partial:result.partial||collections.length>1,destructive:false};
  p.setProperty('VS_RECYCLE_SWEEP_AFTER_'+collection,result.nextAfter||'');
  p.setProperty('VS_RECYCLE_SWEEP_COLLECTION',String((index+1)%collections.length));
  p.setProperty('VS_RECYCLE_LAST_SWEEP',JSON.stringify(summary));
  if(typeof console!=='undefined')console.log(JSON.stringify(Object.assign({stage:'recycle_expiry_audit'},summary)));
  return summary;
}
function VS_syncRequestShape(b) {
  const data=Object.create(null);
  if(b.operation==='write')Object.keys(b.data||{}).forEach(k=>{if(['_syncRevision','_syncOperationId','_syncRequestHash','_syncDeleted','_syncDeletedFileId','_syncFileCleanupComplete'].indexOf(k)<0)data[k]=b.data[k];});
  return {operation:b.operation,data:data};
}
function VS_managedRecord(b) {
  VS_BACKUP_READ_CACHE=null;
  const lock=LockService.getScriptLock();lock.waitLock(30000);
  try{return VS_managedRecordUnlocked(b);}finally{lock.releaseLock();}
}
function VS_managedRecordUnlocked(b) {
  const store=VS_managedSheet(b.collection), school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID');
  if(b.operation==='read') {
    VS_recoverMissingBackupRows(b.collection,store);
    const revision=PropertiesService.getScriptProperties().getProperty('VS_RECORD_REV_'+b.collection)||'legacy';
    if(b.syncProtocol===2 && b.knownRevision===revision)return {records:{},unchanged:true,collectionRevision:revision,syncProtocol:2};
    const all=VS_sheetRecords(store),records=Object.create(null);Object.keys(all).forEach(id=>{if(b.syncProtocol===2||!all[id]._syncDeleted)records[id]=all[id];});
    return {records:records,collectionRevision:revision,syncProtocol:2};
  }
  if(!/^[^/]{1,200}$/.test(b.id||'')||b.id==='.'||b.id==='..')throw new Error('Invalid record ID');
  const existing=VS_sheetItem(store,b.id),file=existing;
  if(existing&&b.createOnly===true)return {skipped:true};
  if(existing&&(existing.schoolId!==school||existing.id!==b.id))throw new Error('Foreign school record');
  if(b.syncProtocol!==2 && existing&&existing.data._syncOperationId)throw new Error('Record revision conflict');
  if(b.syncProtocol===2){
    if(!/^[A-Za-z0-9_-]{16,100}$/.test(b.operationId||'')||typeof b.expectedRecordRevision!=='string')throw new Error('Invalid sync operation');
    if(existing&&existing.data._syncOperationId===b.operationId){
      const digest=VS_layoutHash(VS_syncRequestShape(b));
      const original=existing.data._syncRequestHash||VS_layoutHash(VS_syncRequestShape({operation:existing.data._syncDeleted?'delete':'write',data:existing.data}));
      if(digest!==original)throw new Error('Sync operation ID conflict');
      return {recordRevision:existing.data._syncRevision,syncProtocol:2,fileCleanup:existing.data._syncDeleted?VS_managedDeletedFile(store,b.id,existing.data):undefined};
    }
    if((existing&&existing.data._syncRevision||'')!==b.expectedRecordRevision)throw new Error('Record revision conflict');
  }

  if(b.collection==='documents' && (b.expectedRevision!==undefined || file)) {
    const current=existing;
    if(current&&(current.schoolId!==school||current.id!==b.id))throw new Error('Foreign document record');
    const revision=current&&current.data.documentRevision||'';
    if(b.expectedRevision!==undefined) {
      if(typeof b.expectedRevision!=='string'||b.expectedRevision!==revision ||
         (!revision&&current&&b.expectedUploadedAt!==undefined&&b.expectedUploadedAt!==current.data.uploadedAt))throw new Error('Newer cloud document retained; resolve version conflict');
    } else if(revision) throw new Error('Versioned document requires a matching revision');
  }
  if(b.operation==='write' && existing && existing.data._syncDeleted)throw new Error('Record revision conflict');
  if(b.operation==='delete'){
    if(VS_recycleEnabled()&&b.syncProtocol!==2)throw new Error('Invalid sync operation');
    if(existing&&existing.data._syncDeleted)return {recordRevision:existing.data._syncRevision,syncProtocol:2,fileCleanup:VS_managedDeletedFile(store,b.id,existing.data)};
    {
      const revision=Utilities.getUuid(),data={schoolId:school,_syncDeleted:true,_syncRevision:revision};
      if(b.syncProtocol===2){data._syncOperationId=b.operationId;data._syncRequestHash=VS_layoutHash(VS_syncRequestShape(b));}
      if(b.collection==='documents' && existing){data.documentRevision=existing.data.documentRevision||'';const fileId=existing.data._syncDeletedFileId||existing.data.fileId;if(fileId)data._syncDeletedFileId=fileId;}
      if(VS_recycleEnabled()&&existing){const saved=VS_recycleSnapshot(b.collection,b.id,existing,revision);data._syncRecycleFileId=saved.fileId;data._syncRecycleUntil=saved.recoverUntil;}
      PropertiesService.getScriptProperties().setProperty('VS_RECORD_REV_'+b.collection,Utilities.getUuid());
      VS_sheetPut(store,{id:b.id,schoolId:school,data:data});
      return {recordRevision:revision,syncProtocol:2,fileCleanup:VS_managedDeletedFile(store,b.id,data)};
    }

  }
  if(b.operation!=='write'||!b.data||b.data.schoolId!==school)throw new Error('Invalid school record');
  const revision=Utilities.getUuid(),data=Object.assign({},b.data);
  Object.keys(data).filter(k=>k.indexOf('_syncRecycle')===0).forEach(k=>delete data[k]);
  delete data._syncDeleted;delete data._syncOperationId;delete data._syncRevision;
  data._syncRevision=revision;
  if(b.syncProtocol===2){data._syncOperationId=b.operationId;data._syncRequestHash=VS_layoutHash(VS_syncRequestShape(b));}
  delete data._syncDeletedFileId;delete data._syncFileCleanupComplete;
  const text=JSON.stringify({id:b.id,schoolId:school,data:data});if(text.length>512*1024)throw new Error('Record too large; upload files separately');
  PropertiesService.getScriptProperties().setProperty('VS_RECORD_REV_'+b.collection,Utilities.getUuid());VS_sheetPut(store,{id:b.id,schoolId:school,data:data});return {recordRevision:revision,syncProtocol:2};
}
/** Opt-in recovery proof for isolated TEST. Financial/document rows require review. */
function VS_enableTestBackupRecovery() {
  const p=PropertiesService.getScriptProperties();
  if(p.getProperty('VS_MANAGED_SCHOOL_ID')!=='vs-db8afb01a3be46a983c8284714d06e5d')throw new Error('Isolated TEST backup authorization required');
  VS_managedRoot();p.setProperty('VS_TEST_BACKUP_RECOVERY','1');
  const result={success:true,recordBackupVersion:4,financialRecoveryAutomatic:false};
  if(typeof console!=='undefined')console.log(JSON.stringify(result));return result;
}
function VS_testBackupRecoveryEnabled() {
  const p=PropertiesService.getScriptProperties();return p.getProperty('VS_MANAGED_SCHOOL_ID')==='vs-db8afb01a3be46a983c8284714d06e5d'&&p.getProperty('VS_TEST_BACKUP_RECOVERY')==='1';
}
function VS_verifiedRecordBackup(fileId) {
  const school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID');
  if(VS_BACKUP_READ_CACHE&&VS_BACKUP_READ_CACHE.school===school&&VS_BACKUP_READ_CACHE.id===fileId)return VS_BACKUP_READ_CACHE.backup;
  const file=VS_managedFile(fileId);
  if(file.getSize()>20*1024*1024)throw new Error('Backup exceeds verification limit');
  const text=file.getBlob().getDataAsString(),digest=VS_layoutHash(text);
  if(file.getDescription()!=='VIDYA_RECORD_BACKUP:'+school+':'+digest)throw new Error('Backup integrity requires review');
  const backup=JSON.parse(text);
  if(backup.schemaVersion!==4||backup.schoolId!==school||!backup.records||!backup.collectionRevisions)throw new Error('Foreign or unsupported backup');
  Object.keys(backup.records).forEach(col=>{VS_managedCollection(col);Object.keys(backup.records[col]).forEach(id=>{
    const data=backup.records[col][id];if(!/^[^/]{1,200}$/.test(id)||id==='.'||id==='..'||!data||data.schoolId!==school||typeof data._syncRevision!=='string')throw new Error('Backup record requires review');
  });});VS_BACKUP_READ_CACHE={school:school,id:fileId,backup:backup};return backup;
}
function VS_createVerifiedRecordBackup() {
  if(!VS_testBackupRecoveryEnabled())throw new Error('Isolated TEST backup authorization required');
  VS_BACKUP_READ_CACHE=null;
  const p=PropertiesService.getScriptProperties(),records={},heads={},properties=p.getProperties();
  if(properties.VS_LAST_VERIFIED_RECORD_BACKUP){try{VS_verifiedRecordBackup(properties.VS_LAST_VERIFIED_RECORD_BACKUP);}catch(_){/* Invalid prior backup does not block a fresh verified capture. */}}
  const collections=VS_LAYOUT_COLLECTIONS.filter(col=>properties['VS_RECORD_REV_'+col]);
  // Release the school lock between collections. A busy school invalidates this
  // snapshot instead of blocking normal sync for the whole backup duration.
  collections.forEach(col=>{
    const lock=LockService.getScriptLock();lock.waitLock(30000);
    try{const result=VS_managedRecordUnlocked({collection:col,operation:'read',syncProtocol:2});records[col]=result.records;heads[col]=result.collectionRevision;}
    finally{lock.releaseLock();}
  });
  const checkLock=LockService.getScriptLock();checkLock.waitLock(30000);
  try{
    const current=p.getProperties();
    if(VS_LAYOUT_COLLECTIONS.filter(col=>current['VS_RECORD_REV_'+col]).length!==collections.length||
       collections.some(col=>heads[col]!==properties['VS_RECORD_REV_'+col]||heads[col]!==current['VS_RECORD_REV_'+col]))
      throw new Error('Backup changed during capture; existing snapshot retained');
  }finally{checkLock.releaseLock();}
    const backup={schemaVersion:4,schoolId:p.getProperty('VS_MANAGED_SCHOOL_ID'),createdAt:Date.now(),records:records,collectionRevisions:heads,
      scope:'records_and_tombstones',documentBinariesIncluded:false};
    const text=JSON.stringify(backup);if(text.length>20*1024*1024)throw new Error('Backup exceeds verification limit');
    const file=VS_managedFolder(VS_managedRoot(),'Backups').createFile('Verified_Record_Backup_'+Date.now()+'.json',text,'application/json');
    file.setDescription('VIDYA_RECORD_BACKUP:'+backup.schoolId+':'+VS_layoutHash(text));
    const readback=VS_verifiedRecordBackup(file.getId());if(JSON.stringify(readback)!==text)throw new Error('Backup verification failed');
    const commitLock=LockService.getScriptLock();commitLock.waitLock(30000);
    try{if(Number(p.getProperty('VS_LAST_VERIFIED_RECORD_BACKUP_AT')||0)<=backup.createdAt){
      p.setProperty('VS_LAST_VERIFIED_RECORD_BACKUP',file.getId());p.setProperty('VS_LAST_VERIFIED_RECORD_BACKUP_AT',String(backup.createdAt));
    }}finally{commitLock.releaseLock();}
    return {fileId:file.getId(),recordBackupVersion:4,verified:true,collections:Object.keys(records).length,documentBinariesIncluded:false};
}
function VS_recoverMissingBackupRows(collection,store,verifiedBackup) {
  if(!VS_testBackupRecoveryEnabled()||['fee_payments','fee_ledger','teacher_salary','school_expenses','documents'].includes(collection))return;
  const p=PropertiesService.getScriptProperties(),id=p.getProperty('VS_LAST_VERIFIED_RECORD_BACKUP');if(!id)return;
  let backup=verifiedBackup;try{if(!backup)backup=VS_verifiedRecordBackup(id);}catch(_){p.setProperty('VS_LAST_RECORD_RECOVERY',JSON.stringify({at:Date.now(),verified:false,needsReview:true,code:'BACKUP_INTEGRITY_UNVERIFIED'}));return;}
  const rows=backup.records[collection];
  // Any accepted cloud write since this backup invalidates automatic recovery.
  if(!rows||backup.collectionRevisions[collection]!==p.getProperty('VS_RECORD_REV_'+collection))return;
  const existing=VS_sheetRecords(store),missing=Object.keys(rows).filter(key=>!existing[key]);
  if(missing.length>100){p.setProperty('VS_LAST_RECORD_RECOVERY',JSON.stringify({at:Date.now(),verified:false,needsReview:true,code:'RECOVERY_BATCH_REVIEW_REQUIRED'}));return;}
  missing.forEach(key=>VS_sheetPut(store,{id:key,schoolId:store.school,data:rows[key]}));
  if(missing.length){p.setProperty('VS_RECORD_REV_'+collection,Utilities.getUuid());
    p.setProperty('VS_LAST_RECORD_RECOVERY',JSON.stringify({at:Date.now(),restored:missing.length,verified:true,financial:false}));}
}
/** Owner-only real-cloud rehearsal. Deletes only its own fresh disposable row,
 * after verifying the complete record backup; ordinary read then repairs it. */
function VS_testMissingRecordRecoveryRehearsal() {
  if(!VS_testBackupRecoveryEnabled())throw new Error('Isolated TEST backup authorization required');
  const school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID');
  const id='recovery-rehearsal-'+Utilities.getUuid(),operation='recovery-create-'+Utilities.getUuid(),capturedAt=Date.now();
  const ack=VS_managedRecord({collection:'school_notices',operation:'write',id:id,syncProtocol:2,operationId:operation,expectedRecordRevision:'',
    data:{schoolId:school,syntheticTest:true,title:'Disposable missing-row recovery rehearsal',capturedAt:capturedAt}});
  const backup=VS_createVerifiedRecordBackup(),lock=LockService.getScriptLock();lock.waitLock(30000);
  try {
    const saved=VS_verifiedRecordBackup(backup.fileId),p=PropertiesService.getScriptProperties(),store=VS_managedSheet('school_notices'),row=VS_sheetItem(store,id);
    if(!row||row.data.syntheticTest!==true||row.data._syncRevision!==ack.recordRevision||saved.collectionRevisions.school_notices!==p.getProperty('VS_RECORD_REV_school_notices'))throw new Error('TEST rehearsal changed; no fault injected');
    store.sheet.getRange(row.row,1,1,33).setValues([Array(33).fill('')]);SpreadsheetApp.flush();
    if(VS_sheetItem(store,id))throw new Error('TEST fault injection unverified');
    const result=VS_managedRecordUnlocked({collection:'school_notices',operation:'read',syncProtocol:2,knownRevision:saved.collectionRevisions.school_notices}),restored=result.records&&result.records[id];
    if(!restored||restored._syncRevision!==ack.recordRevision||restored._syncOperationId!==operation||restored.capturedAt!==capturedAt)throw new Error('TEST recovery readback failed; verified backup retained');
    const evidence={at:Date.now(),stage:'missing_row_cloud_readback',success:true,verifiedDriveBackup:true,recordRevisionPreserved:true,operationIdentityPreserved:true,timestampPreserved:true,originalSchoolTouched:false};
    if(typeof console!=='undefined')console.log(JSON.stringify(evidence));return evidence;
  } finally {lock.releaseLock();}
}
function VS_managedFile(id) {
  const file=DriveApp.getFileById(id),root=VS_managedRoot().getId(),seen={};
  function own(folder){if(folder.getId()===root)return true;if(seen[folder.getId()])return false;seen[folder.getId()]=true;const parents=folder.getParents();while(parents.hasNext())if(own(parents.next()))return true;return false;}
  const parents=file.getParents();while(parents.hasNext())if(own(parents.next()))return file;throw new Error('Foreign school file');
}
function VS_managedConnect(b) {
  const p=PropertiesService.getScriptProperties(),school=p.getProperty('VS_MANAGED_SCHOOL_ID');
  if(!school||b.schoolId!==school||!/^[a-f0-9]{64}$/.test(b.ticket||''))throw new Error('School storage connection rejected');
  VS_managedRoot();
  // Fixed trusted broker. Never accept a caller-supplied URL or Firebase token.
  const response=UrlFetchApp.fetch('https://saarthi-oauth-staging.onrender.com/school-cloud',{method:'post',contentType:'application/json',payload:JSON.stringify({action:'managed/storage/authorize',schoolId:school,ticket:b.ticket}),muteHttpExceptions:true});
  const authorization=JSON.parse(response.getContentText());
  if(response.getResponseCode()!==200||authorization.success!==true||authorization.schoolId!==school)throw new Error('Connection ticket rejected');
  const secret=p.getProperty('VS_MANAGED_SECRET');if(!/^[a-f0-9]{64}$/.test(secret||''))throw new Error('Managed storage not prepared');
  return jsonResponse({success:true,schoolId:school,storageReady:true,connectionSecret:secret});
}
// Fixed diagnostic categories only. Never return/log exception text, stack or record contents.
function VS_managedDiagnostic(error) {
  const message=String(error && error.message || '');
  const known={
    'Signed school request required':'SCRIPT_SIGNED_REQUEST_REQUIRED',
    'Invalid request signature':'SCRIPT_SIGNATURE_REJECTED',
    'Request already used':'SCRIPT_REPLAY_REJECTED',
    'Retry storage shortly':'SCRIPT_NONCE_CAPACITY',
    'School Drive root mismatch':'SCRIPT_ROOT_IDENTITY_MISMATCH',
    'School workbook identity mismatch':'SCRIPT_WORKBOOK_IDENTITY_MISMATCH',
    'Pending workbook identity mismatch':'SCRIPT_WORKBOOK_IDENTITY_MISMATCH',
    'School workbook requires operator review':'SCRIPT_WORKBOOK_REVIEW_REQUIRED',
    'Invalid or duplicate legacy record; operator review required':'SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED',
    'Foreign school record':'SCRIPT_FOREIGN_RECORD_REJECTED',
    'Invalid sync operation':'SCRIPT_INVALID_SYNC_OPERATION',
    'Versioned document requires a matching revision':'SCRIPT_DOCUMENT_REVISION_REQUIRED',
    'Newer cloud document retained; resolve version conflict':'SCRIPT_DOCUMENT_REVISION_CONFLICT',
    'Migration conflict; both versions retained':'SCRIPT_MIGRATION_CONFLICT',
    'Verified school tab is missing; operator recovery required':'SCRIPT_MISSING_MIGRATED_TAB',
    'School record verification failed':'SCRIPT_RECORD_VERIFY_FAILED',
    'Managed storage not prepared':'SCRIPT_STORAGE_NOT_PREPARED',
    'School data organization in progress; retry Sync. Pending data retained':'SCRIPT_MIGRATION_PENDING'
  };
  if(known[message])return known[message];
  if(/permission|not authorized|authorization is required|access denied/i.test(message))return 'SCRIPT_PERMISSION_DENIED';
  if(/quota|too many times|limit exceeded/i.test(message))return 'SCRIPT_QUOTA_EXCEEDED';
  if(/lock|timed out|timeout/i.test(message))return 'SCRIPT_TIMEOUT';
  if(error && error.name==='TypeError')return 'SCRIPT_TYPE_ERROR';
  if(error && error.name==='SyntaxError')return 'SCRIPT_PARSE_ERROR';
  return 'SCRIPT_OPERATION_FAILED';
}

function VS_managedHandle(e) {
  VS_BACKUP_READ_CACHE=null;
  const school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID');
  let verified=false;
  try {
    const request=JSON.parse(e.postData.contents);
    if(request.action==='managed_connect')return VS_managedConnect(request);
    const b=VS_managedVerify(e);verified=true;let result;
    if(b.action==='managed_health'){
      VS_managedRoot();const p=PropertiesService.getScriptProperties();let sheetsVerified=null;
      if(VS_testBackupRecoveryEnabled()){
        const properties=p.getProperties(),collection=VS_LAYOUT_COLLECTIONS.find(col=>properties['VS_SHEET_MIGRATED_'+col]==='1');
        if(collection){const store=VS_managedSheet(collection),parts=store.partitions||[store];parts.forEach(part=>{
          if(part.sheet.getRange(1,1,1,1).getValues()[0][0]!=='Record Key')throw new Error('School tab identity requires review');
        });sheetsVerified=true;}
      }
      result={storageReady:true,driveRootVerified:true,sheetsAccessVerified:sheetsVerified,documentVersions:1,recordSyncVersion:2,recordDeltaBatchVersion:1,recordStorageVersion:1,organizedStorageVersion:2,managedViewVersion:1,recycleVersion:VS_recycleEnabled()?1:0,
        recordBackupVersion:VS_testBackupRecoveryEnabled()?4:0,disasterRehearsalVersion:VS_testBackupRecoveryEnabled()?5:0,lastVerifiedRecordBackupAt:Number(p.getProperty('VS_LAST_VERIFIED_RECORD_BACKUP_AT')||0),
        scriptBundleVersion:'2026-10-10.3',googleEmail:''};
    }
    else if(b.action==='managed_delta'){result=VS_managedDelta(b);}
    else if(b.action==='managed_view'){result=VS_managedView(b);}
    else if(b.action==='managed_mobile'){result=VS_managedMobile(b.request,b.lease);}
    else if(b.action==='managed_attendance_batch'){
      if(!Array.isArray(b.operations)||b.operations.length>25)throw new Error('Invalid attendance batch');
      result={acknowledgements:b.operations.map(op=>{
        if(!/^[a-f0-9]{64}$/.test(op.operationId||''))throw new Error('Invalid attendance operation');
        try{VS_managedMobile(Object.assign({},op.request,{action:'mobile_mark_attendance',operationId:op.operationId}),b.lease);return {operationId:op.operationId,success:true};}
        catch(e){const authoritative=/School (session expired|record or ID|licence|is closed)|already recorded|Attendance can be marked|own school ID|Accurate school location/.test(e.message||'');return {operationId:op.operationId,success:false,authoritative:authoritative};}
      })};
    }
    else if(b.action==='managed_summary'){result=VS_managedSummary();}
    else if(b.action==='managed_records'){result=VS_managedRecord(b);}
    else if(b.action==='managed_upload'){
      if(!/^[-\w.+]+\/[-\w.+]+$/.test(b.mime||'')||typeof b.name!=='string'||b.name.length>200)throw new Error('Invalid file');const bytes=Utilities.base64Decode(b.base64);if(!bytes.length||bytes.length>20*1024*1024)throw new Error('File limit exceeded');
      const lock=LockService.getScriptLock();lock.waitLock(30000);
      try {
        const root=VS_managedRoot(),target=PropertiesService.getScriptProperties().getProperty('VS_LAYOUT_JOB')?VS_managedFolder(root,'Other_Files'):VS_managedFolder(VS_managedFolder(root,'Files'),b.mime.indexOf('image/')===0?'Photos':'Documents');let file=null,marker='';
        if(b.uploadKey!==undefined) {
          if(!/^[A-Za-z0-9_-]{1,150}$/.test(b.uploadKey))throw new Error('Invalid upload key');
          const digest=Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,bytes).map(v=>('0'+((v+256)%256).toString(16)).slice(-2)).join('');
          marker='VIDYA_UPLOAD:'+school+':'+b.uploadKey+':'+digest;
          for(const source of VS_layoutUploadFolders(root,target)){const matches=source.getFilesByName(b.name);if(matches.hasNext()){const found=matches.next();if(matches.hasNext()||found.getDescription()!==marker||(file&&file.getId()!==found.getId()))throw new Error('Upload key collision; existing file retained');file=found;}}
        }
        if(!file){file=target.createFile(Utilities.newBlob(bytes,b.mime,b.name));if(marker)file.setDescription(marker);}
        result={fileId:file.getId(),fileUrl:'https://drive.google.com/file/d/'+file.getId()+'/view'};
      } finally {lock.releaseLock();}

    }else if(b.action==='managed_file'){
      const blob=VS_managedFile(b.fileId).getBlob();if(blob.getBytes().length>20*1024*1024)throw new Error('File limit exceeded');result={mime:blob.getContentType(),base64:Utilities.base64Encode(blob.getBytes())};
    }else if(b.action==='managed_backup'){
      if(VS_testBackupRecoveryEnabled())return jsonResponse(Object.assign({success:true,schoolId:school},VS_createVerifiedRecordBackup()));
      const root=VS_managedRoot(),folders=root.getFolders(),records={};while(folders.hasNext()){const f=folders.next();if(f.getName().indexOf('records_')===0)records[f.getName().slice(8)]=VS_managedRecord({collection:f.getName().slice(8),operation:'read'}).records;}
      const text=JSON.stringify({schemaVersion:3,schoolId:school,createdAt:new Date().toISOString(),records:records});if(text.length>20*1024*1024)throw new Error('Backup exceeds safe file limit');const file=VS_managedFolder(root,'Backups').createFile('School_Backup_'+Date.now()+'.json',text,'application/json');result={fileId:file.getId(),fileUrl:'https://drive.google.com/file/d/'+file.getId()+'/view'};
    }else if(b.action==='managed_disaster'){
      result=VS_managedDisaster(b);
    }else if(b.action==='managed_recycle'){
      result=VS_managedRecycle(b);
    }else if(b.action==='managed_restore'){
      const file=VS_managedFile(b.fileId),blob=file.getBlob();if(blob.getBytes().length>20*1024*1024)throw new Error('Backup too large');const backup=JSON.parse(blob.getDataAsString());
      if(backup.schemaVersion!==3||backup.schoolId!==school||!backup.records||typeof backup.records!=='object')throw new Error('Foreign or unsupported backup');
      const pending=[];Object.keys(backup.records).forEach(col=>{VS_managedCollection(col);Object.keys(backup.records[col]).forEach(id=>{const data=backup.records[col][id];if(!/^[^/]{1,200}$/.test(id)||id==='.'||id==='..'||!data||data.schoolId!==school)throw new Error('Invalid backup record');pending.push({collection:col,id:id,data:data,operation:'write',createOnly:true});});});
      let copied=0,skipped=0;const lock=LockService.getScriptLock();lock.waitLock(30000);try{pending.forEach(r=>{const result=VS_managedRecordUnlocked(r);if(result.skipped)skipped++;else copied++;});}finally{lock.releaseLock();}result={copied:copied,skipped:skipped};
    }else throw new Error('Unknown managed storage action');
    return jsonResponse(Object.assign({success:true,schoolId:school},result));
  }catch(error){
    const safe={
      'This QR does not belong to the active school':'This QR is invalid or has not synced to this school. Ask the school to sync or regenerate the ID card.',
      'Record revision conflict':'Record revision conflict',
      'Sync operation ID conflict':'Sync operation ID conflict',
      'School data organization in progress; retry Sync. Pending data retained':'School data organization in progress; retry Sync. Pending data retained',
      'This ID card needs a new secure school QR':'Ask your school to regenerate this ID card.',
      'Class, roll number or date of birth is incorrect':'Class, roll number or date of birth is incorrect',
      'School session expired':'School session expired. Scan your ID again.',
      'School record or ID card was changed; scan again':'School record or ID card was changed; scan again'
    };
    // Owner-only execution diagnostics: constants and source line, never raw
    // exceptions, payloads, identities, signatures, paths or credentials.
    const diagnostic=VS_managedDiagnostic(error);
    const site=String(error&&error.stack||'').match(/(?:Code|SaarthiManagedAll)(?:\.gs)?:(\d+)/);
    const trace={event:'managed_storage_failure',at:Date.now(),phase:verified?'authorized_operation':'request_verification',code:diagnostic,line:site?Number(site[1]):0};
    if(typeof console!=='undefined')console.info(JSON.stringify(trace));
    // Anonymous web-app executions may not expose logs in the default Cloud
    // project. Keep only the same non-sensitive trace in a short-lived cache.
    try{CacheService.getScriptCache().put('VS_SYNC_DIAGNOSTIC_V1',JSON.stringify(trace),1800);}catch(_){}
    const code=verified?diagnostic:'SCRIPT_OPERATION_FAILED';
    return jsonResponse({success:false,schoolId:school,message:safe[error.message]||'School storage request rejected',code:code});
  }
}

// Run manually in the owner editor only; not routed through doPost/doGet.
function VS_readLastSyncDiagnostic() {
  const trace=CacheService.getScriptCache().get('VS_SYNC_DIAGNOSTIC_V1');
  Logger.log(trace||'No recent sync diagnostic captured');
}

// Organized storage is a layout of the SAME revision/CAS adapter, not a second
// sync engine. Owner-editor steps are explicit; installing code never migrates.
const VS_LAYOUT_COLLECTIONS = ['students_directory','teachers_directory','attendance_logs','teacher_attendance','attendance_records','teacher_schedules','school_notices','school_calendar','exam_results','teacher_salary','school_config','school_settings','fee_settings','fee_ledger','fee_payments','school_expenses','student_scan_index','scanner_devices','documents','backups','exams','exam_center_results','mobile_sessions','mobile_users','mobile_complaints'];
function VS_layoutHash(value) {
  function ordered(v){if(Array.isArray(v))return v.map(ordered);if(v&&typeof v==='object'){const out=Object.create(null);Object.keys(v).sort().forEach(k=>out[k]=ordered(v[k]));return out;}return v;}
  return Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,JSON.stringify(ordered(value)),Utilities.Charset.UTF_8).map(v=>('0'+((v+256)%256).toString(16)).slice(-2)).join('');
}
function VS_layoutState(collection) {
  if(VS_LAYOUT_COLLECTIONS.indexOf(collection)<0)throw new Error('Unknown collection');
  const text=PropertiesService.getScriptProperties().getProperty('VS_LAYOUT_'+collection);
  if(!text)return null;const state=JSON.parse(text);
  if(state.version!==2||state.schoolId!==PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID')||state.collection!==collection)throw new Error('School layout identity mismatch');
  return state;
}
function VS_layoutSave(state){PropertiesService.getScriptProperties().setProperty('VS_LAYOUT_'+state.collection,JSON.stringify(state));}
function VS_managedSheet(collection,readContext) {
  const state=VS_layoutState(collection);
  return state&&['active','rollingBack'].indexOf(state.phase)>=0?VS_layoutStore(state,readContext):VS_legacySheet(collection,readContext);
}
function VS_layoutTargets(collection) {
  if(collection==='teacher_attendance')return ['05_Teacher_Attendance','06_Staff_Attendance','17_Other_School_Records'];
  if(collection==='teachers_directory')return ['02_Teachers','03_Other_Staff','17_Other_School_Records'];
  if(['attendance_records','attendance_logs'].indexOf(collection)>=0)return ['04_Student_Attendance','05_Teacher_Attendance','06_Staff_Attendance','17_Other_School_Records'];
  const map={students_directory:'01_Students',teacher_attendance:'05_Teacher_Attendance',fee_ledger:'07_School_Fees',fee_payments:'07_School_Fees',fee_settings:'08_Fee_Structure',school_expenses:'09_School_Expenses',exams:'10_Examinations',exam_results:'11_Exam_Results',exam_center_results:'11_Exam_Results',teacher_salary:'12_Staff_Salary',school_notices:'13_School_Notices',school_config:'14_School_Profile',school_settings:'14_School_Profile',school_calendar:'15_Academic_Sessions',documents:'16_Documents_Metadata',backups:'16_Documents_Metadata'};
  return [map[collection]||'17_Other_School_Records'];
}
function VS_layoutPartition(collection,data) {
  const role=String(data.role||data.ownerRole||data.personRole||data.staffType||data.staffCategory||data.type||'').toLowerCase().replace(/[ _-]/g,'');
  if(collection==='teacher_attendance')return role==='teacher'?0:['staff','otherstaff','nonteaching','nonteachingstaff','supportstaff'].indexOf(role)>=0?1:2;
  if(collection==='teachers_directory')return ['teacher','teaching','teachingstaff'].indexOf(role)>=0?0:['staff','otherstaff','nonteaching','nonteachingstaff','supportstaff'].indexOf(role)>=0?1:2;
  if(['attendance_records','attendance_logs'].indexOf(collection)>=0){
    if(role==='student'||data.studentId&&!data.teacherId)return 0;
    if(['staff','otherstaff','nonteaching','nonteachingstaff','supportstaff'].indexOf(role)>=0)return 2;
    if(role==='teacher'||data.teacherId&&!data.studentId)return 1;
    return 3;
  }
  return 0;
}
function VS_layoutBook(name) {
  const p=PropertiesService.getScriptProperties(),school=p.getProperty('VS_MANAGED_SCHOOL_ID');
  const key='VS_LAYOUT_BOOK_'+name,pendingKey='VS_LAYOUT_PENDING_'+name,root=VS_managedRoot(),filename=name+' — '+school;
  let id=p.getProperty(key)||p.getProperty(pendingKey);
  if(!id){
    // Unique school name also detects a create-timeout orphan outside the root.
    const local=root.getFilesByName(filename),global=DriveApp.getFilesByName(filename),candidates={};
    [local,global].forEach(matches=>{while(matches.hasNext()){const file=matches.next();candidates[file.getId()]=file;}});
    const ids=Object.keys(candidates);if(ids.length>1)throw new Error('Duplicate organized workbook; operator review required');
    if(ids.length){const file=candidates[ids[0]];if(file.getDescription()!=='VIDYA_LAYOUT:'+school+':'+name)throw new Error('Unverified create-timeout workbook; owner review required');id=file.getId();}
    else{const book=SpreadsheetApp.create(filename);id=book.getId();p.setProperty(pendingKey,id);}
    p.setProperty(key,id);
  }
  const file=DriveApp.getFileById(id),marker='VIDYA_LAYOUT:'+school+':'+name;
  if(!file.getDescription()&&p.getProperty(pendingKey)===id)file.setDescription(marker);
  if(file.getDescription()!==marker)throw new Error('Organized workbook identity mismatch');
  let own=false;const parents=file.getParents();while(parents.hasNext())if(parents.next().getId()===root.getId())own=true;
  if(!own)file.moveTo(root);VS_managedFile(id);p.deleteProperty(pendingKey);return id;
}
function VS_layoutStore(state,readContext) {
  const school=state.schoolId;
  return {school:school,collection:state.collection,partitions:state.targets.map(target=>{
    const key=school+':'+target.id+':'+target.name,verified=readContext&&readContext.layoutBooks&&readContext.layoutBooks[key];let book;
    if(verified)book=verified;
    else{const f=VS_managedFile(target.id);if(f.getDescription()!=='VIDYA_LAYOUT:'+school+':'+target.name)throw new Error('Organized workbook identity mismatch');book=SpreadsheetApp.openById(target.id);if(readContext){if(!readContext.layoutBooks)readContext.layoutBooks=Object.create(null);readContext.layoutBooks[key]=book;}}
    let sheet=book.getSheetByName(state.collection);
    if(!sheet){if(['active','rollingBack'].indexOf(state.phase)>=0)throw new Error('Active organized tab missing');sheet=book.insertSheet(state.collection);if(sheet.getMaxColumns()<33)sheet.insertColumnsAfter(sheet.getMaxColumns(),33-sheet.getMaxColumns());sheet.getRange(1,1,1,33).setValues([['Record Key','School ID','Revision','Deleted','Operation ID','Display Name'].concat(Array.from({length:27},(_,n)=>'Data '+(n+1)))]);sheet.setFrozenRows(1);}
    return {sheet:sheet,school:school};
  })};
}
function VS_layoutEntries(store) {
  const last=store.sheet.getLastRow();return last<2?[]:store.sheet.getRange(2,1,last-1,33).getValues().filter(v=>v[0]).map(v=>VS_sheetDecode(store,v));
}
function VS_layoutChoose(items) {
  if(!items.length)return null;
  const hashes=items.map(item=>VS_layoutHash(item.data));
  if(hashes.every(hash=>hash===hashes[0]))return items[0];
  const proven=items.filter((item,index)=>Array.isArray(item.layoutPrevious)&&hashes.every((hash,n)=>n===index||item.layoutPrevious.indexOf(hash)>=0));
  if(proven.length!==1)throw new Error('Partition conflict; all versions retained');return proven[0];
}
function VS_layoutItem(store,id) {
  return VS_layoutChoose(store.partitions.map(part=>VS_sheetItem(part,id)).filter(item=>item&&!item.layoutRedirect));
}
function VS_layoutPut(store,item) {
  const index=VS_layoutPartition(store.collection,item.data),previous=[];
  store.partitions.forEach((part,n)=>{if(n!==index){const old=VS_sheetItem(part,item.id);if(old&&!old.layoutRedirect)previous.push(VS_layoutHash(old.data));}});
  VS_sheetPut(store.partitions[index],Object.assign({},item,previous.length?{layoutPrevious:previous}:{}));
  store.partitions.forEach((part,n)=>{if(n===index)return;const old=VS_sheetItem(part,item.id);if(old&&!old.layoutRedirect)VS_sheetPut(part,{id:old.id,schoolId:old.schoolId,data:old.data,layoutRedirect:index+1});});
}
function VS_layoutRecords(store) {
  const groups=Object.create(null),records=Object.create(null);store.partitions.forEach(part=>VS_layoutEntries(part).forEach(item=>{if(!item.layoutRedirect)(groups[item.id]||(groups[item.id]=[])).push(item);}));
  Object.keys(groups).forEach(id=>records[id]=VS_layoutChoose(groups[id]).data);return records;
}
function VS_layoutSnapshot(collection,records,label) {
  const school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID');
  const value={version:2,schoolId:school,collection:collection,records:records},text=JSON.stringify(value);
  if(text.length>20*1024*1024)throw new Error('Snapshot exceeds safe limit; source retained');
  const hash=VS_layoutHash(value),folder=VS_managedFolder(VS_managedRoot(),'Backup_And_Recovery');
  const name='Layout_'+label+'_'+Utilities.getUuid()+'.json',file=folder.createFile(name,text,'application/json');file.setDescription('VIDYA_LAYOUT_BACKUP:'+school+':'+hash);
  const saved=JSON.parse(VS_managedFile(file.getId()).getBlob().getDataAsString());if(VS_layoutHash(saved)!==hash)throw new Error('Backup verification failed');return {id:file.getId(),hash:hash};
}
function VS_layoutVerifyBackup(backup) {
  const school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID'),f=VS_managedFile(backup.id);
  if(f.getDescription()!=='VIDYA_LAYOUT_BACKUP:'+school+':'+backup.hash||VS_layoutHash(JSON.parse(f.getBlob().getDataAsString()))!==backup.hash)throw new Error('Backup changed; migration paused');
}
function VS_layoutCopy(collection,rollback,limit) {
  let state=VS_layoutState(collection);const p=PropertiesService.getScriptProperties(),school=p.getProperty('VS_MANAGED_SCHOOL_ID');
  if(!state){const source=VS_legacySheet(collection),records=VS_sheetRecords(source);state={version:2,schoolId:school,collection:collection,phase:'copying',cursor:0,revision:p.getProperty('VS_RECORD_REV_'+collection)||'legacy',backup:VS_layoutSnapshot(collection,records,'before_'+collection),targets:VS_layoutTargets(collection).map(name=>({name:name,id:VS_layoutBook(name)}))};VS_layoutSave(state);}
  if(!rollback&&state.phase==='active'||rollback&&state.phase==='rolledBack')return {complete:true,phase:state.phase};
  if(rollback&&state.phase==='active'){VS_layoutVerifyBackup(state.backup);state.rollbackBackup=VS_layoutSnapshot(collection,VS_sheetRecords(VS_layoutStore(state)),'before_rollback_'+collection);state.phase='rollingBack';state.cursor=0;state.revision=p.getProperty('VS_RECORD_REV_'+collection)||'legacy';VS_layoutSave(state);}
  if(rollback&&state.phase!=='rollingBack')throw new Error('Collection is not active');
  if(!rollback&&state.phase!=='copying')throw new Error('Collection migration requires review');
  VS_layoutVerifyBackup(state.backup);if(state.rollbackBackup)VS_layoutVerifyBackup(state.rollbackBackup);if(state.activationBackup)VS_layoutVerifyBackup(state.activationBackup);
  const revision=p.getProperty('VS_RECORD_REV_'+collection)||'legacy';if(state.revision!==revision){state.revision=revision;state.cursor=0;}
  const organized=VS_layoutStore(state),legacy=VS_legacySheet(collection),source=rollback?organized:legacy,target=rollback?legacy:organized;
  const records=VS_sheetRecords(source),ids=Object.keys(records).sort();
  for(let n=0;n<limit&&state.cursor<ids.length;n++,state.cursor++){const id=ids[state.cursor];VS_sheetPut(target,{id:id,schoolId:school,data:records[id]});}
  if(state.cursor===ids.length){
    const copied=VS_sheetRecords(target);if(VS_layoutHash(records)!==VS_layoutHash(copied))throw new Error('Migration validation mismatch; authoritative route retained');
    state.activationBackup=VS_layoutSnapshot(collection,records,(rollback?'rollback_':'activate_')+collection);
    state.count=ids.length;state.reviewCount=!rollback&&organized.partitions.length>1?VS_layoutEntries(organized.partitions[organized.partitions.length-1]).filter(item=>!item.layoutRedirect&&!item.data._syncDeleted).length:0;state.hash=VS_layoutHash(records);state.phase=rollback?'rolledBack':'active';
  }
  // This single property is the activation commit point. A crash before it
  // leaves source authoritative; after it all readers/writers use the new route.
  VS_layoutSave(state);return {complete:state.phase!=='copying'&&state.phase!=='rollingBack',phase:state.phase,copied:state.cursor,count:ids.length};
}
function VS_layoutBinaryInventory() {
  const root=VS_managedRoot(),pending=[root],files=[],seen={};let visited=0;
  while(pending.length){const folder=pending.shift();if(seen[folder.getId()])throw new Error('Drive ancestry cycle');seen[folder.getId()]=true;if(++visited+files.length>5000)throw new Error('Drive inventory limit; source retained');
    const name=folder.getName();if(name==='Backups'||name==='Backup_And_Recovery'||name.indexOf('records_')===0)continue;
    const children=folder.getFolders();while(children.hasNext())pending.push(children.next());
    const entries=folder.getFiles();while(entries.hasNext()){const f=entries.next(),mime=f.getMimeType?f.getMimeType():f.getBlob().getContentType();if(mime.indexOf('application/vnd.google-apps.')===0||mime==='application/json')continue;
      if(files.length+visited>=5000)throw new Error('Drive inventory limit; source retained');const parents=f.getParents(),ids=[];while(parents.hasNext())ids.push(parents.next().getId());files.push({id:f.getId(),name:f.getName(),mime:mime,size:f.getSize(),parents:ids});}
  }return files;
}
function VS_layoutBinaryTarget(entry) {
  // Stable Drive IDs are preserved. Unclassified assets have their own folder;
  // never invent a student/teacher identity from a filename.
  const map={};function reference(value,target){if(typeof value!=='string')return;const match=value.match(/(?:\/d\/|[?&]id=)([A-Za-z0-9_-]+)/);const id=match?match[1]:value;if(!/^[A-Za-z0-9_-]+$/.test(id))return;if(map[id]&&map[id]!==target)map[id]='Other_Files';else map[id]=target;}
  ['students_directory','teachers_directory','school_config','documents'].forEach(col=>{const records=VS_sheetRecords(VS_managedSheet(col));Object.keys(records).forEach(id=>{const d=records[id];if(d._syncDeleted)return;
    const role=String(d.ownerRole||d.role||'').toLowerCase(),photoTarget=col==='students_directory'?'Student_Photos':col==='teachers_directory'?(role==='teacher'?'Teacher_Photos':role==='staff'?'Staff_Photos':'Other_Files'):'School_Assets';
    ['photoUrl','photoFileId','logoUrl','sealUrl','signatureUrl'].forEach(key=>reference(d[key],photoTarget));
    if(d.fileId)reference(d.fileId,col==='documents'?(d.documentKind==='idCard'?'ID_Cards':role==='student'?'Student_Documents':role==='teacher'?'Teacher_Documents':role==='staff'?'Staff_Documents':'Other_Files'):'School_Assets');});});
  return map[entry.id]||'Other_Files';
}
function VS_layoutBinaryStep(job,rollback,limit) {
  VS_layoutVerifyBackup(job.binaryManifest);const manifest=JSON.parse(VS_managedFile(job.binaryManifest.id).getBlob().getDataAsString()).records;
  const p=PropertiesService.getScriptProperties(),school=job.schoolId,backupFolder=VS_managedFolder(VS_managedRoot(),'Backup_And_Recovery');
  for(let n=0;n<limit&&job.binaryCursor<manifest.length;n++,job.binaryCursor++){
    const entry=manifest[job.binaryCursor],file=VS_managedFile(entry.id);if(file.getSize()>20*1024*1024)throw new Error('Binary exceeds safe backup limit; file retained');
    const auditName='Audit_'+entry.id+'.json',auditFiles=backupFolder.getFilesByName(auditName);let audit=null;if(auditFiles.hasNext()){const f=auditFiles.next();if(auditFiles.hasNext())throw new Error('Duplicate binary audit');audit=JSON.parse(f.getBlob().getDataAsString());}
    if(!audit){if(rollback)continue;const blob=file.getBlob(),bytes=blob.getBytes(),hash=VS_layoutBytesHash(bytes),name='Original_'+entry.id;
      const found=backupFolder.getFilesByName(name);let copy;if(found.hasNext()){copy=found.next();if(found.hasNext()||copy.getDescription()!=='VIDYA_BINARY_BACKUP:'+school+':'+hash)throw new Error('Binary backup collision');}
      else {copy=backupFolder.createFile(Utilities.newBlob(bytes,entry.mime,name));copy.setDescription('VIDYA_BINARY_BACKUP:'+school+':'+hash);}
      if(VS_layoutBytesHash(copy.getBlob().getBytes())!==hash)throw new Error('Binary backup verification failed');
      audit={schoolId:school,hash:hash,backupId:copy.getId(),target:VS_layoutBinaryTarget(entry)};const auditFile=backupFolder.createFile(auditName,JSON.stringify(audit),'application/json');if(VS_layoutHash(JSON.parse(auditFile.getBlob().getDataAsString()))!==VS_layoutHash(audit))throw new Error('Binary audit verification failed');}
    if(audit.schoolId!==school||VS_layoutBytesHash(VS_managedFile(audit.backupId).getBlob().getBytes())!==audit.hash||VS_layoutBytesHash(file.getBlob().getBytes())!==audit.hash)throw new Error('Binary changed; both versions retained');
    if(entry.parents.length!==1)throw new Error('Ambiguous binary parents; file retained');
    const target=rollback?DriveApp.getFolderById(entry.parents[0]):VS_managedFolder(VS_managedRoot(),audit.target);VS_layoutOwnFolder(target);
    // Parent must itself still belong to this school's ancestry.
    const current=file.getParents();let already=false,recognized=false;while(current.hasNext()){const parent=current.next();if(parent.getId()===target.getId())already=true;if(parent.getId()===entry.parents[0]||parent.getName()===audit.target)recognized=true;}
    if(!already&&!recognized)throw new Error('Binary was independently relocated; file retained');
    if(!already)file.moveTo(target);VS_managedFile(entry.id);const actual=file.getParents();if(!actual.hasNext()||actual.next().getId()!==target.getId()||actual.hasNext())throw new Error('Binary move not verified');if(VS_layoutBytesHash(file.getBlob().getBytes())!==audit.hash)throw new Error('Binary content changed during move');
  }
  return job.binaryCursor===manifest.length;
}
/** Owner editor ONLY; no signed API route. Run begin once, then step until done.
 * Installing this source never activates a layout or moves a school file.
 */
/** Read-only owner preview: never creates/backfills tabs or moves files. */
function VS_previewOrganizedStorageMigration() {
  const lock=LockService.getScriptLock();lock.waitLock(30000);
  try {
    const p=PropertiesService.getScriptProperties(),school=p.getProperty('VS_MANAGED_SCHOOL_ID'),root=VS_managedRoot(),collections=[];
    VS_LAYOUT_COLLECTIONS.forEach(collection=>{
      const state=VS_layoutState(collection);let records=Object.create(null);
      if(state&&['active','rollingBack'].indexOf(state.phase)>=0)records=VS_sheetRecords(VS_layoutStore(state));
      else {
        const bookId=p.getProperty('VS_MANAGED_SHEET_ID');
        if(bookId){const f=VS_managedFile(bookId);if(f.getDescription()!=='VIDYA_SCHOOL_DATA:'+school)throw new Error('School workbook identity mismatch');const sheet=SpreadsheetApp.openById(bookId).getSheetByName(collection);if(sheet)records=VS_sheetRecords({sheet:sheet,school:school});else if(p.getProperty('VS_SHEET_MIGRATED_'+collection)==='1')throw new Error('Verified school tab is missing; operator recovery required');}
        if(p.getProperty('VS_SHEET_MIGRATED_'+collection)!=='1'){
          const folders=root.getFoldersByName('records_'+collection);
          if(folders.hasNext()){
            const folder=folders.next();if(folders.hasNext())throw new Error('Duplicate collection folders; operator review required');const files=folder.getFiles(),seen=Object.create(null);let bytes=0;
            while(files.hasNext()){
              const raw=files.next().getBlob().getDataAsString();bytes+=raw.length;if(bytes>20*1024*1024)throw new Error('Collection migration exceeds safe limit');const item=JSON.parse(raw);
              if(!item||item.schoolId!==school||typeof item.id!=='string'||!item.data||item.data.schoolId!==school||seen[item.id])throw new Error('Invalid or duplicate legacy record; operator review required');seen[item.id]=true;
              if(records[item.id]&&VS_layoutHash(records[item.id])!==VS_layoutHash(item.data))throw new Error('Migration conflict; both versions retained');records[item.id]=item.data;
            }
          }
        }
      }
      const targets=VS_layoutTargets(collection),partitionCounts=Object.create(null);targets.forEach(name=>partitionCounts[name]=0);
      Object.keys(records).forEach(id=>partitionCounts[targets[VS_layoutPartition(collection,records[id])]]++);
      collections.push({collection:collection,count:Object.keys(records).length,hash:VS_layoutHash(records),partitionCounts:partitionCounts,sourcePhase:state?state.phase:'legacy'});
    });
    const files=VS_layoutBinaryInventory();return {dryRun:true,schoolId:school,rootFolderId:root.getId(),collections:collections,binaryCount:files.length,binaryBytes:files.reduce((sum,f)=>sum+f.size,0),oversizedFileIds:files.filter(f=>f.size>20*1024*1024).map(f=>f.id),limits:{snapshotBytes:20*1024*1024,binaryBytes:20*1024*1024,inventoryEntries:5000},writesPerformed:0};
  }finally{lock.releaseLock();}
}
function VS_beginOrganizedStorageMigration() {
  const lock=LockService.getScriptLock();lock.waitLock(30000);
  try{const p=PropertiesService.getScriptProperties(),old=p.getProperty('VS_LAYOUT_JOB');if(old)return VS_organizedStorageStatus();
    const school=p.getProperty('VS_MANAGED_SCHOOL_ID');VS_managedRoot();
    const manifest=VS_layoutSnapshot('binary_manifest',VS_layoutBinaryInventory(),'binary_inventory');
    p.setProperty('VS_LAYOUT_JOB',JSON.stringify({version:2,schoolId:school,id:Utilities.getUuid(),phase:'records',collectionCursor:0,binaryCursor:0,binaryManifest:manifest}));return VS_organizedStorageStatus();
  }finally{lock.releaseLock();}
}
function VS_stepOrganizedStorageMigration(){return VS_layoutJobStep(false);}
function VS_rollbackOrganizedStorageMigration(){return VS_layoutJobStep(true);}
function VS_layoutJobStep(rollback) {
  const lock=LockService.getScriptLock();lock.waitLock(30000);
  try{const p=PropertiesService.getScriptProperties(),raw=p.getProperty('VS_LAYOUT_JOB');if(!raw)throw new Error('Begin organized storage migration first');const job=JSON.parse(raw);
    if(job.version!==2||job.schoolId!==p.getProperty('VS_MANAGED_SCHOOL_ID'))throw new Error('Foreign migration job');
    if(rollback&&['rollingBackRecords','rollingBackFiles','rolledBack'].indexOf(job.phase)<0){job.phase='rollingBackRecords';job.collectionCursor=0;job.binaryCursor=0;}
    if(job.phase==='records'||job.phase==='rollingBackRecords'){
      while(job.collectionCursor<VS_LAYOUT_COLLECTIONS.length){const col=VS_LAYOUT_COLLECTIONS[job.collectionCursor],state=VS_layoutState(col);
        if(rollback&&(!state||['active','rollingBack'].indexOf(state.phase)<0)){job.collectionCursor++;continue;}
        const result=VS_layoutCopy(col,rollback,25);if(result.complete)job.collectionCursor++;break;}
      if(job.collectionCursor===VS_LAYOUT_COLLECTIONS.length)job.phase=rollback?'rollingBackFiles':'files';
    } else if(job.phase==='files'||job.phase==='rollingBackFiles'){
      if(VS_layoutBinaryStep(job,rollback,5))job.phase=rollback?'rolledBack':'complete';
    }
    p.setProperty('VS_LAYOUT_JOB',JSON.stringify(job));return VS_organizedStorageStatus();
  }finally{lock.releaseLock();}
}
function VS_organizedStorageStatus() {
  const p=PropertiesService.getScriptProperties(),raw=p.getProperty('VS_LAYOUT_JOB');if(!raw)return {started:false};const job=JSON.parse(raw);
  if(job.schoolId!==p.getProperty('VS_MANAGED_SCHOOL_ID'))throw new Error('Foreign migration job');
  return {started:true,schoolId:job.schoolId,migrationId:job.id,phase:job.phase,collectionCursor:job.collectionCursor,binaryCursor:job.binaryCursor,
    collections:VS_LAYOUT_COLLECTIONS.map(col=>{const state=VS_layoutState(col);return {collection:col,phase:state?state.phase:'legacy',count:state?state.count:null,reviewCount:state?state.reviewCount||0:0};})};
}

function VS_layoutBytesHash(bytes){return Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,bytes).map(v=>('0'+((v+256)%256).toString(16)).slice(-2)).join('');}
function VS_layoutOwnFolder(folder){const root=VS_managedRoot().getId(),seen={};function own(f){if(f.getId()===root)return true;if(seen[f.getId()])return false;seen[f.getId()]=true;const parents=f.getParents();while(parents.hasNext())if(own(parents.next()))return true;return false;}if(!own(folder))throw new Error('Foreign migration folder');}
function VS_layoutUploadFolders(root,target){const result=[target,root];const old=root.getFoldersByName('Files');if(old.hasNext()){const files=old.next();['Photos','Documents'].forEach(name=>{const matches=files.getFoldersByName(name);if(matches.hasNext())result.push(matches.next());});}['Student_Photos','Teacher_Photos','Staff_Photos','Student_Documents','Teacher_Documents','Staff_Documents','ID_Cards','School_Assets','Other_Files'].forEach(name=>{const matches=root.getFoldersByName(name);if(matches.hasNext())result.push(matches.next());});const seen={};return result.filter(f=>{if(seen[f.getId()])return false;seen[f.getId()]=true;return true;});}

function VS_managedView(b) {
  const lock=LockService.getScriptLock();lock.waitLock(30000);
  try{const p=PropertiesService.getScriptProperties(),known=b.knownRevisions||{},groups={},revisions={};
    const collections=['exams','fee_settings','fee_ledger','fee_payments','school_notices','school_config','school_settings'];
    function preview(key,records){const rows=Object.keys(records).filter(id=>!records[id]._syncDeleted&&!records[id].deleted).map(id=>Object.assign({},records[id],{id:id}));rows.sort((a,c)=>Number(c.updatedAt||c.timestamp||0)-Number(a.updatedAt||a.timestamp||0)||a.id.localeCompare(c.id));groups[key]={count:rows.length,rows:rows.slice(0,100)};}
    collections.forEach(col=>{const out=VS_managedRecordUnlocked({collection:col,operation:'read',syncProtocol:2,knownRevision:known[col]});revisions[col]=out.collectionRevision;if(!out.unchanged)preview(col,out.records);});
    ['exam_results','exam_center_results'].forEach(col=>VS_managedSheet(col));
    const revision=JSON.stringify(['exam_results','exam_center_results'].map(col=>p.getProperty('VS_RECORD_REV_'+col)||'legacy'));revisions.examResults=revision;
    if(known.examResults!==revision){const rows=Object.create(null),removed=Object.create(null);['exam_results','exam_center_results'].forEach(col=>{const all=VS_sheetRecords(VS_managedSheet(col));Object.keys(all).forEach(id=>{const row=all[id];if(row._syncDeleted||row.deleted)removed[id]=true;else if(!rows[id]||Number(row.timestamp||row.updatedAt||0)>=Number(rows[id].timestamp||rows[id].updatedAt||0))rows[id]=row;});});Object.keys(removed).forEach(id=>delete rows[id]);preview('examResults',rows);}
    const result={groups:groups,revisions:revisions,previewLimit:100};if(JSON.stringify(result).length>4*1024*1024)throw new Error('View exceeds safe limit');return result;
  }finally{lock.releaseLock();}
}

// Same version-2 record contracts, one lock/checkpoint round-trip per pull.
function VS_managedDelta(b) {
  VS_BACKUP_READ_CACHE=null;
  if(!Array.isArray(b.collections)||b.collections.length>22||new Set(b.collections).size!==b.collections.length||b.collections.some(col=>VS_LAYOUT_COLLECTIONS.indexOf(col)<0||['mobile_sessions','mobile_users','mobile_complaints'].indexOf(col)>=0))throw new Error('Invalid delta collections');
  const lock=LockService.getScriptLock();lock.waitLock(30000);
  try{const changes={},p=PropertiesService.getScriptProperties();
    let recoveryBackup=null;if(VS_testBackupRecoveryEnabled()&&p.getProperty('VS_LAST_VERIFIED_RECORD_BACKUP')){
      try{recoveryBackup=VS_verifiedRecordBackup(p.getProperty('VS_LAST_VERIFIED_RECORD_BACKUP'));}catch(_){p.setProperty('VS_LAST_RECORD_RECOVERY',JSON.stringify({at:Date.now(),verified:false,needsReview:true,code:'BACKUP_INTEGRITY_UNVERIFIED'}));}
    }
    b.collections.forEach(col=>{if(recoveryBackup&&recoveryBackup.records[col])VS_recoverMissingBackupRows(col,VS_managedSheet(col),recoveryBackup);const revision=p.getProperty('VS_RECORD_REV_'+col)||'legacy';changes[col]=b.knownRevisions&&b.knownRevisions[col]===revision?{records:{},unchanged:true,collectionRevision:revision,syncProtocol:2}:VS_managedRecordUnlocked({operation:'read',collection:col,syncProtocol:2});});
    if(JSON.stringify(changes).length>20*1024*1024)throw new Error('Delta export exceeds safe limit');return {syncProtocol:2,changes:changes};
  }finally{lock.releaseLock();}
}

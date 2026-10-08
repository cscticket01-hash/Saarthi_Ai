/** Managed Windows storage adapter. Deploy as the SCHOOL account, not developer.
 * No Firebase project/key/password required. Run VS_setupManagedSchool once.
 * Existing legacy sheets/files remain untouched; do not rebind existing roots.
 */
// Operator configuration: set only for a NEW school deployment.
// Existing deployments keep their stored School ID, root and secret.
const VS_SETUP_SCHOOL_ID = '';
const VS_SETUP_CREATE_NEW_STORAGE = false;

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
function VS_managedCollection(name) {
  if (!['students_directory','teachers_directory','attendance_logs','teacher_attendance','attendance_records','teacher_schedules','school_notices','school_calendar','exam_results','teacher_salary','school_config','school_settings','fee_settings','fee_ledger','fee_payments','school_expenses','student_scan_index','scanner_devices','documents','backups','exams','exam_center_results','mobile_sessions','mobile_users','mobile_complaints'].includes(name)) throw new Error('Unknown collection');
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
function VS_managedSheet(collection) {
  const legacy=VS_managedCollection(collection),p=PropertiesService.getScriptProperties();
  const school=p.getProperty('VS_MANAGED_SCHOOL_ID');let id=p.getProperty('VS_MANAGED_SHEET_ID'),book;
  const pending=p.getProperty('VS_MANAGED_SHEET_PENDING');
  if(!id&&pending){const file=DriveApp.getFileById(pending);if(file.getDescription()!=='VIDYA_SCHOOL_DATA:'+school)throw new Error('Pending workbook identity mismatch');file.moveTo(VS_managedFolder(VS_managedRoot(),'School Data'));p.setProperty('VS_MANAGED_SHEET_ID',pending);p.deleteProperty('VS_MANAGED_SHEET_PENDING');id=pending;}
  if(id){const file=VS_managedFile(id);if(file.getDescription()!=='VIDYA_SCHOOL_DATA:'+school)throw new Error('School workbook identity mismatch');book=SpreadsheetApp.openById(id);}
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
  const text=JSON.stringify({id:item.id,schoolId:item.schoolId,data:item.data});
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
  const last=store.sheet.getLastRow(),records={};let bytes=0;
  if(last<2)return records;
  const rows=store.sheet.getRange(2,1,last-1,33).getValues();
  rows.forEach(values=>{if(!values[0])return;bytes+=values.slice(6).join('').length;if(bytes>20*1024*1024)throw new Error('Collection export exceeds safe limit');const item=VS_sheetDecode(store,values);if(records[item.id])throw new Error('Duplicate Sheet record');records[item.id]=item.data;});
  return records;
}
// Delete only the immutable upload belonging to this exact document revision.
// Unkeyed legacy or shared files are retained; no broad Drive delete is possible.
function VS_managedDeletedFile(store,id,data) {
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
function VS_managedRecord(b) {
  const lock=LockService.getScriptLock();lock.waitLock(30000);
  try{return VS_managedRecordUnlocked(b);}finally{lock.releaseLock();}
}
function VS_managedRecordUnlocked(b) {
  const store=VS_managedSheet(b.collection), school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID');
  if(b.operation==='read') {
    const revision=PropertiesService.getScriptProperties().getProperty('VS_RECORD_REV_'+b.collection)||'legacy';
    if(b.syncProtocol===2 && b.knownRevision===revision)return {records:{},unchanged:true,collectionRevision:revision,syncProtocol:2};
    const all=VS_sheetRecords(store),records={};Object.keys(all).forEach(id=>{if(b.syncProtocol===2||!all[id]._syncDeleted)records[id]=all[id];});
    return {records:records,collectionRevision:revision,syncProtocol:2};
  }
  if(!/^[^/]{1,200}$/.test(b.id||'')||b.id==='.'||b.id==='..')throw new Error('Invalid record ID');
  const existing=VS_sheetItem(store,b.id),file=existing;
  if(existing&&b.createOnly===true)return {skipped:true};
  if(existing&&(existing.schoolId!==school||existing.id!==b.id))throw new Error('Foreign school record');
  if(b.syncProtocol!==2 && existing&&existing.data._syncOperationId)throw new Error('Record revision conflict');
  if(b.syncProtocol===2){
    if(!/^[A-Za-z0-9_-]{16,100}$/.test(b.operationId||'')||typeof b.expectedRecordRevision!=='string')throw new Error('Invalid sync operation');
    if(existing&&existing.data._syncOperationId===b.operationId)return {recordRevision:existing.data._syncRevision,syncProtocol:2,fileCleanup:existing.data._syncDeleted?VS_managedDeletedFile(store,b.id,existing.data):undefined};
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
    if(existing&&existing.data._syncDeleted)return {recordRevision:existing.data._syncRevision,syncProtocol:2,fileCleanup:VS_managedDeletedFile(store,b.id,existing.data)};
    {
      const revision=Utilities.getUuid(),data={schoolId:school,_syncDeleted:true,_syncRevision:revision};
      if(b.syncProtocol===2)data._syncOperationId=b.operationId;
      if(b.collection==='documents' && existing){data.documentRevision=existing.data.documentRevision||'';const fileId=existing.data._syncDeletedFileId||existing.data.fileId;if(fileId)data._syncDeletedFileId=fileId;}
      PropertiesService.getScriptProperties().setProperty('VS_RECORD_REV_'+b.collection,Utilities.getUuid());
      VS_sheetPut(store,{id:b.id,schoolId:school,data:data});
      return {recordRevision:revision,syncProtocol:2,fileCleanup:VS_managedDeletedFile(store,b.id,data)};
    }

  }
  if(b.operation!=='write'||!b.data||b.data.schoolId!==school)throw new Error('Invalid school record');
  const revision=Utilities.getUuid(),data=Object.assign({},b.data);
  delete data._syncDeleted;delete data._syncOperationId;delete data._syncRevision;
  data._syncRevision=revision;
  if(b.syncProtocol===2)data._syncOperationId=b.operationId;
  delete data._syncDeletedFileId;delete data._syncFileCleanupComplete;
  const text=JSON.stringify({id:b.id,schoolId:school,data:data});if(text.length>512*1024)throw new Error('Record too large; upload files separately');
  PropertiesService.getScriptProperties().setProperty('VS_RECORD_REV_'+b.collection,Utilities.getUuid());VS_sheetPut(store,{id:b.id,schoolId:school,data:data});return {recordRevision:revision,syncProtocol:2};
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
  const school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID');
  let verified=false;
  try {
    const request=JSON.parse(e.postData.contents);
    if(request.action==='managed_connect')return VS_managedConnect(request);
    const b=VS_managedVerify(e);verified=true;let result;
    if(b.action==='managed_health'){VS_managedRoot();result={storageReady:true,documentVersions:1,recordSyncVersion:2,recordStorageVersion:1,scriptBundleVersion:'2026-10-07.1',googleEmail:''};}
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
        const root=VS_managedRoot(),target=VS_managedFolder(VS_managedFolder(root,'Files'),b.mime.indexOf('image/')===0?'Photos':'Documents');let file=null,marker='';
        if(b.uploadKey!==undefined) {
          if(!/^[A-Za-z0-9_-]{1,150}$/.test(b.uploadKey))throw new Error('Invalid upload key');
          const digest=Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,bytes).map(v=>('0'+((v+256)%256).toString(16)).slice(-2)).join('');
          marker='VIDYA_UPLOAD:'+school+':'+b.uploadKey+':'+digest;
          for(const source of [target,root]){const matches=source.getFilesByName(b.name);if(matches.hasNext()){const found=matches.next();if(matches.hasNext()||found.getDescription()!==marker||(file&&file.getId()!==found.getId()))throw new Error('Upload key collision; existing file retained');file=found;}}
        }
        if(!file){file=target.createFile(Utilities.newBlob(bytes,b.mime,b.name));if(marker)file.setDescription(marker);}
        result={fileId:file.getId(),fileUrl:'https://drive.google.com/file/d/'+file.getId()+'/view'};
      } finally {lock.releaseLock();}

    }else if(b.action==='managed_file'){
      const blob=VS_managedFile(b.fileId).getBlob();if(blob.getBytes().length>20*1024*1024)throw new Error('File limit exceeded');result={mime:blob.getContentType(),base64:Utilities.base64Encode(blob.getBytes())};
    }else if(b.action==='managed_backup'){
      const root=VS_managedRoot(),folders=root.getFolders(),records={};while(folders.hasNext()){const f=folders.next();if(f.getName().indexOf('records_')===0)records[f.getName().slice(8)]=VS_managedRecord({collection:f.getName().slice(8),operation:'read'}).records;}
      const text=JSON.stringify({schemaVersion:3,schoolId:school,createdAt:new Date().toISOString(),records:records});if(text.length>20*1024*1024)throw new Error('Backup exceeds safe file limit');const file=VS_managedFolder(root,'Backups').createFile('School_Backup_'+Date.now()+'.json',text,'application/json');result={fileId:file.getId(),fileUrl:'https://drive.google.com/file/d/'+file.getId()+'/view'};
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

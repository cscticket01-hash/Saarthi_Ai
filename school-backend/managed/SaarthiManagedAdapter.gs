/** Managed Windows storage adapter. Deploy as the SCHOOL account, not developer.
 * No Firebase project/key/password required. Run VS_setupManagedSchool once.
 * Existing legacy sheets/files remain untouched; do not rebind existing roots.
 */
// Operator configuration: set only for a NEW school deployment.
// Existing deployments keep their stored School ID, root and secret.
const VS_SETUP_SCHOOL_ID = '';
const VS_SETUP_CREATE_NEW_STORAGE = false;
const VS_MANAGED_CENTRAL_DEFAULT = 'https://saarthi-oauth-staging.onrender.com/school-cloud';
// Cleared at every signed request / top-level record batch. Never persisted.
let VS_BACKUP_READ_CACHE = null;

/** Select this no-argument function in the Apps Script editor and Run once.
 * Returns no connection secret. Windows pairs using only the deployed /exec URL.
 */
function VS_prepareSchoolStorage() {
  const p = PropertiesService.getScriptProperties();
  const existing = p.getProperty('VS_MANAGED_SCHOOL_ID');
  const propertySchool = p.getProperty('VS_SETUP_SCHOOL_ID');
  const configured = (propertySchool == null ? VS_SETUP_SCHOOL_ID : propertySchool).trim();
  const schoolId = configured || existing;
  if (!schoolId) throw new Error('Set VS_SETUP_SCHOOL_ID to the School ID from the developer website');
  if (existing && configured && existing !== configured) throw new Error('School rebinding is blocked');
  if (existing && !p.getProperty('VS_MANAGED_ROOT_ID')) throw new Error('Existing school root is missing; developer recovery required');
  const storageConsent = p.getProperty('VS_SETUP_CREATE_NEW_STORAGE');
  if (storageConsent != null && !['true','false'].includes(storageConsent)) throw new Error('Invalid new-storage consent');
  VS_setupManagedSchool(schoolId, {startEmpty: !existing && (storageConsent == null ? VS_SETUP_CREATE_NEW_STORAGE === true : storageConsent === 'true')});
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
  const payload=JSON.parse(b.payload);
  const lock=LockService.getScriptLock();lock.waitLock(payload.action==='managed_delta'&&payload.headOnly===true?1000:30000);
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
// Historical Sheet reader retained for migration and pre-cutover compatibility.
// The default authoritative store is immutable JSON category generations.
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
  else if(id){try{VS_restoreDeletedWorkbook(id,school);book=SpreadsheetApp.openById(id);}catch(error){if(!VS_sheetLifecycleEnabled()||!VS_syncStateSheet(false)||!/not found|No item with the given ID|does not exist/i.test(error.message||''))throw error;const pending=p.getProperty('VS_MANAGED_SHEET_RECOVERY_PENDING');if(pending){const f=DriveApp.getFileById(pending);if(f.getDescription()!=='VIDYA_SCHOOL_DATA:'+school)throw new Error('School workbook identity mismatch');f.moveTo(VS_managedFolder(VS_managedRoot(),'School Data'));VS_managedFile(pending);book=SpreadsheetApp.openById(pending);}else{book=SpreadsheetApp.create('Vidya Saarthi School Data');const f=DriveApp.getFileById(book.getId());f.setDescription('VIDYA_SCHOOL_DATA:'+school);p.setProperty('VS_MANAGED_SHEET_RECOVERY_PENDING',book.getId());f.moveTo(VS_managedFolder(VS_managedRoot(),'School Data'));}p.setProperty('VS_PREVIOUS_MANAGED_SHEET_ID',id);id=book.getId();p.setProperty('VS_MANAGED_SHEET_ID',id);p.deleteProperty('VS_MANAGED_SHEET_RECOVERY_PENDING');}}
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
  if(!sheet&&p.getProperty('VS_SHEET_MIGRATED_'+collection)==='1'&&!VS_sheetLifecycleEnabled())throw new Error('Verified school tab is missing; operator recovery required');
  if(!sheet){sheet=book.insertSheet(collection);if(sheet.getMaxColumns()<33)sheet.insertColumnsAfter(sheet.getMaxColumns(),33-sheet.getMaxColumns());sheet.getRange(1,1,1,33).setValues([['Record Key','School ID','Revision','Deleted','Operation ID','Display Name'].concat(Array.from({length:27},(_,n)=>'Data '+(n+1)))]);sheet.setFrozenRows(1);}
  const store={sheet:sheet,school:school,collection:collection};
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
function VS_refreshStudentReadable(store,item,row) {
  if(store.json)return;
  if(store.collection!=='students_directory')return;
  const p=PropertiesService.getScriptProperties();
  try{if(item)VS_studentReadable(store,item,row);else {const remaining=VS_studentReadableBackfill(store);
      p.setProperty('VS_STUDENT_READABLE_STATUS',remaining?'backfill pending: '+remaining+' rows':'available');return;}
    p.setProperty('VS_STUDENT_READABLE_STATUS','row updated; full projection not yet measured');
  }catch(_){
    // A derived display failure must never change canonical ACK/record ownership.
    p.setProperty('VS_STUDENT_READABLE_STATUS','blocked: readable columns require owner review; canonical records retained');
    if(item){const key='VS_STUDENT_VIEW_ROW_'+store.sheet.getName()+':'+(store.bookId||'legacy');p.setProperty(key,String(Math.min(row,Math.max(2,Number(p.getProperty(key)||2)))));}
  }
}
function VS_studentReadableBackfill(store) {
  if(store.collection!=='students_directory')return;
  const p=PropertiesService.getScriptProperties();let remaining=0;
  (store.partitions||[store]).forEach(part=>{
    const key='VS_STUDENT_VIEW_ROW_'+part.sheet.getName()+':'+(part.bookId||'legacy');
    const last=part.sheet.getLastRow(),start=Math.max(2,Number(p.getProperty(key)||2));
    const end=Math.min(last,start+99);
    if(last>=2)VS_studentReadableHeader(part.sheet);
    if(start<=end){
      const rows=part.sheet.getRange(start,1,end-start+1,33).getValues();
      const previous=part.sheet.getRange(start,34,rows.length,14).getValues();
      const values=rows.map((v,n)=>v[0]?VS_studentReadableValues(VS_sheetDecode(part,v)):previous[n]);
      part.sheet.getRange(start,34,values.length,14).setValues(values);SpreadsheetApp.flush();
      VS_verifyStudentReadable(values,part.sheet.getRange(start,34,values.length,14).getValues());
    }
    p.setProperty(key,String(end+1));remaining+=Math.max(0,last-end);
    if(end>=last&&last>=2&&part.sheet.hideColumns)part.sheet.hideColumns(1,33);
  });return remaining;
}
function VS_sheetItem(store,id) {
  if(store.json){const records=VS_jsonRead(store).records;return Object.prototype.hasOwnProperty.call(records,id)?{id:id,schoolId:store.school,data:records[id]}:null;}
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
// Readable fields are derived from the same verified authoritative JSON row.
// They never feed edits back into Sync or create a second school database.
const VS_STUDENT_VIEW_HEADERS=['Name','Parent Name','Class','Roll No','Contact','Photo URL','Hostel Facility','Address','District','State','PIN Code','Joining Date','Date of Birth','Timestamp'];
function VS_studentReadableHeader(sheet) {
  const start=34,width=VS_STUDENT_VIEW_HEADERS.length;
  if(sheet.getMaxColumns()<start+width-1)sheet.insertColumnsAfter(sheet.getMaxColumns(),start+width-1-sheet.getMaxColumns());
  const headers=sheet.getRange(1,start,1,width).getValues()[0];
  if(headers.some((v,n)=>v!==''&&v!==VS_STUDENT_VIEW_HEADERS[n]))throw new Error('Student readable columns contain owner data; review required');
  if(headers.some(v=>v===''))sheet.getRange(1,start,1,width).setValues([VS_STUDENT_VIEW_HEADERS]);
}
function VS_studentReadableValues(item) {
  const d=item.data,field=(...keys)=>{for(const key of keys)if(d[key]!==undefined&&d[key]!==null)return d[key];return '';};
  const raw=item.layoutRedirect||d._syncDeleted?Array(14).fill(''):[field('name','studentName'),field('parentName','fatherName'),field('class','studentClass'),field('rollNo','roll'),field('parentContact','contact','contactNo','mobile'),field('photoUrl','photoURL'),field('hostelFacility','hostel'),field('address'),field('district'),field('state'),field('pinCode','pincode'),field('joiningDate'),field('dateOfBirth','dob'),field('timestamp','createdAt')];
  return raw.map(v=>{const text=v&&typeof v==='object'&&typeof v.__vsTimestamp==='string'?v.__vsTimestamp:typeof v==='object'?JSON.stringify(v):String(v);return /^[=+\-@]/.test(text)?"'"+text:text;});
}
function VS_verifyStudentReadable(expected,actual) {
  if(actual.some((row,n)=>row.some((v,k)=>String(v)!==expected[n][k]&&String(v)!==expected[n][k].replace(/^'/,''))))throw new Error('Student readable projection verification failed');
}
function VS_studentReadable(store,item,row) {
  if(store.collection!=='students_directory')return;
  VS_studentReadableHeader(store.sheet);
  const values=[VS_studentReadableValues(item)];
  store.sheet.getRange(row,34,1,14).setValues(values);SpreadsheetApp.flush();
  VS_verifyStudentReadable(values,store.sheet.getRange(row,34,1,14).getValues());
  const p=PropertiesService.getScriptProperties(),key='VS_STUDENT_VIEW_ROW_'+store.sheet.getName()+':'+(store.bookId||'legacy');
  const cursor=Math.max(2,Number(p.getProperty(key)||2));
  if(cursor>=row){p.setProperty(key,String(Math.max(cursor,row+1)));if(cursor>=store.sheet.getLastRow()&&store.sheet.hideColumns)store.sheet.hideColumns(1,33);}
}
function VS_sheetPut(store,item) {
  if(store.json)return VS_jsonPut(store,item);
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
  VS_saveRecordHead(store,saved);
  VS_recordJsonBackup(store,saved);
  VS_refreshStudentReadable(store,item,row);
  VS_refreshRecordReadable(store,item,row);
}
function VS_sheetRecords(store) {
  if(store.json)return VS_jsonRead(store).records;
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
      if(snap.collection==='students_directory')VS_studentUnique(store,snap.id,restored,current);
      restored._syncRevision=Utilities.getUuid();restored._syncUpdatedAt=Date.now();restored._syncRecycleRestoreId=b.operationId;restored._syncRecycleSource=b.fileId;restored._syncRecycleRestoreRevision=b.expectedRecordRevision;
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
/** One separately bound Import workbook; never reads internal managed tabs. */
function VS_importSheet(b) {
  const lock=LockService.getScriptLock();lock.waitLock(30000);
  try {
    const p=PropertiesService.getScriptProperties(),school=p.getProperty('VS_MANAGED_SCHOOL_ID'),root=VS_managedRoot();
    const marker='VIDYA_STUDENT_IMPORT:v1:'+school,headers=['schoolId','studentId','name','class','section','rollNo','expectedRevision'];
    let id=p.getProperty('VS_STUDENT_IMPORT_SHEET_ID')||p.getProperty('VS_STUDENT_IMPORT_SHEET_PENDING');
    if(!id){
      if(b.action!=='managed_import_sheet_setup'||b.confirmCreate!==true)throw new Error('Explicit import Sheet creation confirmation required');
      const book=SpreadsheetApp.create('Vidya Saarthi Student Import '+school);id=book.getId();
      p.setProperty('VS_STUDENT_IMPORT_SHEET_PENDING',id);
      const file=DriveApp.getFileById(id);file.setDescription(marker);file.moveTo(root);
      const tab=book.insertSheet('Student Import v1');tab.getRange(1,1,1,7).setValues([headers]);tab.setFrozenRows(1);SpreadsheetApp.flush();
    }
    const file=DriveApp.getFileById(id),parents=file.getParents();
    if(file.getDescription()!==marker||!parents.hasNext()||parents.next().getId()!==root.getId()||parents.hasNext()||file.isTrashed())throw new Error('Import Sheet school binding requires review');
    const book=SpreadsheetApp.openById(id),tab=book.getSheetByName('Student Import v1');
    if(!tab||JSON.stringify(tab.getRange(1,1,1,7).getValues()[0])!==JSON.stringify(headers))throw new Error('Import Sheet header/version requires review');
    p.setProperty('VS_STUDENT_IMPORT_SHEET_ID',id);p.deleteProperty('VS_STUDENT_IMPORT_SHEET_PENDING');
    const last=tab.getLastRow();if(last>101)throw new Error('Import Sheet exceeds 100 row admission bound');
    const values=last>1?tab.getRange(2,1,last-1,7).getValues():[];
    const raw=values.map(row=>row.map(v=>typeof v==='string'?v:(typeof v==='number'&&Number.isFinite(v)?String(v):v===null?'':String(v))));
    const rows=raw.filter(row=>row.some(v=>v!=='')).map(row=>{const r={};headers.forEach((h,i)=>r[h]=row[i]);r.expectedRevision=r.expectedRevision===''?null:r.expectedRevision;return r;});
    return {sheetId:id,sheetUrl:'https://docs.google.com/spreadsheets/d/'+id+'/edit',headerVersion:1,maxRows:100,source:'designated-sheet',rows:rows,fingerprint:VS_layoutHash({schoolId:school,sheetId:id,headerVersion:1,headers:headers,raw:raw})};
  }finally{lock.releaseLock();}
}
function VS_studentSlot(data) {
  if(!data||data._syncDeleted)return null;
  const cls=data.studentClass===undefined?data.class:data.studentClass,section=data.section===undefined?'':data.section,roll=data.rollNo;
  if(typeof cls!=='string'||!cls.trim()||typeof section!=='string'||!(typeof roll==='string'||typeof roll==='number')||typeof roll==='number'&&(!Number.isSafeInteger(roll)||roll<0)||!String(roll).trim())return null;
  return JSON.stringify([cls.trim(),section.trim(),String(roll).trim()]);
}
/** Called while existing school ScriptLock is held, including normal app writes.
 * Legacy unmeasured slots are reported; never rewrite them merely for import.
 */
function VS_studentUnique(store,id,data,existing) {
  const slot=VS_studentSlot(data),oldSlot=existing?VS_studentSlot(existing.data):null,all=VS_sheetRecords(store);let partial=slot===null;
  Object.keys(all).forEach(other=>{
    if(all[other]._syncDeleted)return;
    const otherSlot=VS_studentSlot(all[other]);if(otherSlot===null)partial=true;
    if(other!==id&&slot!==null&&otherSlot===slot){
      if(slot!==oldSlot)throw new Error('Student class/section/roll conflict');
      partial=true; // Preserve unrelated updates to already duplicated legacy slots.
    }
  });
  return partial?'partial-legacy':'measured-active-slots';
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
function VS_managedRecordUnlocked(b,readContext) {
  if(b.operation==='read'&&b.knownRecordRevisions!==undefined)return VS_managedIncrementalRecords(b,readContext);
  const store=VS_managedSheet(b.collection,readContext), school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID');
  if(b.operation==='read') {
    VS_recoverMissingBackupRows(b.collection,store);
    VS_refreshStudentReadable(store);
    VS_refreshRecordReadable(store);
    const revision=PropertiesService.getScriptProperties().getProperty('VS_RECORD_REV_'+b.collection)||'legacy';
    const all=VS_sheetRecords(store);VS_seedRecordHeads(store,all,readContext);const missingRecords=VS_missingRecordHeads(store,all,readContext),records=Object.create(null);
    missingRecords.filter(h=>h.deleted).forEach(h=>{all[h.id]={schoolId:school,_syncDeleted:true,_syncRevision:h.revision,...(h.generation?{_syncDeletedOwner:h.generation}:{}),_syncRetiredStudentGenerations:h.retiredGenerations||[]};});
    if(b.syncProtocol===2 && b.knownRevision===revision&&!missingRecords.length)return {records:{},unchanged:true,collectionRevision:revision,syncProtocol:2};Object.keys(all).forEach(id=>{if(b.syncProtocol===2||!all[id]._syncDeleted)records[id]=all[id];});
    return {records:records,collectionRevision:revision,syncProtocol:2,...(missingRecords.some(h=>!h.deleted)?{missingRecords:missingRecords.filter(h=>!h.deleted)}:{})};
  }
  if(!/^[^/]{1,200}$/.test(b.id||'')||b.id==='.'||b.id==='..')throw new Error('Invalid record ID');
  if(b.operation==='recover')return VS_recoverSheetRecord(b,store);
  let existing=VS_sheetItem(store,b.id);
  const retained=VS_sheetLifecycleEnabled()?VS_recordHead(b.collection,b.id):null;
  if(!existing&&retained){const h=retained.head;existing={id:b.id,schoolId:school,data:{schoolId:school,_syncRevision:h.revision,_syncOperationId:h.operationId,_syncRequestHash:h.requestHash,...(h.deleted?{_syncDeleted:true,_syncDeletedOwner:h.generation,_syncRetiredStudentGenerations:h.retiredGenerations||[]}:{})}};
    if(!h.deleted)throw new Error('Verified local Sheet recovery required before editing');}
  const file=existing;
  if(existing&&b.createOnly===true){VS_recordJsonBackup(store,existing);return {skipped:true};}
  if(existing&&(existing.schoolId!==school||existing.id!==b.id))throw new Error('Foreign school record');
  if(b.operation==='write' && b.collection==='school_config' && b.id==='school_profile_cache') {
    const core=['schoolName','principalName','schoolContactNo'];
    const empty=v=>v===undefined||v===null||String(v).trim()==='';
    if(core.every(k=>empty((b.data||{})[k])))throw new Error('Blank school profile blocked');
    if(existing && core.some(k=>!empty(existing.data[k])&&empty((b.data||{})[k])))
      throw new Error('Empty school profile overwrite blocked');
  }
  // A lost response may replay an already committed legacy document write.
  // Only identical, live, same-school content is a receipt; never rebase a stale edit.
  if(b.collection==='documents' && b.operation==='write' && b.syncProtocol!==2 &&
      existing && !existing.data._syncOperationId && !existing.data._syncDeleted &&
      b.data && b.data.schoolId===school && typeof b.data.documentRevision==='string' &&
      b.data.documentRevision.length>0 && b.data.documentRevision===existing.data.documentRevision &&
      VS_layoutHash(VS_syncRequestShape(b))===VS_layoutHash(VS_syncRequestShape({operation:'write',data:existing.data}))) {
    VS_saveRecordHead(store,existing);if(existing.row){VS_refreshStudentReadable(store,existing,existing.row);VS_refreshRecordReadable(store,existing,existing.row);}VS_recordJsonBackup(store,existing);return {recordRevision:existing.data._syncRevision,syncProtocol:2};
  }
  if(b.syncProtocol!==2 && existing&&existing.data._syncOperationId)throw new Error('Record revision conflict');
  if(b.syncProtocol===2){
    if(!/^[A-Za-z0-9_-]{16,100}$/.test(b.operationId||'')||typeof b.expectedRecordRevision!=='string')throw new Error('Invalid sync operation');
    if(existing&&existing.data._syncOperationId===b.operationId){
      const digest=VS_layoutHash(VS_syncRequestShape(b));
      const original=existing.data._syncRequestHash||VS_layoutHash(VS_syncRequestShape({operation:existing.data._syncDeleted?'delete':'write',data:existing.data}));
      if(digest!==original)throw new Error('Sync operation ID conflict');
      VS_saveRecordHead(store,existing);if(existing.row){VS_refreshStudentReadable(store,existing,existing.row);VS_refreshRecordReadable(store,existing,existing.row);}VS_recordJsonBackup(store,existing);return {recordRevision:existing.data._syncRevision,syncProtocol:2,fileCleanup:existing.data._syncDeleted?VS_managedDeletedFile(store,b.id,existing.data):undefined};
    }
    const replacement=VS_sheetLifecycleEnabled()&&b.collection==='students_directory'&&b.operation==='write'&&existing&&b.data&&/^p-[a-f0-9]{32,64}$/.test(b.data.mobileStableId||'')&&b.data.mobileStableId!==b.data.replacesStudentGeneration&&b.data.replacesStudentGeneration===(existing.data._syncDeleted?existing.data._syncDeletedOwner:VS_studentGeneration(existing.data,b.id));
    const childReplacement=VS_reusableStudentChild(b,existing);
    const sameDeletion=VS_sheetLifecycleEnabled()&&b.collection==='students_directory'&&b.operation==='delete'&&existing&&typeof b.deletedStudentGeneration==='string'&&b.deletedStudentGeneration===(existing.data._syncDeleted?existing.data._syncDeletedOwner:VS_studentGeneration(existing.data,b.id));
    // Independent devices may delete the same record from an older revision.
    // The authoritative tombstone already fulfils that intent. Never rebase a
    // stale delete onto a live (possibly restored/new-generation) record.
    const alreadyDeleted=b.operation==='delete'&&existing&&existing.data._syncDeleted===true;
    if((existing&&existing.data._syncRevision||'')!==b.expectedRecordRevision&&!replacement&&!sameDeletion&&!childReplacement&&!alreadyDeleted)throw new Error('Record revision conflict');
    if(replacement&&!existing.data._syncDeleted){VS_deleteStudentOwnedRecords(b.id,existing.data,b.operationId,b.data);}
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
  if(b.operation==='write' && existing && existing.data._syncDeleted && !VS_reusableStudentChild(b,existing) && !(b.syncProtocol===2&&b.expectedRecordRevision===existing.data._syncRevision&&b.data&&(b.data._syncRecreatesDeletedRevision===existing.data._syncRevision||b.data._syncRecreatesDeletedOperationId&&b.data._syncRecreatesDeletedOperationId===existing.data._syncOperationId)&&b.collection!=='students_directory') && !(VS_sheetLifecycleEnabled()&&b.collection==='students_directory'&&b.syncProtocol===2&&/^p-[a-f0-9]{32,64}$/.test(b.data&&b.data.mobileStableId||'')&&b.data.mobileStableId!==existing.data._syncDeletedOwner&&(b.expectedRecordRevision===existing.data._syncRevision||b.data.replacesStudentGeneration===existing.data._syncDeletedOwner)))throw new Error('Record revision conflict');
  if(b.operation==='delete'){
    if(VS_recycleEnabled()&&b.syncProtocol!==2)throw new Error('Invalid sync operation');
    if(existing&&existing.data._syncDeleted){VS_saveRecordHead(store,existing);if(existing.row){VS_refreshStudentReadable(store,existing,existing.row);VS_refreshRecordReadable(store,existing,existing.row);}VS_recordJsonBackup(store,existing);return {recordRevision:existing.data._syncRevision,syncProtocol:2,fileCleanup:VS_managedDeletedFile(store,b.id,existing.data)};}
    {
      const revision=Utilities.getUuid(),data={schoolId:school,_syncDeleted:true,_syncRevision:revision};
      if(b.syncProtocol===2){data._syncOperationId=b.operationId;data._syncRequestHash=VS_layoutHash(VS_syncRequestShape(b));}
      if(VS_sheetLifecycleEnabled()&&b.collection==='students_directory'&&existing){VS_deleteStudentOwnedRecords(b.id,existing.data,b.operationId||revision);data._syncDeletedOwner=VS_studentGeneration(existing.data,b.id);data._syncRetiredStudentGenerations=[...new Set([...(existing.data._syncRetiredStudentGenerations||[]),data._syncDeletedOwner])];}
      if(VS_sheetLifecycleEnabled()&&existing&&existing.data.personId)data._syncDeletedOwner=existing.data.personId;
      if(b.collection==='documents' && existing){data.documentRevision=existing.data.documentRevision||'';const fileId=existing.data._syncDeletedFileId||existing.data.fileId;if(fileId)data._syncDeletedFileId=fileId;}
      if(VS_recycleEnabled()&&existing&&!(VS_sheetLifecycleEnabled()&&b.collection==='students_directory')){const saved=VS_recycleSnapshot(b.collection,b.id,existing,revision);data._syncRecycleFileId=saved.fileId;data._syncRecycleUntil=saved.recoverUntil;}
      PropertiesService.getScriptProperties().setProperty('VS_RECORD_REV_'+b.collection,Utilities.getUuid());
      VS_sheetPut(store,{id:b.id,schoolId:school,data:data});
      return {recordRevision:revision,syncProtocol:2,fileCleanup:VS_managedDeletedFile(store,b.id,data)};
    }

  }
  if(b.operation!=='write'||!b.data||b.data.schoolId!==school)throw new Error('Invalid school record');
  if(VS_sheetLifecycleEnabled()&&b.collection==='students_directory'&&existing&&!existing.data._syncDeleted&&existing.data.mobileStableId&&b.data.mobileStableId!==existing.data.mobileStableId&&b.data.replacesStudentGeneration!==existing.data.mobileStableId)throw new Error('Record revision conflict');
  if(VS_sheetLifecycleEnabled()&&b.collection!=='students_directory'&&b.data.personId&&b.data.studentId){
    const parentStore=VS_managedSheet('students_directory'),parent=VS_sheetItem(parentStore,b.data.studentId),head=VS_recordHead('students_directory',b.data.studentId);
    const known=parent?parent.data:head?{_syncDeleted:head.head.deleted,mobileStableId:head.head.generation,_syncDeletedOwner:head.head.generation,_syncRetiredStudentGenerations:head.head.retiredGenerations||[]}:null;
    if(known&&known._syncDeleted){if(b.data.personId===known._syncDeletedOwner||(known._syncRetiredStudentGenerations||[]).indexOf(b.data.personId)>=0)throw new Error('Student generation was deleted; stale child rejected');throw new Error('New student parent must sync first');}
    if(known&&known.mobileStableId&&known.mobileStableId!==b.data.personId)throw new Error('Student generation was deleted; stale child rejected');
  }
  const studentUniquenessScope=b.collection==='students_directory'?VS_studentUnique(store,b.id,b.data,existing):undefined;
  const generation=b.collection!=='students_directory'&&existing&&!existing.data._syncDeleted&&existing.data._syncRecreatesDeletedRevision;
  if(generation&&b.data._syncRecreatesDeletedRevision&&b.data._syncRecreatesDeletedRevision!==generation)throw new Error('Record revision conflict');
  const revision=Utilities.getUuid(),data=Object.assign({},b.data);
  if(generation)data._syncRecreatesDeletedRevision=generation;
  Object.keys(data).filter(k=>k.indexOf('_syncRecycle')===0).forEach(k=>delete data[k]);
  delete data._syncDeleted;delete data._syncOperationId;delete data._syncRevision;
  data._syncRevision=revision;
  if(b.syncProtocol===2){data._syncOperationId=b.operationId;data._syncRequestHash=VS_layoutHash(VS_syncRequestShape(b));}
  if(VS_sheetLifecycleEnabled()&&b.collection==='students_directory'){
    delete data._syncRetiredStudentGenerations;delete data._syncDeletedOwner;
    if(existing){const retired=[...new Set([...(existing.data._syncRetiredStudentGenerations||[]),...(existing.data._syncDeleted?[existing.data._syncDeletedOwner]:b.data.replacesStudentGeneration?[b.data.replacesStudentGeneration]:[])].filter(v=>typeof v==='string'&&v))];if(retired.length)data._syncRetiredStudentGenerations=retired;}
  }
  delete data._syncDeletedFileId;delete data._syncFileCleanupComplete;
  const text=JSON.stringify({id:b.id,schoolId:school,data:data});if(text.length>512*1024)throw new Error('Record too large; upload files separately');
  PropertiesService.getScriptProperties().setProperty('VS_RECORD_REV_'+b.collection,Utilities.getUuid());VS_sheetPut(store,{id:b.id,schoolId:school,data:data});return {recordRevision:revision,syncProtocol:2,studentUniquenessScope:studentUniquenessScope};
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
  Object.keys(backup.records).forEach(col=>{VS_validateManagedCollection(col);Object.keys(backup.records[col]).forEach(id=>{
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
  if(VS_jsonEnabled())throw new Error('JSON storage active; Sheet layout changes require owner review');
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

// Read-only application-media inventory. Archives, native Google files and
// arbitrary root files are intentionally outside this declared scope.
const VS_BINARY_FOLDERS=['Files','Student_Photos','Teacher_Photos','Staff_Photos','Student_Documents','Teacher_Documents','Staff_Documents','ID_Cards','School_Assets','Other_Files'];
const VS_BINARY_MAX_BYTES=20*1024*1024;
function VS_binaryFolderAllowed(folder) {
  const root=VS_managedRoot().getId(),seen={};let visits=0;
  function walk(f) {
    const id=f.getId();if(seen[id]||++visits>250)return false;seen[id]=true;
    if(['Backups','Backup_And_Recovery','records_legacy'].indexOf(f.getName())>=0)return false;
    const parents=f.getParents();while(parents.hasNext()){
      const parent=parents.next();if(parent.getId()===root)return VS_BINARY_FOLDERS.indexOf(f.getName())>=0;
      if(walk(parent))return true;
    }return false;
  }return walk(folder);
}
function VS_binaryFile(id) {
  const file=VS_managedFile(id);if(file.isTrashed()||String(file.getMimeType()).indexOf('application/vnd.google-apps.')===0)throw new Error('Unsupported school binary');
  const parents=file.getParents();while(parents.hasNext())if(VS_binaryFolderAllowed(parents.next()))return file;
  throw new Error('School binary is outside application media');
}
function VS_binaryMetadata(file,includeBytes) {
  const size=file.getSize(),updated=file.getLastUpdated().getTime();
  if(!Number.isSafeInteger(size)||size<1||size>VS_BINARY_MAX_BYTES)throw new Error('File limit exceeded');
  const bytes=file.getBlob().getBytes();if(bytes.length!==size||file.getSize()!==size||file.getLastUpdated().getTime()!==updated)throw new Error('School binary changed during verification');
  const digest=Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,bytes).map(v=>('0'+((v+256)%256).toString(16)).slice(-2)).join('');
  return {fileId:file.getId(),name:file.getName(),mime:file.getMimeType(),sizeBytes:size,sha256:digest,version:String(updated)+'-'+String(size)+'-'+digest,...(includeBytes?{base64:Utilities.base64Encode(bytes)}:{})};
}
function VS_binaryInventory(b) {
  const root=VS_managedRoot(),pending=[],all=[],seen={};let limited=false,visited=0;
  const started=Date.now(),folders=root.getFolders();let rootScanned=0;while(folders.hasNext()) {if(++rootScanned>250||Date.now()-started>6000){limited=true;break;}const f=folders.next();if(VS_BINARY_FOLDERS.indexOf(f.getName())>=0)pending.push(f);if(pending.length>250){limited=true;break;}}
  while(pending.length) {
    if(++visited>250||all.length>=1000||Date.now()-started>6000){limited=true;break;}
    const folder=pending.shift();if(seen[folder.getId()]){limited=true;continue;}seen[folder.getId()]=true;
    if(!VS_binaryFolderAllowed(folder))continue;
    const children=folder.getFolders();while(children.hasNext()){if(pending.length+visited>=250){limited=true;break;}pending.push(children.next());}
    const files=folder.getFiles();while(files.hasNext()) {if(all.length>=1000||Date.now()-started>6000){limited=true;break;}const file=files.next();
      if(!file.isTrashed()&&String(file.getMimeType()).indexOf('application/vnd.google-apps.')!==0)all.push(file);
    }
  }
  const unique=all.filter((file,index)=>all.findIndex(other=>other.getId()===file.getId())===index);
  unique.sort((a,c)=>a.getId()<c.getId()?-1:a.getId()>c.getId()?1:0);
  const inventoryManifest=unique.map(f=>({id:f.getId(),size:f.getSize(),updated:f.getLastUpdated().getTime()})),inventoryFingerprint=VS_layoutHash(inventoryManifest);
  const candidates=unique.filter(f=>!b.cursor||f.getId()>b.cursor),items=[];let bytes=0,cursor=b.cursor||'',unverified=false;
  for(const file of candidates) {
    if(items.length>=5)break;const size=file.getSize();if(size>VS_BINARY_MAX_BYTES||size<1){items.push({fileId:file.getId(),name:file.getName(),mime:file.getMimeType(),sizeBytes:size,verification:'unavailable',reason:'size_limit'});unverified=true;cursor=file.getId();continue;}
    if(bytes+size>VS_BINARY_MAX_BYTES)break;
    const verified=VS_binaryMetadata(VS_binaryFile(file.getId()),false),captured=inventoryManifest.find(entry=>entry.id===file.getId());
    if(verified.sizeBytes!==captured.size||verified.version.indexOf(String(captured.updated)+'-'+String(captured.size)+'-')!==0)throw new Error('School binary changed during verification');
    items.push({...verified,verification:'bytes_hashed'});bytes+=size;cursor=file.getId();
  }
  const more=candidates.some(f=>f.getId()>cursor);
  return {binaryInventoryVersion:1,inventoryFingerprint:inventoryFingerprint,inventoryScope:'application_media_folders',observedAt:Date.now(),items:items,nextCursor:more?cursor:null,partial:limited||more||unverified,scanLimited:limited,coverageComplete:!limited&&!more&&!unverified,hashedBytes:bytes};
}
function VS_binaryDownload(b) {
  const item=VS_binaryMetadata(VS_binaryFile(b.fileId),true);
  if(item.sha256!==b.expectedSha256||item.version!==b.expectedVersion)throw new Error('School binary version changed; refresh inventory');
  return {...item,binaryDownloadVersion:1,verification:'bytes_hashed'};
}
function VS_managedCentralEndpoint(school) {
  const configured = PropertiesService.getScriptProperties().getProperty('VS_MANAGED_CENTRAL_ENDPOINT');
  const endpoint = configured == null ? VS_MANAGED_CENTRAL_DEFAULT : configured;
  const production = 'https://saarthi-oauth-staging.onrender.com/school-cloud';
  const isolated = 'https://saarthi-sync-v2-test.onrender.com/school-cloud';
  if (endpoint !== production && endpoint !== isolated) throw new Error('Untrusted central endpoint');
  if (endpoint === isolated && school !== 'vs-db8afb01a3be46a983c8284714d06e5d') throw new Error('TEST endpoint requires isolated TEST school');
  return endpoint;
}
function VS_managedConnect(b) {
  const p=PropertiesService.getScriptProperties(),school=p.getProperty('VS_MANAGED_SCHOOL_ID');
  if(!school||b.schoolId!==school||!/^[a-f0-9]{64}$/.test(b.ticket||''))throw new Error('School storage connection rejected');
  VS_managedRoot();
  // Fixed trusted broker. Never accept a caller-supplied URL or Firebase token.
  const response=UrlFetchApp.fetch(VS_managedCentralEndpoint(school),{method:'post',contentType:'application/json',payload:JSON.stringify({action:'managed/storage/authorize',schoolId:school,ticket:b.ticket}),muteHttpExceptions:true,followRedirects:false});
  const authorization=JSON.parse(response.getContentText());
  if(response.getResponseCode()!==200||authorization.success!==true||authorization.schoolId!==school)throw new Error('Connection ticket rejected');
  const secret=p.getProperty('VS_MANAGED_SECRET');if(!/^[a-f0-9]{64}$/.test(secret||''))throw new Error('Managed storage not prepared');
  return jsonResponse({success:true,schoolId:school,storageReady:true,connectionSecret:secret});
}
// Fixed diagnostic categories only. Never return/log exception text, stack or record contents.
function VS_managedDiagnostic(error) {
  const message=String(error && error.message || '');
  const known={
    'JSON category identity mismatch':'SCRIPT_JSON_IDENTITY_MISMATCH',
    'JSON readback verification failed':'SCRIPT_JSON_READBACK_FAILED',
    'JSON head missing; operator review required':'SCRIPT_JSON_HEAD_MISSING',
    'JSON category exceeds safe limit':'SCRIPT_JSON_CAPACITY_REVIEW',
    'New student parent must sync first':'SCRIPT_STUDENT_PARENT_PENDING',
    'Verified local Sheet recovery required before editing':'SCRIPT_SHEET_RECOVERY_REQUIRED',
    'Recovery revision or content mismatch':'SCRIPT_RECOVERY_MISMATCH',
    'Sync state identity mismatch':'SCRIPT_SYNC_STATE_IDENTITY',
    'Sync state unavailable; recovery requires review':'SCRIPT_SYNC_STATE_UNAVAILABLE',
    'Student generation was deleted; stale child rejected':'SCRIPT_STUDENT_GENERATION_DELETED',
    'JSON head changed; retry Sync':'SCRIPT_JSON_HEAD_CONFLICT',
    'JSON cutover exists; stale Sheet routing blocked':'SCRIPT_JSON_STALE_SHEET_BLOCKED',
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
    'Blank school profile blocked':'SCRIPT_BLANK_SCHOOL_PROFILE',
    'Empty school profile overwrite blocked':'SCRIPT_EMPTY_PROFILE_OVERWRITE',
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

/** Account-wide quota requires explicit owner consent; not school file usage. */
function VS_managedStorageQuota(b) {
 const p=PropertiesService.getScriptProperties(),school=p.getProperty('VS_MANAGED_SCHOOL_ID');
 if(!b||b.schoolId!==school)throw new Error('Foreign school record');
 VS_managedRoot();
 if(p.getProperty('VS_ALLOW_DRIVE_QUOTA_REPORTING')!=='true')return {success:true,schoolId:school,driveQuotaVersion:1,status:'Unknown',reason:'School owner has not enabled Google account quota reporting'};
 try {
  const usage=DriveApp.getStorageUsed(),limit=DriveApp.getStorageLimit();
  if(!Number.isSafeInteger(usage)||usage<0||!Number.isSafeInteger(limit))throw new Error('Invalid quota');
  return {success:true,schoolId:school,driveQuotaVersion:1,status:'Measured',usage:usage,limit:limit<0?null:limit,scope:'Google account storage; separate from school application files',measuredAt:Date.now(),reason:limit<0?'Google reports no storage limit for this account':null};
 }catch(_){return {success:true,schoolId:school,driveQuotaVersion:1,status:'Unknown',reason:'Authorized Google storage quota read unavailable; no additional permission requested'};}
}

/** Read-only record census. No sheet/folder creation, migration or recovery writes. */
function VS_managedBackupSnapshot(b) {
 const p=PropertiesService.getScriptProperties(),school=p.getProperty('VS_MANAGED_SCHOOL_ID');
 if(!b||b.schoolId!==school)throw new Error('Foreign school record');
 const root=VS_managedRoot(),collections=VS_LAYOUT_COLLECTIONS.filter(c=>['mobile_sessions','mobile_users','mobile_complaints'].indexOf(c)<0);
 const records={},heads={},missing=[],initial=p.getProperties();let bytes=0;
 if(initial.VS_MANAGED_SHEET_PENDING)missing.push({collection:'school workbook',reason:'Pending workbook identity requires owner review'});
 collections.forEach(col=>{
  const lock=LockService.getScriptLock();lock.waitLock(5000);
  try {
   const state=VS_layoutState(col);let values=Object.create(null);
   if(VS_collectionUsesJson(col)&&p.getProperty('VS_JSON_CUTOVER_'+col)==='1'&&!p.getProperty('VS_JSON_HEAD_'+col))throw new Error('JSON head missing; operator review required');
   if(VS_collectionUsesJson(col)&&p.getProperty('VS_JSON_HEAD_'+col))values=VS_jsonRead({json:true,school:school,collection:col}).records;
   else if(state&&['active','rollingBack'].indexOf(state.phase)>=0&&p.getProperty('VS_SHEET_CUTOVER_'+col)!=='1')values=VS_sheetRecords(VS_layoutStore(state));
   else {
    const id=p.getProperty('VS_MANAGED_SHEET_ID');
    if(id){const f=VS_managedFile(id);if(f.getDescription()!=='VIDYA_SCHOOL_DATA:'+school)throw new Error('School workbook identity mismatch');const sheet=SpreadsheetApp.openById(id).getSheetByName(col);if(sheet)values=VS_sheetRecords({sheet:sheet,school:school});else if(p.getProperty('VS_SHEET_MIGRATED_'+col)==='1')missing.push({collection:col,reason:'Verified school tab missing'});}
    if(p.getProperty('VS_SHEET_MIGRATED_'+col)!=='1'){
     const folders=root.getFoldersByName('records_'+col);
     if(folders.hasNext()){
      const folder=folders.next();if(folders.hasNext())throw new Error('Duplicate collection folders; operator review required');
      const files=folder.getFiles();
      while(files.hasNext()){
       const raw=files.next().getBlob().getDataAsString();bytes+=raw.length*4;if(bytes>20*1024*1024)throw new Error('Backup exceeds verification limit');
       const item=JSON.parse(raw);if(!item||item.schoolId!==school||typeof item.id!=='string'||!item.data||item.data.schoolId!==school)throw new Error('Foreign school record');
       if(values[item.id]&&JSON.stringify(values[item.id])!==JSON.stringify(item.data))throw new Error('Migration conflict; both versions retained');
       values[item.id]=item.data;
      }
     }
    }
    if(state)missing.push({collection:col,reason:'Organized layout migration is not active; partial census'});
   }
   Object.keys(values).forEach(id=>{if(values[id].schoolId!==school)throw new Error('Foreign school record');});
   bytes+=JSON.stringify(values).length*4;if(bytes>20*1024*1024)throw new Error('Backup exceeds verification limit');
   records[col]=values;heads[col]=p.getProperty('VS_RECORD_REV_'+col)||'legacy';
  }finally{lock.releaseLock();}
 });
 const check=LockService.getScriptLock();check.waitLock(5000);
 try {const current=p.getProperties();if(collections.some(col=>initial['VS_JSON_HEAD_'+col]!==current['VS_JSON_HEAD_'+col]||(initial['VS_RECORD_REV_'+col]||'legacy')!==heads[col]||heads[col]!== (current['VS_RECORD_REV_'+col]||'legacy')||initial['VS_LAYOUT_'+col]!==current['VS_LAYOUT_'+col]))throw new Error('Backup changed during capture; retry snapshot');}finally{check.releaseLock();}
 return {success:true,schoolId:school,snapshotProtocol:1,collections:collections,records:records,collectionRevisions:heads,missingData:missing,recordsComplete:missing.length===0,documentBinariesIncluded:false,createdAt:Date.now()};
}

function VS_managedHandle(e) {
  VS_BACKUP_READ_CACHE=null;
  const school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID');
  let verified=false;
  try {
    const request=JSON.parse(e.postData.contents);
    if(request.action==='managed_connect')return VS_managedConnect(request);
    const b=VS_managedVerify(e);verified=true;let result;
    if(b.action==='managed_backup_snapshot'){
      result=VS_managedBackupSnapshot(b);
    }else if(b.action==='managed_storage_quota'){
      result=VS_managedStorageQuota(b);
    }else if(b.action==='managed_health'){
      VS_managedRoot();const p=PropertiesService.getScriptProperties();let sheetsVerified=null;
      if(VS_testBackupRecoveryEnabled()&&!VS_jsonEnabled()){
        const properties=p.getProperties(),collection=VS_LAYOUT_COLLECTIONS.find(col=>properties['VS_SHEET_MIGRATED_'+col]==='1');
        if(collection){const store=VS_managedSheet(collection),parts=store.partitions||[store];parts.forEach(part=>{
          if(part.sheet.getRange(1,1,1,1).getValues()[0][0]!=='Record Key')throw new Error('School tab identity requires review');
        });sheetsVerified=true;}
      }
      result={storageReady:true,driveRootVerified:true,sheetsAccessVerified:sheetsVerified,documentVersions:1,recordSyncVersion:2,recordDeltaBatchVersion:1,recordChangeHeadsVersion:1,recordStorageVersion:VS_jsonEnabled()?2:1,recordJsonBackupVersion:VS_sheetLifecycleEnabled()?0:1,jsonSchemaVersion:VS_jsonEnabled()?1:0,organizedStorageVersion:2,managedViewVersion:1,recycleVersion:VS_recycleEnabled()?1:0,
        binaryInventoryVersion:1,binaryDownloadVersion:1,recordBackupVersion:VS_testBackupRecoveryEnabled()?4:0,disasterRehearsalVersion:VS_testBackupRecoveryEnabled()?5:0,disasterReadbackVersion:VS_testBackupRecoveryEnabled()?1:0,lastVerifiedRecordBackupAt:Number(p.getProperty('VS_LAST_VERIFIED_RECORD_BACKUP_AT')||0),
        studentImportSheetVersion:1,studentSlotUniquenessVersion:1,studentReadableViewVersion:1,studentReadableViewStatus:PropertiesService.getScriptProperties().getProperty('VS_STUDENT_READABLE_STATUS')||'not yet measured',sheetLifecycleVersion:1,recordStorageMode:VS_sheetLifecycleEnabled()?'sheets':VS_jsonEnabled()?'json':'sheets',attendanceBatchVersion:2,attendanceBatchMaxOperations:25,attendanceBatchBudgetMillis:45000,recordDeltaRecordsVersion:1,scriptBundleVersion:'2026-10-18.1',googleEmail:''};
    }
    else if(b.action==='managed_delta'){result=VS_managedDelta(b);}
    else if(b.action==='managed_view'){result=VS_managedView(b);}
    else if(b.action==='managed_mobile'){result=VS_managedMobile(b.request,b.lease);}
    else if(b.action==='managed_attendance_batch'){result=VS_managedAttendanceBatch(b);}
    else if(b.action==='managed_summary'){result=VS_managedSummary();}
    else if(['managed_import_sheet_setup','managed_import_sheet_read'].indexOf(b.action)>=0){result=VS_importSheet(b);}
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

    }else if(b.action==='managed_binary_inventory'){
      result=VS_binaryInventory(b);
    }else if(b.action==='managed_binary_download'){
      result=VS_binaryDownload(b);
    }else if(b.action==='managed_file'){
      const blob=VS_managedFile(b.fileId).getBlob();if(blob.getBytes().length>20*1024*1024)throw new Error('File limit exceeded');result={mime:blob.getContentType(),base64:Utilities.base64Encode(blob.getBytes())};
    }else if(b.action==='managed_backup'){
      if(PropertiesService.getScriptProperties().getProperty('VS_SHEET_LIFECYCLE')!=='off'){result=VS_createSheetBackup();return jsonResponse(Object.assign({success:true,schoolId:school},result));}
      if(VS_jsonEnabled())throw new Error('Use verified full snapshot for JSON storage backup');
      if(VS_testBackupRecoveryEnabled())return jsonResponse(Object.assign({success:true,schoolId:school},VS_createVerifiedRecordBackup()));
      const root=VS_managedRoot(),folders=root.getFolders(),records={};while(folders.hasNext()){const f=folders.next();if(f.getName().indexOf('records_')===0)records[f.getName().slice(8)]=VS_managedRecord({collection:f.getName().slice(8),operation:'read'}).records;}
      const text=JSON.stringify({schemaVersion:3,schoolId:school,createdAt:new Date().toISOString(),records:records});if(text.length>20*1024*1024)throw new Error('Backup exceeds safe file limit');const file=VS_managedFolder(root,'Backups').createFile('School_Backup_'+Date.now()+'.json',text,'application/json');result={fileId:file.getId(),fileUrl:'https://drive.google.com/file/d/'+file.getId()+'/view'};
    }else if(b.action==='managed_disaster'){
      result=VS_managedDisaster(b);
    }else if(b.action==='managed_disaster_readback'){
      result=VS_managedDisasterReadback(b);
    }else if(b.action==='managed_recycle'){
      result=VS_managedRecycle(b);
    }else if(b.action==='managed_restore'){
      const file=VS_managedFile(b.fileId),blob=file.getBlob();if(blob.getBytes().length>20*1024*1024)throw new Error('Backup too large');const backup=JSON.parse(blob.getDataAsString());
      if(backup.schemaVersion!==3||backup.schoolId!==school||!backup.records||typeof backup.records!=='object')throw new Error('Foreign or unsupported backup');
      const pending=[];Object.keys(backup.records).forEach(col=>{VS_managedCollection(col);Object.keys(backup.records[col]).forEach(id=>{const data=backup.records[col][id];if(!/^[^/]{1,200}$/.test(id)||id==='.'||id==='..'||!data||data.schoolId!==school)throw new Error('Invalid backup record');pending.push({collection:col,id:id,data:data,operation:'write',createOnly:true});});});
      let copied=0,skipped=0;const lock=LockService.getScriptLock();lock.waitLock(30000);try{pending.forEach(r=>{const result=VS_managedRecordUnlocked(r);if(result.skipped)skipped++;else copied++;});}finally{lock.releaseLock();}result={copied:copied,skipped:skipped};
    }else throw new Error('Unknown managed storage action');
    if(b.action==='managed_records'&&b.operation!=='read'&&result.recordRevision&&VS_sheetLifecycleEnabled()){const saved=VS_sheetItem(VS_managedSheet(b.collection),b.id);if(saved)result.record=saved.data;}
    return jsonResponse(Object.assign({success:true,schoolId:school},result));
  }catch(error){
    const safe={
      'This QR does not belong to the active school':'This QR is invalid or has not synced to this school. Ask the school to sync or regenerate the ID card.',
      'Record revision conflict':'Record revision conflict',
      'Student class/section/roll conflict':'Student class/section/roll conflict',
      'Import Sheet school binding requires review':'Import Sheet school binding requires review',
      'Import Sheet header/version requires review':'Import Sheet header/version requires review',
      'Import Sheet exceeds 100 row admission bound':'Import Sheet exceeds 100 row admission bound',
      'Explicit import Sheet creation confirmation required':'Explicit import Sheet creation confirmation required',
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
    // Anonymous web-app cache and owner-editor cache can be different.
    // Save ONLY a sanitized owner-only category + line for at most 24 hours.
    // Never persist payloads, URLs, school identifiers or raw exceptions.
    if(verified){
      try{PropertiesService.getScriptProperties().setProperty('VS_OWNER_LAST_SYNC_DIAGNOSTIC_V2',JSON.stringify(trace));}catch(_){}
    }
    const code=verified?diagnostic:'SCRIPT_OPERATION_FAILED';
    return jsonResponse({success:false,schoolId:school,message:safe[error.message]||'School storage request rejected',code:code});
  }
}

// Run manually in the owner editor only; not routed through doPost/doGet.
function VS_readLastSyncDiagnostic() {
  // Owner-editor function ONLY. This is NOT a doGet/doPost action.
  const key='VS_OWNER_LAST_SYNC_DIAGNOSTIC_V2';
  let trace=null;
  function sanitized(raw,maxAge){
    if(typeof raw!=='string'||raw.length>4096)return null;
    try{
      const candidate=JSON.parse(raw);
      if(candidate&&candidate.event==='managed_storage_failure'&&
          Number.isSafeInteger(candidate.at)&&candidate.at>=0&&candidate.at<=Date.now()&&
          Date.now()-candidate.at<=maxAge&&
          /^[A-Z0-9_]{4,80}$/.test(candidate.code||'')&&
          Number.isSafeInteger(candidate.line)&&candidate.line>=0&&candidate.line<=1000000){
        return {at:candidate.at,phase:candidate.phase==='authorized_operation'?'authorized_operation':'request_verification',code:candidate.code,line:candidate.line};
      }
    }catch(_){}
    return null;
  }
  try{trace=sanitized(PropertiesService.getScriptProperties().getProperty(key),86400000);}catch(_){}
  if(!trace){
    try{trace=sanitized(CacheService.getScriptCache().get('VS_SYNC_DIAGNOSTIC_V1'),1800000);}catch(_){}
  }
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
function VS_layoutSave(state){if(VS_jsonEnabled())throw new Error('JSON storage active; Sheet layout changes require owner review');PropertiesService.getScriptProperties().setProperty('VS_LAYOUT_'+state.collection,JSON.stringify(state));}
function VS_managedSheet(collection,readContext) {
  if(VS_jsonEnabled()){if(!VS_sheetLifecycleEnabled())return VS_jsonStore(collection);return VS_migrateJsonCategoryToSheets(collection,readContext);}
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
    return {sheet:sheet,school:school,collection:state.collection,bookId:target.id};
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
  if(VS_jsonEnabled())throw new Error('JSON storage active; Sheet layout changes require owner review');
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
  if(VS_jsonEnabled())throw new Error('JSON storage active; Sheet layout changes require owner review');
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
              const raw=files.next().getBlob().getDataAsString();bytes+=raw.length*4;if(bytes>20*1024*1024)throw new Error('Collection migration exceeds safe limit');const item=JSON.parse(raw);
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
  if(VS_jsonEnabled())throw new Error('JSON storage active; Sheet layout changes require owner review');
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
  if(VS_jsonEnabled())throw new Error('JSON storage active; Sheet layout changes require owner review');
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
  // Discovery hints only: no Sheets/Drive opens, recovery, writes or ACKs.
  // Normal delta reads verify records; hourly audit detects external edits.
  if(b.headOnly!==undefined&&typeof b.headOnly!=='boolean')throw new Error('Invalid delta mode');
  if(b.headOnly===true){
    const lock=LockService.getScriptLock();lock.waitLock(1000);
    try{const props=PropertiesService.getScriptProperties().getProperties(),revisions={};
      b.collections.forEach(col=>{revisions[col]=props['VS_RECORD_REV_'+col]||'legacy';});
      return {syncProtocol:2,headOnly:true,revisions:revisions};
    }finally{lock.releaseLock();}
  }
  const lock=LockService.getScriptLock();lock.waitLock(30000);
  try{const changes={},p=PropertiesService.getScriptProperties(),readContext={};
    let recoveryBackup=null;if(VS_testBackupRecoveryEnabled()&&p.getProperty('VS_LAST_VERIFIED_RECORD_BACKUP')){
      try{recoveryBackup=VS_verifiedRecordBackup(p.getProperty('VS_LAST_VERIFIED_RECORD_BACKUP'));}catch(_){p.setProperty('VS_LAST_RECORD_RECOVERY',JSON.stringify({at:Date.now(),verified:false,needsReview:true,code:'BACKUP_INTEGRITY_UNVERIFIED'}));}
    }
    if(b.knownRecordRevisions!==undefined)VS_validateRecordCheckpoints(b.knownRecordRevisions,b.collections);
    b.collections.forEach(col=>{if(VS_sheetLifecycleEnabled()){changes[col]=VS_managedRecordUnlocked({operation:'read',collection:col,syncProtocol:2,knownRevision:b.knownRevisions&&b.knownRevisions[col],...(b.knownRecordRevisions&&Object.prototype.hasOwnProperty.call(b.knownRecordRevisions,col)?{knownRecordRevisions:b.knownRecordRevisions[col]}:{})},readContext);return;}if(VS_jsonEnabled())VS_jsonStore(col);if(recoveryBackup&&recoveryBackup.records[col])VS_recoverMissingBackupRows(col,VS_managedSheet(col),recoveryBackup);const revision=p.getProperty('VS_RECORD_REV_'+col)||'legacy';if(col==='students_directory'&&b.knownRevisions&&b.knownRevisions[col]===revision)VS_refreshStudentReadable(VS_managedSheet(col));changes[col]=b.knownRevisions&&b.knownRevisions[col]===revision?{records:{},unchanged:true,collectionRevision:revision,syncProtocol:2}:VS_managedRecordUnlocked({operation:'read',collection:col,syncProtocol:2});});
    if(JSON.stringify(changes).length>20*1024*1024)throw new Error('Delta export exceeds safe limit');return {syncProtocol:2,changes:changes};
  }finally{lock.releaseLock();}
}

// JSON category generations are immutable. The single Script Property head is
// the commit point under the existing Sync request lock. Failed/unpublished
// generations and all previous heads remain in Drive as recovery evidence.
function VS_jsonEnabled(){
  const p=PropertiesService.getScriptProperties(),mode=p.getProperty('VS_RECORD_STORAGE');
  const hasJSON=Object.keys(p.getProperties()).some(k=>k.indexOf('VS_JSON_CUTOVER_')===0||k.indexOf('VS_JSON_HEAD_')===0);
  if(mode==='json')return true;
  if(mode&&mode!=='sheets')throw new Error('Unknown school record storage mode');
  if(hasJSON){if(mode==='sheets'&&!VS_sheetLifecycleEnabled())throw new Error('JSON cutover exists; stale Sheet routing blocked');return true;}
  return false; // User-selected default: readable Google Sheets, media in Drive.
}
function VS_jsonValidate(store,value){
  if(!value||value.schemaVersion!==1||value.schoolId!==store.school||value.collection!==store.collection||!value.records||Array.isArray(value.records)||typeof value.records!=='object')throw new Error('JSON category identity mismatch');
  Object.keys(value.records).forEach(id=>{const d=value.records[id];if(!/^[^/]{1,200}$/.test(id)||id==='.'||id==='..'||!d||typeof d!=='object'||Array.isArray(d)||d.schoolId!==store.school)throw new Error('Foreign school record');});
  value.records=Object.assign(Object.create(null),value.records);return value;
}
function VS_jsonRead(store){
  const raw=PropertiesService.getScriptProperties().getProperty('VS_JSON_HEAD_'+store.collection);
  if(!raw)throw new Error('JSON head missing; operator review required');
  const head=JSON.parse(raw),file=VS_managedFile(head.fileId);
  if(head.schoolId!==store.school||head.schemaVersion!==1||file.getDescription()!=='VIDYA_JSON:'+store.school+':'+store.collection+':'+head.hash)throw new Error('JSON category identity mismatch');
  const blob=file.getBlob();if(blob.getBytes().length>20*1024*1024)throw new Error('JSON category exceeds safe limit');
  const value=VS_jsonValidate(store,JSON.parse(blob.getDataAsString()));
  if(VS_layoutHash(value)!==head.hash)throw new Error('JSON readback verification failed');
  return value;
}
function VS_jsonCommit(store,records){
  const p=PropertiesService.getScriptProperties(),key='VS_JSON_HEAD_'+store.collection,previous=p.getProperty(key)||null;
  const value=VS_jsonValidate(store,{schemaVersion:1,schoolId:store.school,collection:store.collection,generation:Utilities.getUuid(),createdAt:new Date().toISOString(),previousHead:previous?JSON.parse(previous):null,records:records});
  const text=JSON.stringify(value);if(Utilities.base64Decode(Utilities.base64Encode(text)).length>20*1024*1024)throw new Error('JSON category exceeds safe limit');
  const folder=VS_managedFolder(VS_managedFolder(VS_managedRoot(),'School JSON'),store.collection),hash=VS_layoutHash(value);
  const file=folder.createFile(store.collection+'_'+value.generation+'.json',text,'application/json');
  file.setDescription('VIDYA_JSON:'+store.school+':'+store.collection+':'+hash);
  if(VS_layoutHash(VS_jsonValidate(store,JSON.parse(file.getBlob().getDataAsString())))!==hash)throw new Error('JSON readback verification failed');
  if((p.getProperty(key)||null)!==previous)throw new Error('JSON head changed; retry Sync');
  p.setProperty(key,JSON.stringify({schemaVersion:1,schoolId:store.school,fileId:file.getId(),hash:hash,collectionRevision:Utilities.getUuid()}));
  p.setProperty('VS_RECORD_REV_'+store.collection,JSON.parse(p.getProperty(key)).collectionRevision);
  VS_jsonRead(store); // No ACK before independently reading the committed head.
}
function VS_jsonLegacyRecords(collection,school){
  const p=PropertiesService.getScriptProperties(),state=VS_layoutState(collection);
  if(state&&state.phase!=='active'&&state.phase!=='rolledBack')throw new Error('Sheet migration in progress; owner review required');
  if(state&&state.phase==='active')return VS_sheetRecords(VS_layoutStore(state));
  const records=Object.create(null),bookId=p.getProperty('VS_MANAGED_SHEET_ID');
  if(p.getProperty('VS_MANAGED_SHEET_PENDING'))throw new Error('Pending workbook identity requires owner review');
  if(bookId){const f=VS_managedFile(bookId);if(f.getDescription()!=='VIDYA_SCHOOL_DATA:'+school)throw new Error('School workbook identity mismatch');const tab=SpreadsheetApp.openById(bookId).getSheetByName(collection);if(tab)Object.assign(records,VS_sheetRecords({sheet:tab,school:school}));else if(p.getProperty('VS_SHEET_MIGRATED_'+collection)==='1')throw new Error('Verified school tab is missing; operator recovery required');}
  if(p.getProperty('VS_SHEET_MIGRATED_'+collection)!=='1'){
    const folders=VS_managedRoot().getFoldersByName('records_'+collection);if(folders.hasNext()){
      const folder=folders.next();if(folders.hasNext())throw new Error('Duplicate collection folders; operator review required');
      const files=folder.getFiles(),seen=Object.create(null);let bytes=0;
      while(files.hasNext()){const raw=files.next().getBlob().getDataAsString();bytes+=raw.length*4;if(bytes>20*1024*1024)throw new Error('Collection migration exceeds safe limit');const item=JSON.parse(raw);
        if(!item||typeof item.id!=='string'||item.schoolId!==school||!item.data||item.data.schoolId!==school)throw new Error('Foreign school record');
        if(seen[item.id]||(Object.prototype.hasOwnProperty.call(records,item.id)&&VS_layoutHash(records[item.id])!==VS_layoutHash(item.data)))throw new Error('Migration conflict; both versions retained');
        seen[item.id]=true;records[item.id]=item.data;
      }
    }
  }
  return records;
}
function VS_jsonStore(collection){
  VS_validateManagedCollection(collection);
  const p=PropertiesService.getScriptProperties(),store={json:true,collection:collection,school:p.getProperty('VS_MANAGED_SCHOOL_ID')};
  if(!p.getProperty('VS_JSON_HEAD_'+collection)){
    if(p.getProperty('VS_JSON_CUTOVER_'+collection)==='1')throw new Error('JSON head missing; operator review required');
    const records=VS_jsonLegacyRecords(collection,store.school);
    VS_jsonCommit(store,records);
    if(VS_layoutHash(records)!==VS_layoutHash(VS_jsonRead(store).records))throw new Error('JSON migration verification failed');
    // Invalidate delta cursors only once after verified cutover. Original Sheets
    // are never modified; all metadata, revisions and tombstones are copied.
  }else VS_jsonRead(store);
  const committedHead=JSON.parse(p.getProperty('VS_JSON_HEAD_'+collection));
  if(typeof committedHead.collectionRevision!=='string'||!committedHead.collectionRevision)throw new Error('JSON category identity mismatch');
  p.setProperty('VS_RECORD_REV_'+collection,committedHead.collectionRevision);
  p.setProperty('VS_JSON_CUTOVER_'+collection,'1');
  return store;
}
function VS_jsonPut(store,item){
  if(item.schoolId!==store.school||!item.data||item.data.schoolId!==store.school)throw new Error('Foreign school record');
  if(JSON.stringify(item).length>512*1024)throw new Error('Record too large; upload files separately');
  const records=VS_jsonRead(store).records;records[item.id]=item.data;VS_jsonCommit(store,records);
}

// Readable non-student columns derive only from the committed canonical row.
// Never read display cells back into Sync, never overwrite owner columns.
function VS_recordReadableText(value){
  const text=value===undefined||value===null?'':value&&typeof value==='object'&&typeof value.__vsTimestamp==='string'?value.__vsTimestamp:typeof value==='object'?JSON.stringify(value):String(value);
  if(text.length>40000)throw new Error('Readable field exceeds Sheet display limit; canonical record retained');
  return /^[=+\-@]/.test(text)?"'"+text:text;
}
function VS_recordReadableHeader(key){return /^[=+\-@]/.test(key)?'Field: '+key:key;}
function VS_recordViewHeaders(sheet,start,width){
  const available=Math.max(0,Math.min(width,sheet.getMaxColumns()-start+1));
  return (available?sheet.getRange(1,start,1,available).getValues()[0]:[]).concat(Array(width-available).fill(''));
}
function VS_refreshRecordReadable(store,item,row){
  if(store.json||store.collection==='students_directory')return;
  const p=PropertiesService.getScriptProperties();
  try{
    if(store.partitions){store.partitions.forEach(part=>VS_refreshRecordReadable(part));return;}
    const key='VS_RECORD_VIEW_FIELDS_'+(store.bookId||'legacy')+':'+store.sheet.getName(),raw=p.getProperty(key);
    const fields=raw?JSON.parse(raw):[];
    if(!Array.isArray(fields)||fields.length>128||fields.some(k=>typeof k!=='string'))throw new Error('Readable view identity requires review');
    const last=store.sheet.getLastRow(),entries=item?[{item:item,row:row}]:[];let nextCursor=null;
    if(!raw&&store.sheet.getMaxColumns()>33&&last>0&&store.sheet.getRange(1,34,last,store.sheet.getMaxColumns()-33).getValues().some(r=>r.some(v=>v!=='')))throw new Error('Readable columns contain owner data; review required');
    if(!item&&last>=2){const start=Math.max(2,Number(p.getProperty(key+'_cursor')||2)),end=Math.min(last,start+99);if(start<=end){store.sheet.getRange(start,1,end-start+1,33).getValues().forEach((v,n)=>{if(v[0])entries.push({item:VS_sheetDecode(store,v),row:start+n});});nextCursor=end+1;}}
    const oldHeaders=['Record ID'].concat(fields.map(VS_recordReadableHeader)),existing=VS_recordViewHeaders(store.sheet,34,oldHeaders.length);
    if(raw?existing.some((v,n)=>v!==oldHeaders[n]):existing.some(v=>v!==''))throw new Error('Readable columns contain owner data; review required');
    const added=[];entries.forEach(e=>Object.keys(e.item.data).sort().forEach(k=>{if(k.indexOf('_sync')!==0&&fields.indexOf(k)<0){fields.push(k);added.push(k);}}));
    if(fields.length>128)throw new Error('Readable view field capacity exceeded');
    const headers=['Record ID'].concat(fields.map(VS_recordReadableHeader));
    const nextStart=34+oldHeaders.length,available=Math.max(0,Math.min(added.length,store.sheet.getMaxColumns()-nextStart+1));
    if(available&&store.sheet.getRange(1,nextStart,Math.max(last,1),available).getValues().some(r=>r.some(v=>v!=='')))throw new Error('Readable columns contain owner data; review required');
    if(store.sheet.getMaxColumns()<33+headers.length)store.sheet.insertColumnsAfter(store.sheet.getMaxColumns(),33+headers.length-store.sheet.getMaxColumns());
    if(!raw||added.length){
      store.sheet.getRange(1,34,1,headers.length).setValues([headers]);SpreadsheetApp.flush();
      if(JSON.stringify(store.sheet.getRange(1,34,1,headers.length).getValues()[0])!==JSON.stringify(headers))throw new Error('Readable view header verification failed');
      p.setProperty(key,JSON.stringify(fields));
    }
    // At most 100 backfill rows; batch adjacent rows without touching gaps or
    // owner cells. Keep readback verification before advancing the cursor.
    const batches=[];
    entries.forEach(e=>{const d=e.item.data,values=[VS_recordReadableText(e.item.id)].concat(fields.map(k=>e.item.layoutRedirect||d._syncDeleted?'':VS_recordReadableText(d[k]))),lastBatch=batches[batches.length-1];
      if(lastBatch&&lastBatch.row+lastBatch.values.length===e.row)lastBatch.values.push(values);
      else batches.push({row:e.row,values:[values]});
    });
    batches.forEach(batch=>{const range=store.sheet.getRange(batch.row,34,batch.values.length,headers.length);range.setValues(batch.values);SpreadsheetApp.flush();VS_verifyStudentReadable(batch.values,range.getValues());});
    // New fields must be projected to prior rows before hiding canonical data.
    if(added.length&&last>2)p.setProperty(key+'_cursor','2');else if(nextCursor!==null)p.setProperty(key+'_cursor',String(nextCursor));
    if(store.sheet.hideColumns&&Number(p.getProperty(key+'_cursor')||2)>last)store.sheet.hideColumns(1,33);
    p.setProperty('VS_RECORD_READABLE_STATUS_'+store.collection,'available; existing rows may require bounded backfill');
  }catch(_){p.setProperty('VS_RECORD_READABLE_STATUS_'+store.collection,'blocked: owner columns or display limits require review; canonical records retained');}
}

// Immutable, category-scoped JSON backups of verified Sheet records. Sheets
// remain authoritative. Sync receives no write ACK until this file readback
// succeeds; a committed Sheet write with a failed backup retries the same op.
function VS_recordJsonBackup(store,item){
  if(store.json||VS_sheetLifecycleEnabled()||PropertiesService.getScriptProperties().getProperty('VS_RECORD_JSON_BACKUPS')==='off')return null;
  VS_validateManagedCollection(store.collection);
  if(!item||item.schoolId!==store.school||!item.data||item.data.schoolId!==store.school||typeof item.id!=='string')throw new Error('Foreign school record');
  const value={schemaVersion:1,backupKind:'sheet_record_revision',schoolId:store.school,collection:store.collection,id:item.id,recordRevision:item.data._syncRevision||'',data:item.data};
  const text=JSON.stringify(value,null,2);if(Utilities.base64Decode(Utilities.base64Encode(text)).length>1024*1024)throw new Error('Record JSON backup exceeds safe limit');
  const hash=VS_layoutHash(value),root=VS_managedRoot(),folder=VS_managedFolder(VS_managedFolder(VS_managedFolder(root,'Backups'),'Record_JSON'),store.collection);
  const name=VS_layoutHash(item.id)+'_'+hash+'.json',marker='VIDYA_RECORD_JSON:'+store.school+':'+store.collection+':'+hash;
  const matches=folder.getFilesByName(name);let file;
  if(matches.hasNext()){file=matches.next();if(matches.hasNext())throw new Error('Record JSON backup collision; retained for review');if(file.getDescription()!==marker){if(file.getDescription()||VS_layoutHash(JSON.parse(VS_managedFile(file.getId()).getBlob().getDataAsString()))!==hash)throw new Error('Record JSON backup collision; retained for review');file.setDescription(marker);}}
  else {file=folder.createFile(name,text,'application/json');file.setDescription(marker);}
  const verified=VS_managedFile(file.getId()),blob=verified.getBlob();
  if(blob.getBytes().length>1024*1024||VS_layoutHash(JSON.parse(blob.getDataAsString()))!==hash)throw new Error('Record JSON backup readback failed');
  return {fileId:file.getId(),fileUrl:'https://drive.google.com/file/d/'+file.getId()+'/view',sha256:hash,recordRevision:value.recordRevision};
}
// Owner-editor export of existing managed Sheet rows; five records per call,
// no scheduler, queue changes, restore or second synchronization engine.
function VS_exportExistingRecordJsonBackups(){
  const lock=LockService.getScriptLock();lock.waitLock(30000);
  try{
    VS_managedRoot();if(VS_jsonEnabled())throw new Error('Sheet JSON export requires Sheet authority');
    if(PropertiesService.getScriptProperties().getProperty('VS_RECORD_JSON_BACKUPS')==='off')throw new Error('Record JSON export is disabled');
    const p=PropertiesService.getScriptProperties(),school=p.getProperty('VS_MANAGED_SCHOOL_ID'),key='VS_RECORD_JSON_EXPORT',raw=p.getProperty(key);
    const job=raw?JSON.parse(raw):{schemaVersion:1,schoolId:school,collectionIndex:0,lastId:''};
    if(job.schemaVersion!==1||job.schoolId!==school||!Number.isInteger(job.collectionIndex)||job.collectionIndex<0||job.collectionIndex>VS_LAYOUT_COLLECTIONS.length||typeof job.lastId!=='string')throw new Error('JSON export identity mismatch');
    let exported=0;
    while(job.collectionIndex<VS_LAYOUT_COLLECTIONS.length&&exported<5){
      const collection=VS_LAYOUT_COLLECTIONS[job.collectionIndex],records=VS_jsonLegacyRecords(collection,school),ids=Object.keys(records).sort().filter(id=>id>job.lastId);
      for(const id of ids){if(exported>=5)break;VS_recordJsonBackup({collection:collection,school:school},{id:id,schoolId:school,data:records[id]});job.lastId=id;exported++;p.setProperty(key,JSON.stringify(job));}
      if(!ids.length||job.lastId===ids[ids.length-1]){job.collectionIndex++;job.lastId='';p.setProperty(key,JSON.stringify(job));}
    }
    return {schoolId:school,exported:exported,complete:job.collectionIndex===VS_LAYOUT_COLLECTIONS.length,sourceSheetsChanged:false};
  }finally{lock.releaseLock();}
}

// Sheet-only protocol. Sync State contains hashes/revisions/deletion markers,
// never student names, contact details, photos or record payloads.
function VS_sheetLifecycleEnabled(){return PropertiesService.getScriptProperties().getProperty('VS_SHEET_LIFECYCLE')!=='off';}
function VS_syncStateSheet(create,collection,readContext){
  if(collection)VS_validateManagedCollection(collection);
  const p=PropertiesService.getScriptProperties(),school=p.getProperty('VS_MANAGED_SCHOOL_ID');
  let id=p.getProperty('VS_SYNC_STATE_SHEET_ID'),book;
  if(!id){
    if(!create)return null;
    const pending=p.getProperty('VS_SYNC_STATE_PENDING');
    if(pending){id=pending;const f=DriveApp.getFileById(id);if(f.getDescription()!=='VIDYA_SYNC_STATE:'+school)throw new Error('Sync state identity mismatch');f.moveTo(VS_managedFolder(VS_managedRoot(),'School Data'));VS_managedFile(id);book=SpreadsheetApp.openById(id);}
    else {book=SpreadsheetApp.create('Vidya Saarthi Sync State');id=book.getId();const f=DriveApp.getFileById(id);f.setDescription('VIDYA_SYNC_STATE:'+school);p.setProperty('VS_SYNC_STATE_PENDING',id);f.moveTo(VS_managedFolder(VS_managedRoot(),'School Data'));}
    let tab=book.getSheetByName('Record Heads');if(!tab){tab=book.insertSheet('Record Heads');tab.getRange(1,1,1,2).setValues([['Record key hash','Verified sync metadata']]);}
    p.setProperty('VS_SYNC_STATE_SHEET_ID',id);p.deleteProperty('VS_SYNC_STATE_PENDING');
  }else {
    const verified=readContext&&readContext.syncStateBook;
    if(verified&&verified.id===id&&verified.school===school)book=verified.book;
    else {const f=VS_managedFile(id);if(f.getDescription()!=='VIDYA_SYNC_STATE:'+school||f.isTrashed())throw new Error('Sync state unavailable; recovery requires review');book=SpreadsheetApp.openById(id);}
  }
  if(readContext)readContext.syncStateBook={id:id,school:school,book:book};
  let sheet=book.getSheetByName(collection||'Record Heads');if(!sheet&&create&&collection){sheet=book.insertSheet(collection);sheet.getRange(1,1,1,2).setValues([['Record key hash','Verified sync metadata']]);}if(!sheet&&collection)return null;if(!sheet)throw new Error('Sync state unavailable; recovery requires review');return sheet;
}
function VS_recordHead(collection,id){
  const sheet=VS_syncStateSheet(false,collection);if(!sheet||sheet.getLastRow()<2)return null;
  const key=VS_layoutHash([collection,id]),matches=sheet.getRange(2,1,sheet.getLastRow()-1,1).createTextFinder(key).matchEntireCell(true).matchCase(true).findAll();
  if(matches.length>1)throw new Error('Duplicate sync state; review required');
  if(!matches.length)return null;const row=matches[0].getRow(),head=JSON.parse(sheet.getRange(row,2,1,1).getValues()[0][0]);
  if(head.schoolId!==PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID')||head.collection!==collection||head.id!==id)throw new Error('Sync state identity mismatch');return {row:row,head:head};
}
function VS_saveRecordHead(store,item){
  if(!VS_sheetLifecycleEnabled()||store.json||store.backup)return;
  const d=item.data,sheet=VS_syncStateSheet(true,store.collection),old=VS_recordHead(store.collection,item.id);
  const head={schoolId:store.school,collection:store.collection,id:item.id,revision:d._syncRevision||'',operationId:d._syncOperationId||'',requestHash:d._syncRequestHash||'',deleted:d._syncDeleted===true,generation:d.mobileStableId||d._syncDeletedOwner||'',retiredGenerations:d._syncRetiredStudentGenerations||[],payloadHash:VS_layoutHash(d)};
  // A verified identical head already is the receipt after a lost ACK.
  // Avoid rewriting the sync-state row and flushing on every safe retry.
  if(old&&VS_layoutHash(old.head)===VS_layoutHash(head))return;
  const row=old?old.row:Math.max(2,sheet.getLastRow()+1);if(row>sheet.getMaxRows())sheet.insertRowsAfter(sheet.getMaxRows(),100);
  sheet.getRange(row,1,1,2).setValues([[VS_layoutHash([store.collection,item.id]),JSON.stringify(head)]]);SpreadsheetApp.flush();
  if(VS_layoutHash(VS_recordHead(store.collection,item.id).head)!==VS_layoutHash(head))throw new Error('Sync state verification failed');
}
function VS_missingRecordHeads(store,records,readContext){
  if(!VS_sheetLifecycleEnabled())return [];
  const sheet=VS_syncStateSheet(false,store.collection,readContext);if(!sheet||sheet.getLastRow()<2)return [];
  return sheet.getRange(2,2,sheet.getLastRow()-1,1).getValues().filter(r=>r[0]).map(r=>JSON.parse(r[0])).filter(h=>h.schoolId===store.school&&h.collection===store.collection&&!Object.prototype.hasOwnProperty.call(records,h.id)).map(h=>({id:h.id,revision:h.revision,deleted:h.deleted}));
}
function VS_recoverSheetRecord(b,store){
  if(!VS_sheetLifecycleEnabled()||b.syncProtocol!==2||!b.data||b.data.schoolId!==store.school)throw new Error('Verified Sheet recovery required');
  const saved=VS_recordHead(b.collection,b.id),current=VS_sheetItem(store,b.id);
  if(!saved||saved.head.deleted||saved.head.revision!==b.expectedRecordRevision||VS_layoutHash(b.data)!==saved.head.payloadHash)throw new Error('Recovery revision or content mismatch');
  if(current){if(VS_layoutHash(current.data)!==saved.head.payloadHash)throw new Error('Record revision conflict');}
  else VS_sheetPut(store,{id:b.id,schoolId:store.school,data:b.data});
  PropertiesService.getScriptProperties().setProperty('VS_RECORD_REV_'+b.collection,Utilities.getUuid());
  return {syncProtocol:2,recordRevision:saved.head.revision,recovered:true};
}
function VS_restoreDeletedWorkbook(id,school){
  const file=VS_managedFile(id);if(file.getDescription()!=='VIDYA_SCHOOL_DATA:'+school)throw new Error('School workbook identity mismatch');
  if(file.isTrashed()) {file.setTrashed(false);if(file.isTrashed())throw new Error('School workbook restore unverified');}
  return file;
}
function VS_studentGeneration(data,id){return data.mobileStableId||id;}
function VS_isStudentOwnedRecord(collection,data,id,stable,aliases){
  if(!data||data._syncDeleted)return false;
  if(data.personId!=null)return data.personId===stable && data.role!=='teacher'&&data.ownerRole!=='teacher';
  if(data.role==='teacher'||data.ownerRole==='teacher')return false;
  if(collection==='mobile_users'&&id===Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,'student/'+stable,Utilities.Charset.UTF_8).map(v=>('0'+((v+256)%256).toString(16)).slice(-2)).join(''))return true;
  return ['studentId','studentDocId','studentDocumentId','documentId','oldStudentId','previousStudentId'].some(k=>typeof data[k]==='string'&&aliases.indexOf(data[k])>=0) || collection==='student_scan_index'&&aliases.indexOf(id)>=0;
}
function VS_deleteStudentOwnedRecords(parentId,parent,operationId,replacement){
  const school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID'),stable=VS_studentGeneration(parent,parentId),aliases=[parentId].concat(Array.isArray(parent.previousStudentIds)?parent.previousStudentIds:[]);
  // Exact explicit owner references only; never guess from names or roll alone.
  const categories=['documents','attendance_records','attendance_logs','fee_ledger','fee_payments','exam_results','exam_center_results','student_scan_index','mobile_sessions','mobile_users','mobile_complaints'];
  const cleanup=new Set(parent.photoFileId?[parent.photoFileId]:[]),deletedRecords=[{collection:'students_directory',id:parentId}];
  categories.forEach(collection=>{
    const store=VS_managedSheet(collection),records=VS_sheetRecords(store);
    Object.keys(records).forEach(id=>{const row=records[id];if(row._syncDeleted&&row._syncDeletedOwner===stable){deletedRecords.push({collection:collection,id:id});if(row._syncDeletedFileId)cleanup.add(row._syncDeletedFileId);}if(!VS_isStudentOwnedRecord(collection,row,id,stable,aliases))return;
      deletedRecords.push({collection:collection,id:id});
      const data={schoolId:school,_syncDeleted:true,_syncRevision:Utilities.getUuid(),_syncOperationId:VS_layoutHash([operationId,collection,id]),_syncDeletedOwner:stable};
      if(collection==='documents'){data.documentRevision=row.documentRevision||'';if(row.fileId)data._syncDeletedFileId=row.fileId;}
      VS_sheetPut(store,{id:id,schoolId:school,data:data});
      if(data._syncDeletedFileId)cleanup.add(data._syncDeletedFileId);
      if(row.photoFileId)cleanup.add(row.photoFileId);
      PropertiesService.getScriptProperties().setProperty('VS_RECORD_REV_'+collection,Utilities.getUuid());
    });
  });
  VS_removeStudentRecordJsonBackups(deletedRecords);
  if(cleanup.size){const references=VS_studentFileReferences(parentId,stable);function protect(value){if(!value||typeof value!=='object')return;Object.keys(value).forEach(k=>{if((k==='fileId'||/FileId$/.test(k))&&typeof value[k]==='string')references.add(value[k]);else protect(value[k]);});}protect(replacement);cleanup.forEach(fileId=>VS_removeStudentOwnedFile(fileId,parentId,stable,references));}
}

function VS_studentFileReferences(parentId,stable){
  const references=new Set();

  // Check every active reference, including shared school assets, before trash.
  for(const collection of VS_LAYOUT_COLLECTIONS){
    const records=VS_sheetRecords(VS_managedSheet(collection));
    for(const id of Object.keys(records)){
      const row=records[id];if(row._syncDeleted||collection==='students_directory'&&id===parentId&&VS_studentGeneration(row,id)===stable)continue;
      function collect(value){if(!value||typeof value!=='object')return;Object.keys(value).forEach(k=>{if((k==='fileId'||/FileId$/.test(k))&&typeof value[k]==='string')references.add(value[k]);else if(typeof value[k]==='string'){const match=value[k].match(/^https:\/\/drive\.google\.com\/file\/d\/([A-Za-z0-9_-]+)/);if(match)references.add(match[1]);}else collect(value[k]);});}
      collect(row);
    }
  }
  return references;
}
function VS_removeStudentOwnedFile(fileId,parentId,stable,references){
  if(!fileId)return 'none';
  if(references.has(fileId))return 'retained-shared';
  const file=VS_managedFile(fileId);if(!file.isTrashed())file.setTrashed(true);
  if(!file.isTrashed())throw new Error('Student file deletion not acknowledged');return 'deleted';
}

// One bulk metadata seed per original collection; no per-record Drive files.
// Existing heads always win over a legacy source and cannot be rewritten here.
function VS_seedRecordHeads(store,records,readContext){
  if(!VS_sheetLifecycleEnabled()||store.json||store.partitions)return;
  const p=PropertiesService.getScriptProperties(),key='VS_HEAD_SEEDED_'+store.collection+':'+p.getProperty('VS_MANAGED_SHEET_ID');
  if(p.getProperty(key)==='1')return;
  const ids=Object.keys(records);if(!ids.length){p.setProperty(key,'1');return;}
  const sheet=VS_syncStateSheet(true,store.collection,readContext),last=sheet.getLastRow(),known={};
  if(last>=2)sheet.getRange(2,1,last-1,2).getValues().forEach(row=>{if(row[0])known[row[0]]=true;});
  const rows=[];ids.forEach(id=>{const d=records[id],hash=VS_layoutHash([store.collection,id]);if(known[hash]||!d._syncRevision)return;rows.push([hash,JSON.stringify({schoolId:store.school,collection:store.collection,id:id,revision:d._syncRevision,operationId:d._syncOperationId||'',requestHash:d._syncRequestHash||'',deleted:d._syncDeleted===true,generation:d.mobileStableId||d._syncDeletedOwner||'',retiredGenerations:d._syncRetiredStudentGenerations||[],payloadHash:VS_layoutHash(d)})]);});
  if(rows.length){const start=last+1;if(start+rows.length-1>sheet.getMaxRows())sheet.insertRowsAfter(sheet.getMaxRows(),start+rows.length-1-sheet.getMaxRows());sheet.getRange(start,1,rows.length,2).setValues(rows);SpreadsheetApp.flush();if(VS_layoutHash(sheet.getRange(start,1,rows.length,2).getValues())!==VS_layoutHash(rows))throw new Error('Sync state verification failed');}
  p.setProperty(key,'1');
}

function VS_createSheetBackup(){
  const school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID'),snapshot=VS_managedBackupSnapshot({schoolId:school});
  if(snapshot.recordsComplete!==true)throw new Error('Full record census unavailable; backup not verified');
  const book=SpreadsheetApp.create('School Sheet Backup '+Date.now()),file=DriveApp.getFileById(book.getId());
  file.setDescription('VIDYA_SHEET_BACKUP_PENDING:'+school);file.moveTo(VS_managedFolder(VS_managedRoot(),'Backups'));
  Object.keys(snapshot.records).forEach(collection=>{
    const records=snapshot.records[collection],sheet=book.insertSheet(collection);
    if(sheet.getMaxColumns()<33)sheet.insertColumnsAfter(sheet.getMaxColumns(),33-sheet.getMaxColumns());
    sheet.getRange(1,1,1,33).setValues([['Record Key','School ID','Revision','Deleted','Operation ID','Display Name'].concat(Array.from({length:27},(_,n)=>'Data '+(n+1)))]);
    const rows=Object.keys(records).map(id=>{const d=records[id],text=JSON.stringify({id:id,schoolId:school,data:d}),label=String(d.name||d.studentName||d.title||'').slice(0,200),row=[Utilities.base64EncodeWebSafe(id),school,d._syncRevision||'',d._syncDeleted?'YES':'NO',d._syncOperationId||'',/^[=+\-@]/.test(label)?"'"+label:label];for(let n=0;n<27;n++){const part=text.slice(n*20000,(n+1)*20000);row.push(part?JSON.stringify(part):'');}return row;});
    if(rows.length){if(rows.length+1>sheet.getMaxRows())sheet.insertRowsAfter(sheet.getMaxRows(),rows.length+1-sheet.getMaxRows());sheet.getRange(2,1,rows.length,33).setValues(rows);SpreadsheetApp.flush();}
    if(VS_layoutHash(VS_sheetRecords({sheet:sheet,school:school,collection:collection}))!==VS_layoutHash(records))throw new Error('Sheet backup readback verification failed');
  });
  file.setDescription('VIDYA_SHEET_BACKUP:'+school);
  return {fileId:file.getId(),fileUrl:'https://docs.google.com/spreadsheets/d/'+file.getId()+'/edit',backupFormat:'sheets',verified:true,documentBinariesIncluded:false};
}

// Delete only individually identified legacy record snapshots for the explicit
// student cascade. Mixed-school/full-school archives are never broadly erased.
function VS_removeStudentRecordJsonBackups(deleted){
  const school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID'),root=VS_managedRoot();
  function child(folder,name){const it=folder.getFoldersByName(name);if(!it.hasNext())return null;const result=it.next();if(it.hasNext())throw new Error('Duplicate backup folder; review required');return result;}
  const backups=child(root,'Backups'),records=backups&&child(backups,'Record_JSON');if(!records)return;
  const groups={};deleted.forEach(r=>(groups[r.collection]||(groups[r.collection]=new Set())).add(r.id));
  Object.keys(groups).forEach(collection=>{const folder=child(records,collection);if(!folder)return;const files=folder.getFiles(),prefixes=new Set([...groups[collection]].map(id=>VS_layoutHash(id)));let count=0;
    while(files.hasNext()){if(++count>5000)throw new Error('Student backup cleanup requires bounded owner review');const file=files.next();if(!prefixes.has(file.getName().split('_')[0]))continue;
      const value=JSON.parse(VS_managedFile(file.getId()).getBlob().getDataAsString()),hash=VS_layoutHash(value);
      if(value.schoolId!==school||value.collection!==collection||!groups[collection].has(value.id)||file.getDescription()!=='VIDYA_RECORD_JSON:'+school+':'+collection+':'+hash)throw new Error('Student backup cleanup identity mismatch');
      file.setTrashed(true);if(!file.isTrashed())throw new Error('Student backup deletion not acknowledged');
    }
  });
}

function VS_collectionUsesJson(collection){return VS_jsonEnabled()&&(!VS_sheetLifecycleEnabled()||PropertiesService.getScriptProperties().getProperty('VS_SHEET_CUTOVER_'+collection)!=='1');}
function VS_migrateJsonCategoryToSheets(collection,readContext){
  const p=PropertiesService.getScriptProperties(),school=p.getProperty('VS_MANAGED_SCHOOL_ID'),key='VS_SHEET_CUTOVER_'+collection;
  if(p.getProperty(key)==='1')return VS_legacySheet(collection,readContext);
  const head=p.getProperty('VS_JSON_HEAD_'+collection),proofKey='VS_SHEET_SOURCE_'+collection,proof=head||'legacy';
  if(p.getProperty(proofKey)&&p.getProperty(proofKey)!==proof)throw new Error('JSON source changed during Sheet cutover; review required');
  const records=head?VS_jsonRead({json:true,school:school,collection:collection}).records:VS_jsonLegacyRecords(collection,school);
  const store=VS_legacySheet(collection,readContext),current=VS_sheetRecords(store);
  if(Object.keys(current).some(id=>!Object.prototype.hasOwnProperty.call(records,id)))throw new Error('Sheet cutover contains unrelated rows; review required');
  p.setProperty(proofKey,proof);let copied=0;
  for(const id of Object.keys(records)){
    if(current[id]&&VS_layoutHash(current[id])===VS_layoutHash(records[id]))continue;
    if(copied>=100)throw new Error('School data organization in progress; retry Sync. Pending data retained');
    VS_sheetPut(store,{id:id,schoolId:school,data:records[id]});copied++;
  }
  if(VS_layoutHash(VS_sheetRecords(store))!==VS_layoutHash(records))throw new Error('Sheet cutover verification failed');
  VS_seedRecordHeads(store,records);
  p.setProperty(key,'1');p.setProperty('VS_RECORD_REV_'+collection,Utilities.getUuid());
  return store;
}

function VS_reusableStudentChild(b,existing){
  if(!VS_sheetLifecycleEnabled()||!existing||!existing.data._syncDeleted||b.syncProtocol!==2||b.operation!=='write'||!b.data||!b.data.personId||!b.data.studentId||['fee_payments','fee_ledger','attendance_records','attendance_logs','exam_results','exam_center_results','student_scan_index'].indexOf(b.collection)<0)return false;
  const owner=existing.data._syncDeletedOwner;if(owner===b.data.personId)return false;
  const parent=VS_sheetItem(VS_managedSheet('students_directory'),b.data.studentId);
  return !!(parent&&!parent.data._syncDeleted&&parent.data.mobileStableId===b.data.personId&&(owner||parent.data.replacesStudentGeneration));
}

// Return verified per-operation receipts before the broker's 90-second deadline.
// Unstarted operations have no receipt: the durable central queue retains them.
// This bounds admission of additional work, not the duration of a Google RPC.
function VS_managedAttendanceBatch(b) {
  if(!Array.isArray(b.operations)||b.operations.length>25)throw new Error('Invalid attendance batch');
  const seen=new Set();
  b.operations.forEach(op=>{
    if(!op||!/^[a-f0-9]{64}$/.test(op.operationId||'')||seen.has(op.operationId)||
       !op.request||typeof op.request!=='object'||Array.isArray(op.request))throw new Error('Invalid attendance operation');
    seen.add(op.operationId);
  });
  const acknowledgements=[],started=Date.now(),budget=45000;let longest=0;
  for(const op of b.operations){
    const elapsed=Date.now()-started;
    if(acknowledgements.length&&(elapsed>=budget||elapsed+longest>=budget))break;
    const before=Date.now();
    try{VS_managedMobile(Object.assign({},op.request,{action:'mobile_mark_attendance',operationId:op.operationId}),b.lease);acknowledgements.push({operationId:op.operationId,success:true});}
    catch(e){const authoritative=/School (session expired|record or ID|licence|is closed)|already recorded|Attendance can be marked|own school ID|Accurate school location/.test(e.message||'');acknowledgements.push({operationId:op.operationId,success:false,authoritative:authoritative});}
    longest=Math.max(longest,Date.now()-before);
  }
  return {acknowledgements:acknowledgements,deferredCount:b.operations.length-acknowledgements.length,partial:acknowledgements.length<b.operations.length};
}

// Incremental checkpoints contain revision metadata only, never record payloads.
function VS_validateRecordCheckpoints(checkpoints,collections){
  if(!checkpoints||typeof checkpoints!=='object'||Array.isArray(checkpoints))throw new Error('Invalid record checkpoint');
  let count=0;
  Object.keys(checkpoints).forEach(col=>{
    if(collections.indexOf(col)<0)throw new Error('Invalid record checkpoint');
    const known=checkpoints[col];if(!known||typeof known!=='object'||Array.isArray(known))throw new Error('Invalid record checkpoint');
    Object.keys(known).forEach(id=>{if(++count>100000||!id||id.length>200||id.indexOf('/')>=0||['.','..'].indexOf(id)>=0||typeof known[id]!=='string'||!known[id]||known[id].length>1000)throw new Error('Invalid record checkpoint');});
  });
}
function VS_managedIncrementalRecords(b,readContext){
  VS_validateManagedCollection(b.collection);
  VS_validateRecordCheckpoints({[b.collection]:b.knownRecordRevisions},[b.collection]);
  if(!VS_sheetLifecycleEnabled())throw new Error('Incremental Sheet protocol unavailable');
  const p=PropertiesService.getScriptProperties(),school=p.getProperty('VS_MANAGED_SCHOOL_ID'),revision=p.getProperty('VS_RECORD_REV_'+b.collection)||'legacy';
  // Normal unchanged checks must never scan Sheets, backfill or repair storage.
  if(b.knownRevision===revision)return {syncProtocol:2,collectionRevision:revision,records:{},unchanged:true,partialRecords:true};
  const store=VS_managedSheet(b.collection,readContext);
  if(store.json||store.partitions)throw new Error('Incremental Sheet protocol unavailable');
  const seeded='VS_HEAD_SEEDED_'+store.collection+':'+p.getProperty('VS_MANAGED_SHEET_ID');
  if(p.getProperty(seeded)!=='1')throw new Error('Initial verified record baseline required');
  const sheet=VS_syncStateSheet(false,b.collection,readContext),records=Object.create(null),missing=[],seen=new Set();
  if(!sheet&&(revision!=='legacy'||Object.keys(b.knownRecordRevisions).length))throw new Error('Sync state unavailable; recovery requires review');
  const rows=sheet&&sheet.getLastRow()>=2?sheet.getRange(2,1,sheet.getLastRow()-1,2).getValues():[];
  rows.forEach(row=>{
    if(!row[0]&&!row[1])return;
    const head=JSON.parse(row[1]);
    if(head.schoolId!==school||head.collection!==b.collection||typeof head.id!=='string'||!head.id||typeof head.revision!=='string'||!head.revision||row[0]!==VS_layoutHash([b.collection,head.id])||seen.has(head.id))throw new Error('Sync state identity mismatch');
    seen.add(head.id);
    if(Object.prototype.hasOwnProperty.call(b.knownRecordRevisions,head.id)&&b.knownRecordRevisions[head.id]===head.revision)return;
    const item=VS_sheetItem(store,head.id);
    if(!item){
      if(!head.deleted){missing.push({id:head.id,revision:head.revision,deleted:false});return;}
      records[head.id]={schoolId:school,_syncRevision:head.revision,_syncDeleted:true,...(head.generation?{_syncDeletedOwner:head.generation}:{}),_syncRetiredStudentGenerations:head.retiredGenerations||[]};return;
    }
    if(item.data._syncRevision!==head.revision||VS_layoutHash(item.data)!==head.payloadHash)throw new Error('School record verification failed');
    records[head.id]=item.data;
  });
  if(JSON.stringify(records).length>20*1024*1024)throw new Error('Delta export exceeds safe limit');
  return {syncProtocol:2,collectionRevision:revision,records:records,partialRecords:true,...(missing.length?{missingRecords:missing}:{})};
}

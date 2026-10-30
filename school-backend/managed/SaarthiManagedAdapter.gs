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
/**
 * Read only metadata from the ALREADY authorized school Drive owner.
 * No Google login, extra OAuth scopes, public email lookup, or Drive writes.
 * The Windows client must additionally match the returned owner email to its
 * currently authenticated school admin before displaying the image.
 */
function VS_managedOwnerProfilePhoto(root) {
  try {
    if (!root || typeof root.getOwner !== 'function') return {};
    const owner = root.getOwner();
    if (!owner || typeof owner.getEmail !== 'function' || typeof owner.getPhotoUrl !== 'function') return {};
    const email = String(owner.getEmail() || '').trim().toLowerCase();
    const url = String(owner.getPhotoUrl() || '').trim();
    if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return {};
    if (!/^https:\/\/(?:[a-z0-9-]+\.)*googleusercontent\.com\//i.test(url)) return {};
    return {profilePhotoEmail:email, profilePhotoUrl:url};
  } catch (_) {
    // Missing Drive photo permission/owner never affects signed storage health.
    return {};
  }
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
  // A completed migration no longer consumes the old JSON folder. Do not
  // list/create it on every Sheet request; workbook/root verification below
  // still runs, and incomplete migrations retain the original import path.
  const legacy=p.getProperty('VS_SHEET_MIGRATED_'+collection)==='1'?null:VS_managedCollection(collection);
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
  const started=VS_TEST_SYNC_TIMING?Date.now():0;
  if(VS_TEST_SYNC_TIMING)VS_TEST_SYNC_TIMING.recordLookupCount++;
  try{return VS_sheetItemCore(store,id);}
  finally{if(started)VS_testSyncTimingAdd('sheetSearchMs',started);}
}
function VS_sheetItemCore(store,id) {
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
function VS_sheetPut(store,item,lookup) {
  if(VS_TEST_SYNC_TIMING)VS_TEST_SYNC_TIMING.storageMode=store.json?'json':store.partitions?'partitioned_sheets':'sheets';
  if(store.json)return VS_jsonPut(store,item);
  if(store.partitions)return VS_layoutPut(store,item);
  const text=JSON.stringify({id:item.id,schoolId:item.schoolId,data:item.data,...(item.layoutRedirect?{layoutRedirect:item.layoutRedirect}:{}),...(item.layoutPrevious?{layoutPrevious:item.layoutPrevious}:{})});
  if(text.length>512*1024)throw new Error('Record too large; upload files separately');
  // Only the current locked operation may supply its own lookup. Never keep
  // this proof globally, across requests, or across partition/layout changes.
  const reuse=lookup&&lookup.store===store&&lookup.id===item.id;
  const old=reuse?lookup.item:VS_sheetItem(store,item.id),data=item.data;
  if(old&&(old.id!==item.id||old.schoolId!==store.school||!Number.isSafeInteger(old.row)||old.row<2))throw new Error('Sheet lookup identity mismatch');
  if(reuse&&old){
    // A human can edit Sheets without our script lock. Re-read the exact row
    // before overwriting it; the final full search still detects duplicates.
    const current=VS_sheetDecode(store,store.sheet.getRange(old.row,1,1,33).getValues()[0]);
    if(current.id!==old.id||VS_layoutHash(current)!==VS_layoutHash({id:old.id,schoolId:old.schoolId,data:old.data,...(old.layoutRedirect?{layoutRedirect:old.layoutRedirect}:{}),...(old.layoutPrevious?{layoutPrevious:old.layoutPrevious}:{})}))throw new Error('External Sheet edit requires review');
  }
  // Display cells are inert text; canonical JSON always begins with '{'.
  const label=String(data.name||data.studentName||data.title||data.documentName||'').slice(0,200);
  const values=[Utilities.base64EncodeWebSafe(item.id),store.school,data._syncRevision||'',data._syncDeleted===true?'YES':'NO',data._syncOperationId||'',label&&/^[=+\-@]/.test(label)?"'"+label:label];
  // Quoted fragments cannot be interpreted as Sheet formulas, even when a
  // continuation begins with '='. Rejoining preserves all Unicode code units.
  for(let n=0;n<27;n++){const part=text.slice(n*20000,(n+1)*20000);values.push(part?JSON.stringify(part):'');}
  const row=old?old.row:Math.max(2,store.sheet.getLastRow()+1);
  if(row>store.sheet.getMaxRows())store.sheet.insertRowsAfter(store.sheet.getMaxRows(),Math.max(100,row-store.sheet.getMaxRows()));
  const writeStarted=VS_TEST_SYNC_TIMING?Date.now():0;
  store.sheet.getRange(row,1,1,33).setValues([values]);SpreadsheetApp.flush();
  if(writeStarted)VS_testSyncTimingAdd('sheetWriteFlushMs',writeStarted);
  const verifyStarted=VS_TEST_SYNC_TIMING?Date.now():0;
  const saved=VS_sheetItem(store,item.id);
  if(!saved||JSON.stringify(saved.data)!==JSON.stringify(data))throw new Error('School record verification failed');
  if(verifyStarted)VS_testSyncTimingAdd('finalVerificationMs',verifyStarted);
  const afterVerify=VS_TEST_SYNC_TIMING?Date.now():0;
  VS_saveRecordHead(store,saved);
  VS_recordJsonBackup(store,saved);
  VS_refreshStudentReadable(store,item,row);
  VS_refreshRecordReadable(store,item,row);
  if(afterVerify)VS_testSyncTimingAdd('postVerificationMs',afterVerify);
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
  if(b.operation==='write')Object.keys(b.data||{}).forEach(k=>{if(['_syncRevision','_syncOperationId','_syncRequestHash','_syncDeleted','_syncDeletedFileId','_syncFileCleanupComplete','_syncFieldRevisions'].indexOf(k)<0)data[k]=b.data[k];});
  return {operation:b.operation,data:data};
}
// TEST-only duration diagnostics. No change to lock ownership, CAS,
// ACK rules, student content, queue processing or storage. Never enabled for
// real schools; only isolated synthetic version-2 TEST notice writes qualify.
var VS_TEST_SYNC_TIMING=null;
function VS_testSyncTimingAdd(key,start){
  if(VS_TEST_SYNC_TIMING)VS_TEST_SYNC_TIMING[key]=(VS_TEST_SYNC_TIMING[key]||0)+Math.max(0,Date.now()-start);
}
function VS_managedRecord(b) {
  VS_BACKUP_READ_CACHE=null;
  // Cheap JS-only checks first: ordinary school traffic makes no new
  // Apps Script PropertiesService call just to determine instrumentation.
  const timed=b.syncProtocol===2&&b.operation==='write'&&['school_notices','students_directory','teachers_directory','documents','fee_ledger','fee_payments','school_expenses'].indexOf(b.collection)>=0&&
    b.data&&b.data.syntheticTest===true&&
    PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID')==='vs-db8afb01a3be46a983c8284714d06e5d';
  const timing=timed?{version:1,scope:'isolated_synthetic_TEST_only',
    lockWaitMs:0,recordLookupCount:0,sheetSearchMs:0,sheetWriteFlushMs:0,finalVerificationMs:0,
    postVerificationMs:0,storageMode:'unknown',totalScriptMs:0}:null;
  const began=Date.now(),lock=LockService.getScriptLock();
  // Acquire the EXACT SAME lock with the EXACT SAME deadline.
  const waiting=Date.now();lock.waitLock(30000);
  if(timing)timing.lockWaitMs=Date.now()-waiting;
  try{
    if(timing)VS_TEST_SYNC_TIMING=timing;
    const result=VS_managedRecordUnlocked(b);
    if(timing){timing.totalScriptMs=Date.now()-began;result.testScriptTiming=timing;}
    return result;
  }finally{
    VS_TEST_SYNC_TIMING=null;
    lock.releaseLock();
  }
}
// Capability-gated field edits. Same-field stale retries never overwrite a
// later edit, including an A->B->A change. Per-field revisions prevent ABA.
function VS_applyFieldPatch(b,existing,school) {
  const patch=b.data&&b.data._syncFieldPatch;
  if(!patch)return null;
  if(b.operation!=='write'||b.syncProtocol!==2||!b.expectedRecordRevision||
      ['documents','backups'].indexOf(b.collection)>=0||!existing||existing.schoolId!==school||existing.id!==b.id||b.data.schoolId!==school||existing.data._syncDeleted||
      patch.version!==1||!patch.set||typeof patch.set!=='object'||Array.isArray(patch.set)||
      !Array.isArray(patch.remove)||patch.remove.length>256||!patch.before||typeof patch.before!=='object'||
      Object.keys(b.data).some(k=>k!=='schoolId'&&k!=='_syncFieldPatch'))throw new Error('Invalid sync operation');
  const current=existing.data,identity=patch.identity||{},keys=[...new Set([...Object.keys(patch.set),...patch.remove])];
  if(keys.length>256||keys.some(k=>typeof k!=='string'||!k||k.length>200||
      ['id','schoolId','createdAt','__proto__','prototype','constructor'].indexOf(k)>=0||k.indexOf('_sync')===0)||
      patch.remove.some(k=>Object.prototype.hasOwnProperty.call(patch.set,k)))throw new Error('Invalid sync operation');
  for(const key of Object.keys(identity)) {
    if(['mobileStableId','teacherId','studentId','personId'].indexOf(key)<0||typeof identity[key]!=='string'||!identity[key]||identity[key]!==current[key])
      throw new Error('Record revision conflict');
  }
  for(const key of ['studentId','personId'])if(current[key]&&identity[key]!==current[key])throw new Error('Record revision conflict');
  const personKey=b.collection==='students_directory'?'mobileStableId':b.collection==='teachers_directory'?'teacherId':null;
  if(personKey&&(!identity[personKey]||identity[personKey]!==current[personKey]))throw new Error('Record revision conflict');
  if(current._syncRecreatesDeletedRevision&&current._syncRevision!==b.expectedRecordRevision)throw new Error('Record revision conflict');
  for(const key of [personKey,'studentId','personId'].filter(Boolean)) {
    if(Object.prototype.hasOwnProperty.call(patch.set,key)&&patch.set[key]!==current[key]||patch.remove.indexOf(key)>=0)
      throw new Error('Record revision conflict');
  }
  if(current._syncRevision!==b.expectedRecordRevision) {
    for(const key of keys.filter(k=>k!=='updatedAt')) {
      const proof=patch.before[key],exists=Object.prototype.hasOwnProperty.call(current,key);
      const revision=current._syncFieldRevisions&&current._syncFieldRevisions[key]|| (exists?current._syncRevision:'absent');
      if(!proof||typeof proof.exists!=='boolean'||proof.exists!==exists||proof.revision!==revision)
        throw new Error('Record revision conflict');
    }
  }
  const data=Object.assign({},current,patch.set,{schoolId:school});patch.remove.forEach(k=>delete data[k]);
  return data;
}
function VS_nextFieldRevisions(previous,data,revision) {
  const stamps=Object.assign({},previous&&previous._syncFieldRevisions||{});
  const keys=new Set([...Object.keys(previous||{}),...Object.keys(data)]);
  keys.forEach(key=>{if(key==='id'||key==='schoolId'||key.indexOf('_sync')===0)return;
    const had=previous&&Object.prototype.hasOwnProperty.call(previous,key),has=Object.prototype.hasOwnProperty.call(data,key);
    if(!had||!has||VS_layoutHash(previous[key])!==VS_layoutHash(data[key]))stamps[key]=revision;
    else if(!stamps[key])stamps[key]=previous._syncRevision||revision;
  });return stamps;
}
function VS_managedRecordUnlocked(b,readContext) {
  if(b.operation==='read'&&b.knownRecordRevisions!==undefined)return VS_managedIncrementalRecords(b,readContext);
  const store=VS_managedSheet(b.collection,readContext), school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID');
  if(b.operation==='read' && b.syncProtocol===2 && b.id!==undefined) {
    if(typeof b.id!=='string'||!/^[^/]{1,200}$/.test(b.id)||b.id==='.'||b.id==='..')throw new Error('Invalid record ID');
    const item=VS_sheetItem(store,b.id),records=Object.create(null),head=VS_sheetLifecycleEnabled()?VS_recordHead(b.collection,b.id):null;
    if(!item&&head&&!head.head.deleted)throw new Error('Verified local Sheet recovery required before editing');
    if(item){if(item.schoolId!==school||item.id!==b.id)throw new Error('Foreign school record');if(head&&VS_layoutHash(item.data)!==head.head.payloadHash)throw new Error('External Sheet edit requires review');records[b.id]=item.data;}
    else if(head&&head.head.deleted)records[b.id]={schoolId:school,_syncDeleted:true,_syncRevision:head.head.revision,_syncDeletedOwner:head.head.generation};
    return {records:records,pointRead:true,syncProtocol:2,collectionRevision:PropertiesService.getScriptProperties().getProperty('VS_RECORD_REV_'+b.collection)||'legacy'};
  }
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
  const lockedLookup=!store.json&&!store.partitions?{store:store,id:b.id,item:existing}:undefined;
  const retained=VS_sheetLifecycleEnabled()?VS_recordHead(b.collection,b.id):null;
  if(!existing&&retained){const h=retained.head;existing={id:b.id,schoolId:school,data:{schoolId:school,_syncRevision:h.revision,_syncOperationId:h.operationId,_syncRequestHash:h.requestHash,...(h.deleted?{_syncDeleted:true,_syncDeletedOwner:h.generation,_syncRetiredStudentGenerations:h.retiredGenerations||[]}:{})}};
    if(!h.deleted)throw new Error('Verified local Sheet recovery required before editing');}
  const wireHash=VS_layoutHash(VS_syncRequestShape(b));
  // Only an identical authenticated full snapshot can repair a lost-ACK head.
  const provenFullReplay=existing&&b.operation==='write'&&!(b.data&&b.data._syncFieldPatch)&&
    existing.data._syncOperationId===b.operationId&&existing.data._syncRequestHash===wireHash&&
    VS_layoutHash(VS_syncRequestShape({operation:'write',data:existing.data}))===wireHash;
  if(existing&&retained&&VS_layoutHash(existing.data)!==retained.head.payloadHash&&!provenFullReplay)throw new Error('External Sheet edit requires review');
  const patchReplay=b.operation==='write'&&b.syncProtocol===2&&typeof b.expectedRecordRevision==='string'&&b.data&&b.data.schoolId===school&&b.data._syncFieldPatch&&existing&&existing.schoolId===school&&existing.id===b.id&&existing.data._syncOperationId===b.operationId;
  if(patchReplay) {
    if(existing.data._syncRequestHash!==wireHash)throw new Error('Sync operation ID conflict');
    return {recordRevision:existing.data._syncRevision,syncProtocol:2,record:Object.assign({id:b.id},existing.data)};
  }
  const patched=VS_applyFieldPatch(b,existing,school);
  if(patched)b=Object.assign({},b,{data:patched});
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
      const digest=wireHash;
      const original=existing.data._syncRequestHash||VS_layoutHash(VS_syncRequestShape({operation:existing.data._syncDeleted?'delete':'write',data:existing.data}));
      if(digest!==original)throw new Error('Sync operation ID conflict');
      VS_saveRecordHead(store,existing);if(existing.row){VS_refreshStudentReadable(store,existing,existing.row);VS_refreshRecordReadable(store,existing,existing.row);}VS_recordJsonBackup(store,existing);return {recordRevision:existing.data._syncRevision,syncProtocol:2,...(b.operation==='write'?{record:Object.assign({id:b.id},existing.data)}:{}),fileCleanup:existing.data._syncDeleted?VS_managedDeletedFile(store,b.id,existing.data):undefined};
    }
    const replacement=VS_sheetLifecycleEnabled()&&b.collection==='students_directory'&&b.operation==='write'&&existing&&b.data&&/^p-[a-f0-9]{32,64}$/.test(b.data.mobileStableId||'')&&b.data.mobileStableId!==b.data.replacesStudentGeneration&&b.data.replacesStudentGeneration===(existing.data._syncDeleted?existing.data._syncDeletedOwner:VS_studentGeneration(existing.data,b.id));
    const childReplacement=VS_reusableStudentChild(b,existing);
    const sameDeletion=VS_sheetLifecycleEnabled()&&b.collection==='students_directory'&&b.operation==='delete'&&existing&&typeof b.deletedStudentGeneration==='string'&&b.deletedStudentGeneration===(existing.data._syncDeleted?existing.data._syncDeletedOwner:VS_studentGeneration(existing.data,b.id));
    // Independent devices may delete the same record from an older revision.
    // The authoritative tombstone already fulfils that intent. Never rebase a
    // stale delete onto a live (possibly restored/new-generation) record.
    const alreadyDeleted=b.operation==='delete'&&existing&&existing.data._syncDeleted===true;
    if((existing&&existing.data._syncRevision||'')!==b.expectedRecordRevision&&!replacement&&!sameDeletion&&!childReplacement&&!alreadyDeleted&&!patched)throw new Error('Record revision conflict');
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
    if(existing&&existing.data._syncDeleted){VS_saveRecordHead(store,existing);if(existing.row){VS_refreshStudentReadable(store,existing,existing.row);VS_refreshRecordReadable(store,existing,existing.row);}VS_recordJsonBackup(store,existing);return {recordRevision:existing.data._syncRevision,syncProtocol:2,...(b.operation==='write'?{record:Object.assign({id:b.id},existing.data)}:{}),fileCleanup:VS_managedDeletedFile(store,b.id,existing.data)};}
    {
      const revision=Utilities.getUuid(),data={schoolId:school,_syncDeleted:true,_syncRevision:revision};
      if(b.syncProtocol===2){data._syncOperationId=b.operationId;data._syncRequestHash=wireHash;}
      if(VS_sheetLifecycleEnabled()&&b.collection==='students_directory'&&existing){VS_deleteStudentOwnedRecords(b.id,existing.data,b.operationId||revision);data._syncDeletedOwner=VS_studentGeneration(existing.data,b.id);data._syncRetiredStudentGenerations=[...new Set([...(existing.data._syncRetiredStudentGenerations||[]),data._syncDeletedOwner])];}
      if(VS_sheetLifecycleEnabled()&&existing&&existing.data.personId)data._syncDeletedOwner=existing.data.personId;
      if(b.collection==='documents' && existing){data.documentRevision=existing.data.documentRevision||'';const fileId=existing.data._syncDeletedFileId||existing.data.fileId;if(fileId)data._syncDeletedFileId=fileId;}
      if(VS_recycleEnabled()&&existing&&!(VS_sheetLifecycleEnabled()&&b.collection==='students_directory')){const saved=VS_recycleSnapshot(b.collection,b.id,existing,revision);data._syncRecycleFileId=saved.fileId;data._syncRecycleUntil=saved.recoverUntil;}
      PropertiesService.getScriptProperties().setProperty('VS_RECORD_REV_'+b.collection,Utilities.getUuid());
      VS_sheetPut(store,{id:b.id,schoolId:school,data:data},lockedLookup);
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
  if(['documents','backups'].indexOf(b.collection)<0)data._syncFieldRevisions=VS_nextFieldRevisions(existing&&existing.data,data,revision);
  if(b.syncProtocol===2){data._syncOperationId=b.operationId;data._syncRequestHash=wireHash;}
  if(VS_sheetLifecycleEnabled()&&b.collection==='students_directory'){
    delete data._syncRetiredStudentGenerations;delete data._syncDeletedOwner;
    if(existing){const retired=[...new Set([...(existing.data._syncRetiredStudentGenerations||[]),...(existing.data._syncDeleted?[existing.data._syncDeletedOwner]:b.data.replacesStudentGeneration?[b.data.replacesStudentGeneration]:[])].filter(v=>typeof v==='string'&&v))];if(retired.length)data._syncRetiredStudentGenerations=retired;}
  }
  delete data._syncDeletedFileId;delete data._syncFileCleanupComplete;
  const text=JSON.stringify({id:b.id,schoolId:school,data:data});if(text.length>512*1024)throw new Error('Record too large; upload files separately');
  PropertiesService.getScriptProperties().setProperty('VS_RECORD_REV_'+b.collection,Utilities.getUuid());VS_sheetPut(store,{id:b.id,schoolId:school,data:data},lockedLookup);return {recordRevision:revision,syncProtocol:2,record:Object.assign({id:b.id},data),studentUniquenessScope:studentUniquenessScope};
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
    'External Sheet edit requires review':'SCRIPT_EXTERNAL_EDIT_REVIEW_REQUIRED',
    'Record revision conflict':'SCRIPT_RECORD_REVISION_CONFLICT',
    'Sync operation ID conflict':'SCRIPT_OPERATION_ID_CONFLICT',
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
      const root=VS_managedRoot();const p=PropertiesService.getScriptProperties();let sheetsVerified=null;
      if(VS_testBackupRecoveryEnabled()&&!VS_jsonEnabled()){
        const properties=p.getProperties(),collection=VS_LAYOUT_COLLECTIONS.find(col=>properties['VS_SHEET_MIGRATED_'+col]==='1');
        if(collection){const store=VS_managedSheet(collection),parts=store.partitions||[store];parts.forEach(part=>{
          if(part.sheet.getRange(1,1,1,1).getValues()[0][0]!=='Record Key')throw new Error('School tab identity requires review');
        });sheetsVerified=true;}
      }
      result={storageReady:true,driveRootVerified:true,sheetsAccessVerified:sheetsVerified,documentVersions:1,recordSyncVersion:2,recordFieldPatchVersion:1,recordPointReadVersion:1,recordWriteBatchVersion:1,recordDeltaBatchVersion:1,recordChangeHeadsVersion:1,recordStorageVersion:VS_jsonEnabled()?2:1,recordJsonBackupVersion:VS_sheetLifecycleEnabled()?0:1,jsonSchemaVersion:VS_jsonEnabled()?1:0,organizedStorageVersion:2,managedViewVersion:1,recycleVersion:VS_recycleEnabled()?1:0,
        binaryInventoryVersion:1,binaryDownloadVersion:1,uploadResumableVersion:p.getProperty('VS_NATIVE_RESUMABLE_UPLOAD')==='1'?1:0,recordBackupVersion:VS_testBackupRecoveryEnabled()?4:0,disasterRehearsalVersion:VS_testBackupRecoveryEnabled()?5:0,disasterReadbackVersion:VS_testBackupRecoveryEnabled()?1:0,lastVerifiedRecordBackupAt:Number(p.getProperty('VS_LAST_VERIFIED_RECORD_BACKUP_AT')||0),
        studentImportSheetVersion:1,studentSlotUniquenessVersion:1,studentReadableViewVersion:1,studentReadableViewStatus:PropertiesService.getScriptProperties().getProperty('VS_STUDENT_READABLE_STATUS')||'not yet measured',sheetLifecycleVersion:1,recordStorageMode:VS_sheetLifecycleEnabled()?'sheets':VS_jsonEnabled()?'json':'sheets',attendanceScheduleVersion:1,attendanceBatchVersion:2,attendanceBatchMaxOperations:25,attendanceBatchBudgetMillis:45000,recordDeltaRecordsVersion:1,sheetIntegrityAuditVersion:1,recordLookupReuseVersion:1,scriptBundleVersion:'2026-10-30.1',googleEmail:'',...(b.profilePhoto===true?VS_managedOwnerProfilePhoto(root):{})};
    }
    else if(b.action==='managed_integrity_audit'){result=VS_managedIntegrityAudit(b);}
    else if(b.action==='managed_delta'){result=VS_managedDelta(b);}
    else if(b.action==='managed_view'){result=VS_managedView(b);}
    else if(b.action==='managed_mobile'){result=VS_managedMobile(b.request,b.lease);}
    else if(b.action==='managed_attendance_batch'){result=VS_managedAttendanceBatch(b);}
    else if(b.action==='managed_summary'){result=VS_managedSummary();}
    else if(['managed_import_sheet_setup','managed_import_sheet_read'].indexOf(b.action)>=0){result=VS_importSheet(b);}
    else if(b.action==='managed_records_batch'){result=VS_managedRecordBatch(b);}
    else if(b.action==='managed_records'){result=VS_managedRecord(b);}
    else if(b.action==='managed_upload_resumable'){result=VS_managedResumableUpload(b);}
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
      'External Sheet edit requires review':'External Sheet edit requires review',
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
      'School record or ID card was changed; scan again':'School record or ID card was changed; scan again',
      'Student attendance is outside the school schedule':'Student attendance is outside the school schedule',
      'Today’s attendance is already recorded':'Today’s attendance is already recorded'
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
  const name='Layout
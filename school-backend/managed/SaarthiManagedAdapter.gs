/** Managed Windows storage adapter. Deploy as the SCHOOL account, not developer.
 * No Firebase project/key/password required. Run VS_setupManagedSchool once.
 * Existing legacy sheets/files remain untouched; do not rebind existing roots.
 */
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
  const expected = Utilities.computeHmacSha256Signature(school+'\n'+b.timestamp+'\n'+b.nonce+'\n'+b.payload, secret).map(v=>('0'+((v+256)%256).toString(16)).slice(-2)).join('');
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
  if (!['students_directory','teachers_directory','attendance_logs','teacher_attendance','attendance_records','teacher_schedules','school_notices','school_calendar','exam_results','teacher_salary','school_config','school_settings','fee_settings','fee_ledger','fee_payments','school_expenses','student_scan_index','scanner_devices','documents','backups','exams','exam_center_results'].includes(name)) throw new Error('Unknown collection');
  const root=VS_managedRoot(), folders=root.getFoldersByName('records_'+name);
  if(folders.hasNext()) {const folder=folders.next();if(folders.hasNext())throw new Error('Duplicate collection folders; operator review required');return folder;}
  return root.createFolder('records_'+name);
}
function VS_managedRecord(b) {
  const folder=VS_managedCollection(b.collection), school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID');
  if(b.operation==='read') {
    const files=folder.getFiles(),records={};let bytes=0;
    while(files.hasNext()){const raw=files.next().getBlob().getDataAsString();bytes+=raw.length;if(bytes>20*1024*1024)throw new Error('Collection export exceeds safe limit');const item=JSON.parse(raw);if(item.schoolId!==school)throw new Error('Foreign school record');records[item.id]=item.data;}
    return {records:records};
  }
  if(!/^[^/]{1,200}$/.test(b.id||'')||b.id==='.'||b.id==='..')throw new Error('Invalid record ID');
  const name=Utilities.base64EncodeWebSafe(b.id)+'.json', matches=folder.getFilesByName(name);let file=matches.hasNext()?matches.next():null;if(matches.hasNext())throw new Error('Duplicate record; operator review required');
  if(file&&b.createOnly===true)return {skipped:true};
  if(b.operation==='delete'){if(file)file.setTrashed(true);return {};}
  if(b.operation!=='write'||!b.data||b.data.schoolId!==school)throw new Error('Invalid school record');
  const text=JSON.stringify({id:b.id,schoolId:school,data:b.data});if(text.length>512*1024)throw new Error('Record too large; upload files separately');
  if(file)file.setContent(text);else folder.createFile(name,text,'application/json');return {};
}
function VS_managedFile(id) {
  const file=DriveApp.getFileById(id),root=VS_managedRoot().getId(),seen={};
  function own(folder){if(folder.getId()===root)return true;if(seen[folder.getId()])return false;seen[folder.getId()]=true;const parents=folder.getParents();while(parents.hasNext())if(own(parents.next()))return true;return false;}
  const parents=file.getParents();while(parents.hasNext())if(own(parents.next()))return file;throw new Error('Foreign school file');
}
function VS_managedHandle(e) {
  const school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID');
  try {
    const b=VS_managedVerify(e);let result;
    if(b.action==='managed_health'){VS_managedRoot();result={storageReady:true};}
    else if(b.action==='managed_records'){const lock=LockService.getScriptLock();lock.waitLock(30000);try{result=VS_managedRecord(b);}finally{lock.releaseLock();}}
    else if(b.action==='managed_upload'){
      if(!/^[-\w.+]+\/[-\w.+]+$/.test(b.mime||'')||typeof b.name!=='string'||b.name.length>200)throw new Error('Invalid file');const bytes=Utilities.base64Decode(b.base64);if(!bytes.length||bytes.length>20*1024*1024)throw new Error('File limit exceeded');
      const file=VS_managedRoot().createFile(Utilities.newBlob(bytes,b.mime,b.name));result={fileId:file.getId(),fileUrl:'https://drive.google.com/file/d/'+file.getId()+'/view'};
    }else if(b.action==='managed_file'){
      const blob=VS_managedFile(b.fileId).getBlob();if(blob.getBytes().length>20*1024*1024)throw new Error('File limit exceeded');result={mime:blob.getContentType(),base64:Utilities.base64Encode(blob.getBytes())};
    }else if(b.action==='managed_backup'){
      const root=VS_managedRoot(),folders=root.getFolders(),records={};while(folders.hasNext()){const f=folders.next();if(f.getName().indexOf('records_')===0)records[f.getName().slice(8)]=VS_managedRecord({collection:f.getName().slice(8),operation:'read'}).records;}
      const text=JSON.stringify({schemaVersion:3,schoolId:school,createdAt:new Date().toISOString(),records:records});if(text.length>20*1024*1024)throw new Error('Backup exceeds safe file limit');const file=root.createFile('School_Backup_'+Date.now()+'.json',text,'application/json');result={fileId:file.getId(),fileUrl:'https://drive.google.com/file/d/'+file.getId()+'/view'};
    }else if(b.action==='managed_restore'){
      const file=VS_managedFile(b.fileId),blob=file.getBlob();if(blob.getBytes().length>20*1024*1024)throw new Error('Backup too large');const backup=JSON.parse(blob.getDataAsString());
      if(backup.schemaVersion!==3||backup.schoolId!==school||!backup.records||typeof backup.records!=='object')throw new Error('Foreign or unsupported backup');
      const pending=[];Object.keys(backup.records).forEach(col=>{VS_managedCollection(col);Object.keys(backup.records[col]).forEach(id=>{const data=backup.records[col][id];if(!/^[^/]{1,200}$/.test(id)||id==='.'||id==='..'||!data||data.schoolId!==school)throw new Error('Invalid backup record');pending.push({collection:col,id:id,data:data,operation:'write',createOnly:true});});});
      let copied=0,skipped=0;const lock=LockService.getScriptLock();lock.waitLock(30000);try{pending.forEach(r=>{const result=VS_managedRecord(r);if(result.skipped)skipped++;else copied++;});}finally{lock.releaseLock();}result={copied:copied,skipped:skipped};
    }else throw new Error('Unknown managed storage action');
    return jsonResponse(Object.assign({success:true,schoolId:school},result));
  }catch(_){return jsonResponse({success:false,schoolId:school,message:'School storage request rejected'});}
}

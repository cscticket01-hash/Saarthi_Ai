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
  if (!['students_directory','teachers_directory','attendance_logs','teacher_attendance','attendance_records','teacher_schedules','school_notices','school_calendar','exam_results','teacher_salary','school_config','school_settings','fee_settings','fee_ledger','fee_payments','school_expenses','student_scan_index','scanner_devices','documents','backups','exams','exam_center_results','mobile_sessions','mobile_users','mobile_complaints'].includes(name)) throw new Error('Unknown collection');
  const root=VS_managedRoot(), folders=root.getFoldersByName('records_'+name);
  if(folders.hasNext()) {const folder=folders.next();if(folders.hasNext())throw new Error('Duplicate collection folders; operator review required');return folder;}
  return root.createFolder('records_'+name);
}
function VS_managedRecord(b) {
  const folder=VS_managedCollection(b.collection), school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID');
  if(b.operation==='read') {
    const revision=PropertiesService.getScriptProperties().getProperty('VS_RECORD_REV_'+b.collection)||'legacy';
    if(b.syncProtocol===2 && b.knownRevision===revision)return {records:{},unchanged:true,collectionRevision:revision,syncProtocol:2};
    const files=folder.getFiles(),records={};let bytes=0;
    while(files.hasNext()){const raw=files.next().getBlob().getDataAsString();bytes+=raw.length;if(bytes>20*1024*1024)throw new Error('Collection export exceeds safe limit');const item=JSON.parse(raw);if(item.schoolId!==school)throw new Error('Foreign school record');if(b.syncProtocol===2 || !item.data._syncDeleted)records[item.id]=item.data;}
    return {records:records,collectionRevision:revision,syncProtocol:2};
  }
  if(!/^[^/]{1,200}$/.test(b.id||'')||b.id==='.'||b.id==='..')throw new Error('Invalid record ID');
  const name=Utilities.base64EncodeWebSafe(b.id)+'.json', matches=folder.getFilesByName(name);let file=matches.hasNext()?matches.next():null;if(matches.hasNext())throw new Error('Duplicate record; operator review required');
  if(file&&b.createOnly===true)return {skipped:true};
  const existing=file?JSON.parse(file.getBlob().getDataAsString()):null;
  if(existing&&(existing.schoolId!==school||existing.id!==b.id))throw new Error('Foreign school record');
  if(b.syncProtocol!==2 && existing&&existing.data._syncOperationId)throw new Error('Record revision conflict');
  if(b.syncProtocol===2){
    if(!/^[A-Za-z0-9_-]{16,100}$/.test(b.operationId||'')||typeof b.expectedRecordRevision!=='string')throw new Error('Invalid sync operation');
    if(existing&&existing.data._syncOperationId===b.operationId)return {recordRevision:existing.data._syncRevision,syncProtocol:2};
    if((existing&&existing.data._syncRevision||'')!==b.expectedRecordRevision)throw new Error('Record revision conflict');
  }

  if(b.collection==='documents' && (b.expectedRevision!==undefined || file)) {
    const current=file?JSON.parse(file.getBlob().getDataAsString()):null;
    if(current&&(current.schoolId!==school||current.id!==b.id))throw new Error('Foreign document record');
    const revision=current&&current.data.documentRevision||'';
    if(b.expectedRevision!==undefined) {
      if(typeof b.expectedRevision!=='string'||b.expectedRevision!==revision ||
         (!revision&&current&&b.expectedUploadedAt!==undefined&&b.expectedUploadedAt!==current.data.uploadedAt))throw new Error('Newer cloud document retained; resolve version conflict');
    } else if(revision) throw new Error('Versioned document requires a matching revision');
  }
  if(b.operation==='write' && existing && existing.data._syncDeleted)throw new Error('Record revision conflict');
  if(b.operation==='delete'){
    if(b.syncProtocol===2 || b.collection==='documents'){
      const revision=Utilities.getUuid(),data={schoolId:school,_syncDeleted:true,_syncRevision:revision};
      if(b.syncProtocol===2)data._syncOperationId=b.operationId;
      if(b.collection==='documents' && existing)data.documentRevision=existing.data.documentRevision||'';
      const text=JSON.stringify({id:b.id,schoolId:school,data:data});
      if(file)file.setContent(text);else folder.createFile(name,text,'application/json');
      PropertiesService.getScriptProperties().setProperty('VS_RECORD_REV_'+b.collection,Utilities.getUuid());
      return {recordRevision:revision,syncProtocol:2};
    }
    if(file)file.setTrashed(true);
    PropertiesService.getScriptProperties().setProperty('VS_RECORD_REV_'+b.collection,Utilities.getUuid());return {};
  }
  if(b.operation!=='write'||!b.data||b.data.schoolId!==school)throw new Error('Invalid school record');
  const revision=Utilities.getUuid(),data=Object.assign({},b.data);
  delete data._syncDeleted;delete data._syncOperationId;delete data._syncRevision;
  data._syncRevision=revision;
  if(b.syncProtocol===2)data._syncOperationId=b.operationId;
  const text=JSON.stringify({id:b.id,schoolId:school,data:data});if(text.length>512*1024)throw new Error('Record too large; upload files separately');
  if(file)file.setContent(text);else folder.createFile(name,text,'application/json');PropertiesService.getScriptProperties().setProperty('VS_RECORD_REV_'+b.collection,Utilities.getUuid());return {recordRevision:revision,syncProtocol:2};
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
function VS_managedHandle(e) {
  const school=PropertiesService.getScriptProperties().getProperty('VS_MANAGED_SCHOOL_ID');
  try {
    const request=JSON.parse(e.postData.contents);
    if(request.action==='managed_connect')return VS_managedConnect(request);
    const b=VS_managedVerify(e);let result;
    if(b.action==='managed_health'){VS_managedRoot();result={storageReady:true,documentVersions:1,recordSyncVersion:2,googleEmail:typeof Session!=='undefined'?Session.getEffectiveUser().getEmail():''};}
    else if(b.action==='managed_mobile'){result=VS_managedMobile(b.request,b.lease);}
    else if(b.action==='managed_attendance_batch'){
      if(!Array.isArray(b.operations)||b.operations.length>25)throw new Error('Invalid attendance batch');
      result={acknowledgements:b.operations.map(op=>{
        if(!/^[a-f0-9]{64}$/.test(op.operationId||''))throw new Error('Invalid attendance operation');
        try{VS_managedMobile(Object.assign({},op.request,{action:'mobile_mark_attendance',operationId:op.operationId}),b.lease);return {operationId:op.operationId,success:true};}
        catch(e){const authoritative=/School (session expired|record or ID|licence|is closed)|already recorded|Check in before|Attendance can be marked|own school ID|Accurate school location/.test(e.message||'');return {operationId:op.operationId,success:false,authoritative:authoritative};}
      })};
    }
    else if(b.action==='managed_summary'){result=VS_managedSummary();}
    else if(b.action==='managed_records'){const lock=LockService.getScriptLock();lock.waitLock(30000);try{result=VS_managedRecord(b);}finally{lock.releaseLock();}}
    else if(b.action==='managed_upload'){
      if(!/^[-\w.+]+\/[-\w.+]+$/.test(b.mime||'')||typeof b.name!=='string'||b.name.length>200)throw new Error('Invalid file');const bytes=Utilities.base64Decode(b.base64);if(!bytes.length||bytes.length>20*1024*1024)throw new Error('File limit exceeded');
      const lock=LockService.getScriptLock();lock.waitLock(30000);
      try {
        const root=VS_managedRoot();let file=null,marker='';
        if(b.uploadKey!==undefined) {
          if(!/^[A-Za-z0-9_-]{1,150}$/.test(b.uploadKey))throw new Error('Invalid upload key');
          const digest=Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,bytes).map(v=>('0'+((v+256)%256).toString(16)).slice(-2)).join('');
          marker='VIDYA_UPLOAD:'+school+':'+b.uploadKey+':'+digest;
          const matches=root.getFilesByName(b.name);
          if(matches.hasNext()){file=matches.next();if(matches.hasNext()||file.getDescription()!==marker)throw new Error('Upload key collision; existing file retained');}
        }
        if(!file){file=root.createFile(Utilities.newBlob(bytes,b.mime,b.name));if(marker)file.setDescription(marker);}
        result={fileId:file.getId(),fileUrl:'https://drive.google.com/file/d/'+file.getId()+'/view'};
      } finally {lock.releaseLock();}

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
  }catch(error){
    const safe={
      'This QR does not belong to the active school':'This QR is invalid or has not synced to this school. Ask the school to sync or regenerate the ID card.',
      'Record revision conflict':'Record revision conflict',
      'This ID card needs a new secure school QR':'Ask your school to regenerate this ID card.',
      'Class, roll number or date of birth is incorrect':'Class, roll number or date of birth is incorrect',
      'School session expired':'School session expired. Scan your ID again.',
      'School record or ID card was changed; scan again':'School record or ID card was changed; scan again'
    };
    return jsonResponse({success:false,schoolId:school,message:safe[error.message]||'School storage request rejected'});
  }
}

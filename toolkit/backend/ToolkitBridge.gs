/** Only the generated, SEPARATE test-school backend contains this adapter.
 * The production doPost is copied unchanged apart from its function name.
 * Bulk traffic still calls the original mobile/legacy handlers.
 */
function VS_toolkitEnableTestMode() {
  const p = VS_project();
  if (!/(^|[-_])(test|lab)([-_]|$)/.test(p) || p === 'saarthi-ai-df12b')
    throw new Error('Use a separate Firebase project with test or lab in its ID');
  PropertiesService.getScriptProperties().setProperty('VS_TOOLKIT_TEST_ONLY', 'true');
  return {testOnly:true, projectId:p};
}

function doPost(e) {
  let body;
  try { body = JSON.parse(e.postData.contents); } catch (_) { return VS_toolkitOriginalDoPost(e); }
  if (!String(body.action || '').startsWith('toolkit_')) return VS_toolkitOriginalDoPost(e);
  try {
    if (PropertiesService.getScriptProperties().getProperty('VS_TOOLKIT_TEST_ONLY') !== 'true')
      throw new Error('Toolkit test mode is not enabled');
    VS_requireAdmin(body);
    const project = VS_project();
    if (!/(^|[-_])(test|lab)([-_]|$)/.test(project) || project === 'saarthi-ai-df12b')
      throw new Error('Production project blocked');
    const result = VS_toolkitAction(body);
    return jsonResponse(Object.assign({success:true, projectId:project}, result));
  } catch (error) {
    return jsonResponse({success:false, message:String(error.message || error)});
  }
}

function VS_toolkitAction(b) {
  if (b.action === 'toolkit_info') {
    let lease = {};
    try { lease = VS_platformStatus(); } catch (_) {}
    const identity = String(PropertiesService.getScriptProperties().getProperty('SAARTHI_SCHOOL_SYNC_ID') || '');
    return {testOnly:true, day:VS_day(), schoolOpen:VS_isOpen(VS_day()),
      location:VS_get('school_settings','school_location') || {},
      licenseAllowed:lease.allowed === true && Number(lease.expiresAt) > Date.now(), schoolSyncId:identity};
  }
  if (b.action === 'toolkit_seed') return VS_toolkitSeed(b.students);
  if (b.action === 'toolkit_verify_students') return VS_toolkitVerifyStudents(b.students);
  if (b.action === 'toolkit_audit_attendance') {
    if (!Array.isArray(b.personIds) || b.personIds.length > 100000 || !/^\d{4}-\d{2}-\d{2}$/.test(b.day)) throw new Error('Invalid audit selection');
    const selected = new Set(b.personIds), counts = {};
    VS_query('attendance_records','date',b.day).forEach(r => {
      if (selected.has(r.personId) && r.role === 'student') counts[r.personId] = (counts[r.personId] || 0) + 1;
    });
    return {duplicates:Object.keys(counts).reduce((n,k) => n + Math.max(0, counts[k] - 1), 0), auditedPeople:selected.size};
  }
  if (b.action === 'toolkit_verify_fees') return VS_toolkitVerifyFees(b.receipts);
  if (b.action === 'toolkit_volume_chunk') return VS_toolkitVolume(b);
  throw new Error('Unknown toolkit action');
}

function VS_toolkitProfiles(students) {
  if (!Array.isArray(students) || !students.length || students.length > 100) throw new Error('Use batches of 1–100 test students');
  return students.map(s => {
    const p = s.profile || {};
    if (!/^tk_[a-f0-9]{16}_\d{6}$/.test(String(s.personId || '')) ||
        !/^TEST /.test(String(p.name || '')) || p.mobileStableId !== s.personId ||
        !/^[a-f0-9]{64}$/.test(String(p.mobileLinkToken || '')) ||
        !/^\d+$/.test(String(p.rollNo || '')) || !/^\d{4}-\d{2}-\d{2}$/.test(String(p.dob || '')))
      throw new Error('Only matching synthetic toolkit identities may be seeded');
    const fields = {};
    ['name','class','rollNo','dob','dateOfBirth','parentName','studentUid','mobileStableId','mobileLinkToken'].forEach(k => {
      if (p[k] !== undefined) fields[k] = VS_encode(p[k]);
    });
    return {id:s.personId, profile:p, fields:fields};
  });
}

function VS_toolkitSeed(students) {
  const entries = VS_toolkitProfiles(students);
  const prefix = 'projects/' + VS_project() + '/databases/(default)/documents/students_directory/';
  VS_firestore('POST',':commit',{writes:entries.map(s => ({update:{name:prefix+s.id, fields:s.fields}}))});
  const lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    const sheet = getOrCreateDatabaseSheet(STUDENT_SHEET_NAME, STUDENT_HEADERS);
    const rows = sheet.getLastRow()>1 ? sheet.getRange(2,1,sheet.getLastRow()-1,STUDENT_HEADERS.length).getValues() : [];
    const existing = {};
    rows.forEach(r => existing[normalizeClass(r[2])+'/'+normalizeRoll(r[3])] = r);
    const append = [];
    entries.forEach(s => {
      const p = s.profile, key = normalizeClass(p.class)+'/'+normalizeRoll(p.rollNo), old = existing[key];
      if (old && (String(old[0]) !== p.name || VS_dob(old[12]) !== p.dob)) throw new Error('Test class/roll is occupied by a different record');
      if (!old) append.push([p.name,'TEST Guardian',p.class,String(p.rollNo),'','','','TEST ADDRESS','','','', '',p.dob,new Date()]);
    });
    if (append.length) {
      sheet.getRange(sheet.getLastRow()+1,4,append.length,1).setNumberFormat('@');
      sheet.getRange(sheet.getLastRow()+1,1,append.length,STUDENT_HEADERS.length).setValues(append);
    }
  } finally { lock.releaseLock(); }
  const saved = VS_firestore('POST',':batchGet',{documents:entries.map(s => prefix+s.id)}) || [];
  let verified = 0;
  saved.forEach(r => {
    if (!r.found) return;
    const id = r.found.name.split('/').pop(), expected = entries.find(s => s.id === id);
    const doc = VS_doc(r.found);
    if (expected && doc.mobileStableId === id && doc.mobileLinkToken === expected.profile.mobileLinkToken &&
        doc.name === expected.profile.name && doc.rollNo === expected.profile.rollNo && doc.class === expected.profile.class && doc.dob === expected.profile.dob) verified++;
  });
  const sheets = VS_toolkitVerifyStudents(entries.map(s => s.profile));
  if (sheets.matched !== entries.length) throw new Error('Sheet read-back verification failed');
  return {verified:verified, sheetsVerified:sheets.matched};
}

function VS_toolkitVerifyStudents(students) {
  if (!Array.isArray(students) || students.length > 500) throw new Error('Verify up to 500 students per call');
  const sheet = getOrCreateDatabaseSheet(STUDENT_SHEET_NAME, STUDENT_HEADERS);
  const rows = sheet.getLastRow()>1 ? sheet.getRange(2,1,sheet.getLastRow()-1,STUDENT_HEADERS.length).getValues() : [];
  const found = {};
  rows.forEach(r => {
    const key = normalizeClass(r[2])+'/'+normalizeRoll(r[3]);
    if (!found[key]) found[key] = [];
    found[key].push(r);
  });
  let matched = 0;
  students.forEach(s => {
    const entries = found[normalizeClass(s.class)+'/'+normalizeRoll(s.rollNo)] || [];
    if (entries.length === 1 && String(entries[0][0]) === s.name && VS_dob(entries[0][12]) === s.dob) matched++;
  });
  return {matched:matched};
}

function VS_toolkitVerifyFees(receipts) {
  if (!Array.isArray(receipts) || receipts.length > 500 || receipts.some(r => !/^TK_[a-f0-9]{16}_\d+$/.test(r))) throw new Error('Invalid test receipt selection');
  const sheet = getOrCreateDatabaseSheet(FEE_SHEET_NAME, FEE_HEADERS);
  const headers = FEE_HEADERS;
  const receiptIndex = headers.indexOf('Receipt No');
  const amountIndex = headers.indexOf('Total Paid');
  if (receiptIndex < 0 || amountIndex < 0) throw new Error('Fee schema is not supported by this toolkit adapter');
  const rows = sheet.getLastRow()>1 ? sheet.getRange(2,1,sheet.getLastRow()-1,headers.length).getValues() : [];
  const selected = new Set(receipts), counts = {}, amounts = {};
  rows.forEach(r => {
    const id = String(r[receiptIndex]);
    if (selected.has(id)) { counts[id]=(counts[id]||0)+1; amounts[id]=(amounts[id]||0)+Number(r[amountIndex]||0); }
  });
  return {matched:Object.keys(counts).length,
    duplicates:Object.keys(counts).reduce((n,k)=>n+Math.max(0,counts[k]-1),0),
    paidAmount:Object.keys(amounts).reduce((n,k)=>n+amounts[k],0)};
}

function VS_toolkitVolume(b) {
  if (!/^[a-f0-9]{16}$/.test(String(b.runId)) || !Number.isInteger(b.part) || b.part<0 || b.part>=10000) throw new Error('Invalid volume run');
  const bytes = Utilities.base64Decode(String(b.data||''));
  if (bytes.length < 1 || bytes.length > 1000000) throw new Error('Use chunks of up to 1 MB');
  const props=PropertiesService.getScriptProperties(), key='VS_TOOLKIT_VOLUME_'+b.runId;
  const lock=LockService.getScriptLock(); lock.waitLock(30000);
  let folder;
  try {
    const previous=props.getProperty(key);
    if (previous) folder=DriveApp.getFolderById(previous);
    else { folder=VS_schoolDriveRoot(true).createFolder('Toolkit_Volume_'+b.runId); props.setProperty(key,folder.getId()); }
  } finally { lock.releaseLock(); }
  const file=folder.createFile(Utilities.newBlob(bytes,'application/octet-stream','part-'+b.part+'.bin'));
  const readBack=file.getBlob().getBytes();
  const sha=Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256,readBack).map(v=>('0'+((v+256)%256).toString(16)).slice(-2)).join('');
  return {fileId:file.getId(), bytes:readBack.length, sha256:sha};
}

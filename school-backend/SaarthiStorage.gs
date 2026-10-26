/** School-owned Google storage. Never search the account's entire Drive by name. */
function VS_schoolDriveRoot(allowUnprepared) {
  const props = PropertiesService.getScriptProperties();
  const id = props.getProperty('VS_DRIVE_ROOT_ID');
  if (!id) throw new Error('Run VS_setupSchool before using school Google storage');
  const root = DriveApp.getFolderById(id);
  if (root.getDescription() !== 'SAARTHI_SCHOOL_PROJECT:' + VS_project()) {
    throw new Error('Google storage belongs to a different school');
  }
  if (!allowUnprepared && props.getProperty('VS_STORAGE_READY') !== 'true') {
    throw new Error('School owner must migrate existing files with VS_prepareSchoolStorage, or explicitly confirm an empty new school');
  }
  return root;
}

// Run from the Script editor as the school owner, never through the web router.
// Supply EXACT IDs of this school's legacy spreadsheets and top-level folders.
// Existing data is moved, never deleted or selected by an account-wide name.
function VS_prepareSchoolStorage(options) {
  options = options || {};
  const root = VS_schoolDriveRoot(true);
  const files = options.fileIds || [], folders = options.folderIds || [];
  if (!Array.isArray(files) || !Array.isArray(folders)) throw new Error('Supply arrays of exact Drive IDs');
  if (!files.length && !folders.length && options.startEmpty !== true) {
    throw new Error('Supply existing school file/folder IDs, or set startEmpty:true only for a new empty school');
  }
  const items = files.map(id => DriveApp.getFileById(String(id)))
    .concat(folders.map(id => DriveApp.getFolderById(String(id))));
  // Validate the entire selection before moving any file.
  items.forEach(item => VS_assertNoForeignSchoolParent(item));
  items.forEach(item => item.moveTo(root));
  PropertiesService.getScriptProperties().setProperty('VS_STORAGE_READY', 'true');
  return {projectId: VS_project(), rootFolderId: root.getId(), moved: items.length};
}

function VS_assertNoForeignSchoolParent(item) {
  const expected = 'SAARTHI_SCHOOL_PROJECT:' + VS_project();
  const seen = {};
  function visit(folder) {
    if (seen[folder.getId()]) return;
    seen[folder.getId()] = true;
    const tag = String(folder.getDescription() || '');
    if (tag.indexOf('SAARTHI_SCHOOL_PROJECT:') === 0 && tag !== expected) {
      throw new Error('Drive item belongs to another school; migration refused');
    }
    const parents = folder.getParents();
    while (parents.hasNext()) visit(parents.next());
  }
  if (typeof item.getDescription === 'function') {
    const tag = String(item.getDescription() || '');
    if (tag.indexOf('SAARTHI_SCHOOL_PROJECT:') === 0 && tag !== expected) {
      throw new Error('Drive folder belongs to another school; migration refused');
    }
  }
  const parents = item.getParents();
  while (parents.hasNext()) visit(parents.next());
}

function VS_schoolFile(fileId) {
  const file = DriveApp.getFileById(String(fileId));
  const rootId = VS_schoolDriveRoot().getId(), seen = {};
  function within(folder) {
    if (folder.getId() === rootId) return true;
    if (seen[folder.getId()]) return false;
    seen[folder.getId()] = true;
    const parents = folder.getParents();
    while (parents.hasNext()) if (within(parents.next())) return true;
    return false;
  }
  const parents = file.getParents();
  while (parents.hasNext()) if (within(parents.next())) return file;
  throw new Error('This Drive file does not belong to the configured school');
}

function VS_schoolSyncGuard(b) {
  if (['sync_identity_get', 'sync_identity_claim', 'health_check', 'ping'].indexOf(b.action) >= 0) return;
  const supplied = String(b._windowsSchoolSyncId || '').trim();
  const actual = String(PropertiesService.getScriptProperties().getProperty('SAARTHI_SCHOOL_SYNC_ID') || '').trim();
  if (supplied && supplied !== actual) throw new Error('Windows School Sync ID mismatch');
  // Also protects snapshots from silently returning an empty unmigrated school.
  VS_schoolDriveRoot();
}

function VS_mobileSchoolProfile() {
  const p = getSchoolProfileDataObject();
  const out = {};
  ['schoolName', 'principalName', 'schoolContactNo', 'latitude', 'longitude',
    'attendanceRadiusMeters'].forEach(k => { if (p[k] !== undefined) out[k] = p[k]; });
  return out;
}

function VS_personPhotoUrl(person, role) {
  if (role === 'student') {
    const sheet = getOrCreateDatabaseSheet(STUDENT_SHEET_NAME, STUDENT_HEADERS);
    const row = findStudentRow(sheet, person.class, person.rollNo);
    if (row < 2) return '';
    const values = sheet.getRange(row, 1, 1, STUDENT_HEADERS.length).getValues()[0];
    if (String(values[0] || '').trim().toLowerCase() !== String(person.name || '').trim().toLowerCase() ||
        VS_dob(values[STUDENT_HEADERS.indexOf('Date of Birth')]) !== VS_dob(person.dob || person.dateOfBirth)) return '';
    return String(values[STUDENT_HEADERS.indexOf('Photo URL')] || '');
  }
  const sheet = getOrCreateDatabaseSheet(TEACHER_SHEET_NAME, TEACHER_HEADERS);
  const row = findTeacherRow(sheet, person.teacherId || person.id, '');
  if (row < 2) return '';
  const values = sheet.getRange(row, 1, 1, TEACHER_HEADERS.length).getValues()[0];
  if (String(values[1] || '').trim().toLowerCase() !== String(person.name || '').trim().toLowerCase()) return '';
  return String(values[TEACHER_HEADERS.indexOf('Photo URL')] || '');
}

// The caller selects a kind, never a file ID, URL or another person's ID.
// Bytes come from this school's Google Drive, not Firestore.
function VS_mobileAsset(b, session) {
  let fileId = '';
  if (b.kind === 'photo') {
    const url = VS_personPhotoUrl(session.person, session.role);
    const match = url.match(/(?:googleusercontent\.com\/d\/|[?&]id=|\/file\/d\/)([A-Za-z0-9_-]+)/);
    fileId = match ? match[1] : '';
  } else if (b.kind === 'logo') {
    fileId = String(getSchoolProfileDataObject().logoFileId || '');
  } else throw new Error('Unsupported school asset');
  if (!fileId) return {available: false};
  const blob = VS_schoolFile(fileId).getBlob();
  if (!/^image\//.test(blob.getContentType()) || blob.getBytes().length > 2 * 1024 * 1024) {
    throw new Error('School image must be at most 2 MB');
  }
  return {available: true, mimeType: blob.getContentType(), base64: Utilities.base64Encode(blob.getBytes())};
}

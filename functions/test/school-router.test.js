'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {drive, school} = require('./helpers/school-backend');

test('the supplied full doPost denies anonymous legacy read/write/identity requests', () => {
  const s = school(); s.prepare();
  for (const action of ['windows_sync_snapshot', 'windows_sync_text_snapshot', 'list_fee_payments',
    'add_student', 'delete_teacher', 'save_school_profile', 'sync_identity_get', 'sync_identity_claim']) {
    const result = s.post({action, schoolSyncId: 'attacker'});
    assert.equal(result.success, false, action);
    assert.match(result.message, /administrator login/);
  }
  assert.equal(s.properties.get('SAARTHI_SCHOOL_SYNC_ID'), undefined);
});
test('a valid signed school-admin proof reaches the existing identity router', () => {
  const s = school();
  const result = s.post({action: 'sync_identity_get', ...s.proof()});
  assert.equal(result.success, true);
  assert.equal(result.projectId, 'school-one');
  assert.ok(s.requests.some(r => r.url.includes('accounts:lookup')));
});
test('foreign, expired, non-admin, revoked and forged administrator proofs are rejected', () => {
  for (const changes of [{aud: 'school-two'}, {iss: 'https://securetoken.google.com/school-two'},
    {exp: 1}, {admin: false, role: 'student'}]) {
    const s = school();
    assert.equal(s.post({action: 'sync_identity_claim', schoolSyncId: 'other', schoolProjectId: 'school-one', schoolAdminIdToken: s.token(changes)}).success, false);
  }
  const s = school();
  const forged = s.token().replace('registered-signature', 'forged-signature');
  const denied = s.post({action: 'sync_identity_get', schoolProjectId: 'school-one', schoolAdminIdToken: forged});
  assert.equal(denied.success, false);
  assert.match(denied.message, /verification failed/);
  const revoked = s.token(); s.acceptedTokens.get(revoked).validSince = Math.floor(Date.now() / 1000) + 1;
  assert.equal(s.post({action: 'sync_identity_get', schoolProjectId: 'school-one', schoolAdminIdToken: revoked}).success, false);
});
test('an unmigrated school is blocked before a sync snapshot can replace existing data', () => {
  const s = school();
  const result = s.post({action: 'windows_sync_snapshot', ...s.proof()});
  assert.equal(result.success, false);
  assert.match(result.message, /migrate existing files/);
  assert.equal(result.students, undefined);
  assert.throws(() => s.context.VS_prepareSchoolStorage({}), /existing school/);
});
test('two schools on one Google account get separate equally named sheets and folders', () => {
  const world = drive(), a = school('school-one', world), b = school('school-two', world);
  a.prepare(); b.prepare();
  const first = a.context.getOrCreateDatabaseSheet('School_Student_Database', ['Name']);
  first.getRange(2, 1, 1, 1).setValues([['School A pupil']]);
  const second = b.context.getOrCreateDatabaseSheet('School_Student_Database', ['Name']);
  assert.notEqual(first, second);
  assert.equal(second.getLastRow(), 1);
  assert.equal(a.context.getOrCreateDatabaseSheet('School_Student_Database', ['Name']).rows[1][0], 'School A pupil');
  assert.notEqual(a.context.getOrCreateFolder('School_Student_Photos').getId(), b.context.getOrCreateFolder('School_Student_Photos').getId());
  assert.throws(() => a.context.VS_setupSchool('school-two', 'AIza' + 'a'.repeat(33)), /rebinding/);
});
test('explicit legacy migration preserves data and cannot adopt another school folder or file', () => {
  const world = drive(), a = school('school-one', world), b = school('school-two', world);
  const file = world.sheetFile('School_Student_Database', world.globalRoot);
  file.sheet.rows = [['Name'], ['Existing pupil']];
  a.context.VS_prepareSchoolStorage({fileIds: [file.id]});
  assert.equal(a.context.getOrCreateDatabaseSheet('School_Student_Database', ['Name']).rows[1][0], 'Existing pupil');
  assert.throws(() => b.context.VS_prepareSchoolStorage({fileIds: [file.id]}), /another school/);
  assert.throws(() => b.context.VS_prepareSchoolStorage({folderIds: [a.context.VS_schoolDriveRoot().getId()]}), /another school/);
  b.prepare(); assert.throws(() => b.context.VS_schoolFile(file.id), /does not belong/);
});
test('Windows promotion cannot bypass the school sync guard and closed-day legacy attendance is blocked', () => {
  const s = school(); s.prepare();
  s.context.VS_changeStudentClass = () => {throw Error('Must never execute');};
  const denied = s.post({action: 'change_student_class', newRollNo: '13', _windowsSchoolSyncId: 'foreign', ...s.proof()});
  assert.equal(denied.success, false); assert.match(denied.message, /Sync ID mismatch/);
  s.context.VS_isOpen = () => false;
  for (const action of ['mark_attendance', 'mark_student_attendance', 'mark_teacher_attendance']) {
    const result = s.post({action, ...s.proof()});
    assert.equal(result.success, false); assert.match(result.message, /closed today/);
  }
});
test('script-owner Firestore writes remove nested media even though IAM bypasses client rules', () => {
  const s = school(); let payload;
  s.context.VS_firestore = (method, path, data) => {payload = data; return null;};
  s.context.VS_set('exam_results', 'one', {name: 'Pupil', reportCardUrl: 'media', mobileLinkToken: 'qr',
    nested: {logoFileId: 'media', marks: 45}, subjects: [{fileUrl: 'media', name: 'Math'}]});
  assert.equal(payload.fields.reportCardUrl, undefined);
  assert.equal(payload.fields.nested.mapValue.fields.logoFileId, undefined);
  assert.equal(payload.fields.nested.mapValue.fields.marks.integerValue, '45');
  assert.equal(payload.fields.mobileLinkToken.stringValue, 'qr');
  assert.equal(payload.fields.subjects.arrayValue.values[0].mapValue.fields.fileUrl, undefined);
});
test('mobile photo retrieval uses the verified pupil sheet and ignores arbitrary IDs from the request', () => {
  const s = school(); s.prepare();
  const person = {id: 'Class 5_Roll_12', name: 'Own pupil', class: 'Class 5', rollNo: '12', dob: '15/03/2015'};
  const sheet = s.context.getOrCreateDatabaseSheet('School_Student_Database',
    ['Name', 'Parent Name', 'Class', 'Roll No', 'Contact', 'Photo URL', 'Hostel Facility', 'Address', 'District', 'State', 'PIN Code', 'Joining Date', 'Date of Birth', 'Timestamp']);
  const ownPhoto = s.world.sheetFile('photo', s.context.VS_schoolDriveRoot());
  sheet.rows.push(['Own pupil', 'Parent', 'Class 5', '12', '', 'https://lh3.googleusercontent.com/d/' + ownPhoto.id, '', '', '', '', '', '', '15/03/2015', '']);
  const result = s.context.VS_mobileAsset({kind: 'photo', personId: 'other', fileId: 'foreign'}, {role: 'student', person});
  assert.equal(result.available, true);
  assert.equal(Buffer.from(result.base64, 'base64').toString(), 'own-photo');
  assert.equal(s.context.VS_mobileAsset({kind: 'photo'}, {role: 'student', person: {...person, name: 'Other pupil'}}).available, false);
});
test('a mobile session is required before any photo or logo action', () => {
  const s = school();
  s.context.VS_get = () => null;
  assert.equal(s.post({action: 'mobile_asset', projectId: 'school-one', kind: 'photo'}).success, false);
});

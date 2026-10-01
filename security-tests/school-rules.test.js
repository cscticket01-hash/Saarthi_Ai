'use strict';
const {before, after, beforeEach, test} = require('node:test');
const {readFileSync} = require('node:fs');
const {initializeTestEnvironment, assertFails, assertSucceeds} = require('@firebase/rules-unit-testing');
const {doc, setDoc, getDoc, getDocs, collection, updateDoc, deleteDoc, deleteField} = require('firebase/firestore');
const rules = readFileSync('../school-backend/firestore.school.rules', 'utf8');
let env, other;
before(async () => {
  env = await initializeTestEnvironment({projectId: 'demo-saarthi-school', firestore: {rules}});
  other = await initializeTestEnvironment({projectId: 'demo-saarthi-other', firestore: {rules}});
});
after(async () => { await env?.cleanup(); await other?.cleanup(); });
beforeEach(async () => { await env.clearFirestore(); await other.clearFirestore(); });
const admin = () => env.authenticatedContext('owner', {admin: true}).firestore();
async function seed(path, data) {
  await env.withSecurityRulesDisabled(ctx => setDoc(doc(ctx.firestore(), path), data));
}
test('anonymous, anonymous-auth and ordinary users cannot read or change school records', async () => {
  await seed('students_directory/pupil', {name: 'Private pupil', parentContact: '9999999999'});
  await seed('school_notices/one', {title: 'Private school notice'});
  for (const db of [env.unauthenticatedContext().firestore(),
    env.authenticatedContext('ordinary').firestore(),
    env.authenticatedContext('anonymous', {firebase: {sign_in_provider: 'anonymous'}}).firestore(),
    env.authenticatedContext('student', {role: 'student'}).firestore()]) {
    await assertFails(getDoc(doc(db, 'students_directory/pupil')));
    await assertFails(getDocs(collection(db, 'students_directory')));
    await assertFails(getDoc(doc(db, 'school_notices/one')));
    await assertFails(updateDoc(doc(db, 'students_directory/pupil'), {parentContact: '8888888888', updatedAt: 1}));
    await assertFails(setDoc(doc(db, 'teachers_directory/new'), {name: 'Intruder'}));
  }
});
test('explicit school administrators can sync all existing and new operational collections', async () => {
  const db = admin();
  for (const col of ['students_directory', 'teachers_directory', 'school_config', 'student_scan_index',
    'scanner_devices', 'attendance_logs', 'teacher_attendance', 'teacher_schedules', 'school_settings',
    'fee_settings', 'fee_ledger', 'fee_payments', 'school_calendar', 'attendance_records', 'exam_results', 'teacher_salary']) {
    const ref = doc(db, col + '/record');
    await assertSucceeds(setDoc(ref, {name: 'Own record', amount: 0, isOpen: false}));
    await assertSucceeds(getDoc(ref));
    await assertSucceeds(updateDoc(ref, {name: 'Updated own record'}));
    await assertSucceeds(deleteDoc(ref));
  }
  const roleAdmin = env.authenticatedContext('role-owner', {role: 'admin'}).firestore();
  await assertSucceeds(setDoc(doc(roleAdmin, 'school_settings/calendar'), {closedWeekdays: [0]}));
});
test('notice schema and append-only audit protection remain enforced', async () => {
  const db = admin();
  const ref = doc(db, 'school_notices/one');
  await assertSucceeds(setDoc(ref, {title: 'Exam', description: 'Own school', category: 'General', timestamp: 1, lastEdited: 1}));
  await assertFails(updateDoc(ref, {fileUrl: 'media'}));
  const audit = doc(db, 'audit_logs/one');
  await assertSucceeds(setDoc(audit, {action: 'Promotion'}));
  await assertFails(updateDoc(audit, {action: 'Rewrite'}));
  await assertFails(deleteDoc(audit));
});
test('media additions and changes are denied while legacy cleanup is allowed', async () => {
  const db = admin();
  const keys = ['photoUrl', 'photoBase64', 'idCardUrl', 'logoFileId', 'logoUrl', 'sealUrl',
    'principalSignatureFileId', 'reportCardUrl', 'receiptPdfUrl', 'pdfBase64', 'fileId', 'driveUrl', 'sheetUrl'];
  for (const col of ['students_directory', 'school_settings', 'exam_results', 'attendance_records', 'teacher_salary']) {
    for (const key of keys) await assertFails(setDoc(doc(db, col + '/bad-' + key), {name: 'Pupil', [key]: 'media'}));
  }
  await seed('students_directory/legacy', {name: 'Pupil', photoUrl: 'legacy-drive-url'});
  const ref = doc(db, 'students_directory/legacy');
  await assertSucceeds(updateDoc(ref, {name: 'Updated name'}));
  await assertFails(updateDoc(ref, {photoUrl: 'new-url'}));
  await assertFails(updateDoc(ref, {fileId: 'new-file'}));
  await assertSucceeds(updateDoc(ref, {photoUrl: deleteField()}));
});
test('mobile session secrets and unlisted/nested collections are client-denied even to an admin', async () => {
  for (const path of ['mobile_sessions/session-secret', 'users/owner', 'students_directory/pupil/private/secret', 'unknown/record']) {
    await seed(path, {secret: 'Private'});
    await assertFails(getDoc(doc(admin(), path)));
    await assertFails(setDoc(doc(admin(), path), {secret: 'Changed'}));
  }
});
test('only trusted update metadata remains public and cannot be client-written', async () => {
  await seed('app_config/android_update', {version: 'review'});
  await assertSucceeds(getDoc(doc(env.unauthenticatedContext().firestore(), 'app_config/android_update')));
  await assertFails(setDoc(doc(admin(), 'app_config/android_update'), {version: 'tampered'}));
  await assertFails(setDoc(doc(admin(), 'app_config/windows_update'), {version: 'tampered'}));
});
test('two Firebase projects keep identically named school documents separate', async () => {
  const a = admin(), b = other.authenticatedContext('owner-b', {admin: true}).firestore();
  await assertSucceeds(setDoc(doc(a, 'students_directory/pupil'), {name: 'School A only'}));
  await assertSucceeds(setDoc(doc(b, 'students_directory/pupil'), {name: 'School B only'}));
  const assert = require('node:assert/strict');
  assert.equal((await getDoc(doc(a, 'students_directory/pupil'))).data().name, 'School A only');
  assert.equal((await getDoc(doc(b, 'students_directory/pupil'))).data().name, 'School B only');
});

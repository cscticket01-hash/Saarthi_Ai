import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../lib/windows_local_firestore.dart';
import '../lib/windows_local_storage.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_connect/central_school_cloud.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = FirebaseFirestore.instance;
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      id = 'Class 1_Roll_1',
      old = 'p-old',
      fresh = 'p-new';
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      CentralSchoolCloud.key: jsonEncode({'managed': true, 'schoolId': school}),
    });
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    if (WindowsLocalStorage.sqliteEnabled)
      await db.changeLocalStorageLocation(
        (await Directory.systemTemp.createTemp('student-life-sql-')).path,
      );
    await db.switchProfile(
      'student-life-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolSyncId': school, 'schoolId': school},
    );
  });
  test('offline student delete removes linked records and re-add retains explicit old-generation deletion evidence', () async {
    final ref = db.collection('students_directory').doc(id);
    await ref.set({
      'schoolId': school,
      'mobileStableId': old,
      'name': 'Old pupil',
      'class': 'Class 1',
      'rollNo': '1',
    });
    await db.collection('fee_payments').doc('old-fee').set({
      'schoolId': school,
      'studentId': id,
      'personId': old,
      'amount': 500,
    });
    await db.collection('fee_payments').doc('other').set({
      'schoolId': school,
      'studentId': 'other',
      'personId': 'other-person',
      'amount': 600,
    });
    await ref.delete();
    expect(
      (await db.collection('fee_payments').doc('old-fee').get()).exists,
      false,
    );
    expect(
      (await db.collection('fee_payments').doc('other').get()).exists,
      true,
    );
    final deleted = (await db.collection('_windows_firebase_outbox').get()).docs
        .where((d) => d.data()['collection'] == 'students_directory')
        .single
        .data();
    expect(deleted['deletedStudentGeneration'], old);
    await ref.set({
      'schoolId': school,
      'mobileStableId': fresh,
      'name': 'New pupil',
      'class': 'Class 1',
      'rollNo': '1',
    });
    final pending = (await db.collection('_windows_firebase_outbox').get()).docs
        .where((d) => d.data()['collection'] == 'students_directory')
        .single;
    expect(pending.data()['data']['replacesStudentGeneration'], old);
    final profile = db.activeProfileId;
    await db.resetVolatileSession();
    await db.switchProfile(
      profile,
      identity: {'schoolSyncId': school, 'schoolId': school},
    );
    expect((await ref.get()).data()?['mobileStableId'], fresh);
    await db.applyVerifiedStudentDeletion(
      school,
      id,
      old,
      'verified-delete-revision',
    );
    expect((await ref.get()).data()?['name'], 'New pupil');
    expect(
      (await db.collection('_windows_firebase_outbox').get()).docs.any(
        (d) => d.data()['operationId'] == pending.data()['operationId'],
      ),
      true,
    );
    final marker = (await db.collection('_windows_local_deletions').get())
        .docs
        .single
        .data();
    expect(marker['snapshot'], {'mobileStableId': old});
    expect(marker['studentPayloadPurged'], true);
  });
  test('cloud deletion purges old pending edits and private payloads, without crossing schools', () async {
    await db.collection('students_directory').doc(id).set({
      'schoolId': school,
      'mobileStableId': old,
      'name': 'Old',
    });
    await db.collection('exam_results').doc('old-exam').set({
      'schoolId': school,
      'studentId': id,
      'personId': old,
      'marks': 99,
    });
    await db.applyVerifiedStudentDeletion(
      school,
      id,
      old,
      'verified-cloud-deletion',
    );
    expect(
      (await db.collection('students_directory').doc(id).get()).exists,
      false,
    );
    expect(
      (await db.collection('exam_results').doc('old-exam').get()).exists,
      false,
    );
    expect(
      (await db.collection('_windows_firebase_outbox').get()).docs,
      isEmpty,
    );
    await expectLater(
      db.applyVerifiedStudentDeletion('other', id, old, 'x'),
      throwsStateError,
    );
  });
}

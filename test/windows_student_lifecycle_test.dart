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
      CentralSchoolCloud.key: jsonEncode({
        'managed': true,
        'schoolId': school,
        'uid': 'synthetic-school',
        'projectId': 'saarthi-ai-df12b',
        'endpoint': 'https://unreachable.example/school-cloud',
        'folderId': 'managed',
        'firebaseRefreshToken': 'synthetic-refresh',
        'email': 'synthetic@example.com',
      }),
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
      'uid': 'synthetic-school',
      'projectId': 'saarthi-ai-df12b',
      'endpoint': 'https://unreachable.example/school-cloud',
      'folderId': 'managed',
      'firebaseRefreshToken': 'synthetic-refresh',
      'email': 'synthetic@example.com',
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
  test('verified cleanup deletes app copies only inside the active profile, preserving foreign profiles and picked originals', () async {
    final root = await WindowsLocalStorage.localFilesDirectory(),
        profile = db.activeProfileId;
    final own = File(
      '${root.path}${Platform.pathSeparator}$profile${Platform.pathSeparator}owned.pdf',
    );
    final foreign = File(
      '${root.path}${Platform.pathSeparator}other-school${Platform.pathSeparator}foreign.pdf',
    );
    final originals = await Directory.systemTemp.createTemp('picked-original-');
    final original = File(
      '${originals.path}${Platform.pathSeparator}source.pdf',
    );
    for (final file in [own, foreign, original]) {
      await file.parent.create(recursive: true);
      await file.writeAsString('synthetic bytes');
    }
    await db.collection('students_directory').doc(id).set({
      'schoolId': school,
      'mobileStableId': old,
      'name': 'Old',
    });
    for (final entry in {
      'owned': own,
      'foreign-path': foreign,
      'picked': original,
    }.entries) {
      await db.collection('_local_student_documents').doc(entry.key).set({
        'schoolId': school,
        'studentId': id,
        'personId': old,
        'localPath': entry.value.path,
      });
    }
    await db.applyVerifiedStudentDeletion(school, id, old, 'verified-delete');
    expect(await own.exists(), false);
    expect(await foreign.exists(), true);
    expect(await original.exists(), true);
    expect(
      (await db.collection('_windows_student_file_cleanup').get()).docs,
      isEmpty,
    );
    // Replay after reopening must remain idempotent on the committed SQLite
    // generation, and must not resurrect the retired cleanup intent.
    await db.resetVolatileSession();
    await db.switchProfile(
      profile,
      identity: {'schoolSyncId': school, 'schoolId': school},
    );
    await db.applyVerifiedStudentDeletion(school, id, old, 'verified-delete');
    expect(await foreign.exists(), true);
    expect(await original.exists(), true);
    expect(
      (await db.collection('_windows_student_file_cleanup').get()).docs,
      isEmpty,
    );
    await originals.delete(recursive: true);
    await foreign.delete();
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../lib/windows_id_card_record_lookup.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final db = FirebaseFirestore.instance;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(true);
    final dir = await Directory.systemTemp.createTemp('id-lookup-');
    await db.changeLocalStorageLocation(dir.path);
    await db.switchProfile(
      dir.path,
      identity: {'schoolSyncId': school, 'schoolId': school},
    );
  });
  tearDown(() async => db.resetVolatileSession());

  test('resolves legacy 01 document from requested roll 1', () async {
    await db.collection('students_directory').doc('Class 1_Roll_01').set({
      'schoolId': school,
      'class': 'Class 1',
      'rollNo': '01',
      'name': 'Sample',
    });
    final found = await WindowsIdCardRecordLookup.find(
      schoolClass: 'Class 1',
      roll: '1',
    );
    expect(found?.id, 'Class 1_Roll_01');
    expect(found?.data['name'], 'Sample');
  });

  test('prefer verified record ID even with alternate roll formatting', () async {
    await db.collection('students_directory').doc('student-legacy-abc').set({
      'schoolId': school,
      'class': 'Class 2',
      'rollNo': '0001',
      'name': 'Sample',
    });
    final found = await WindowsIdCardRecordLookup.find(
      schoolClass: 'Class 2',
      roll: '01',
      preferredId: 'student-legacy-abc',
    );
    expect(found?.id, 'student-legacy-abc');
  });

  test('foreign and deleted records are never exposed', () async {
    await db.collection('students_directory').doc('Class 1_Roll_01').set({
      'schoolId': 'vs-foreign',
      'class': 'Class 1',
      'rollNo': '01',
      'name': 'Other School',
    });
    expect(await WindowsIdCardRecordLookup.find(
      schoolClass: 'Class 1', roll: '1'), isNull);
    await db.collection('students_directory').doc('Class 1_Roll_01').set({
      'schoolId': school,
      'class': 'Class 1',
      'rollNo': '01',
      'name': 'Deleted',
      '_syncDeleted': true,
    });
    expect(await WindowsIdCardRecordLookup.find(
      schoolClass: 'Class 1', roll: '1'), isNull);
  });

  test('ambiguous duplicate noncanonical IDs are rejected', () async {
    for (final id in ['legacy-a', 'legacy-b']) {
      await db.collection('students_directory').doc(id).set({
        'schoolId': school,
        'class': 'Class 3',
        'rollNo': '1',
        'name': id,
      });
    }
    await expectLater(
      WindowsIdCardRecordLookup.find(schoolClass: 'Class 3', roll: '01'),
      throwsStateError,
    );
  });
}

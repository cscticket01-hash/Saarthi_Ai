import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../lib/windows_sheet_recovery.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_local_storage.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_connect/central_school_cloud.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = FirebaseFirestore.instance;
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      collection = 'students_directory',
      id = 'Class 1_Roll_1';
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
        (await Directory.systemTemp.createTemp('sheet-recovery-sql-')).path,
      );
    await db.switchProfile(
      'sheet-recovery-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolSyncId': school, 'schoolId': school},
    );
  });
  test('recovery sends exact cached cloud record while a newer edit remains queued after reopen', () async {
    final original = {
      'schoolId': school,
      'uid': 'synthetic-school',
      'projectId': 'saarthi-ai-df12b',
      'endpoint': 'https://unreachable.example/school-cloud',
      'folderId': 'managed',
      'firebaseRefreshToken': 'synthetic-refresh',
      'email': 'synthetic@example.com',
      'name': 'Verified',
      'mobileStableId': 'p-old',
      '_syncRevision': 'cloud-revision',
    };
    await cacheVerifiedSheetRecord(school, collection, id, original);
    await db.collection(collection).doc(id).set({
      'schoolId': school,
      'name': 'New offline edit',
    });
    final pending = (await db.collection('_windows_firebase_outbox').get())
        .docs
        .single
        .data();
    final profile = db.activeProfileId;
    await db.resetVolatileSession();
    await db.switchProfile(
      profile,
      identity: {'schoolSyncId': school, 'schoolId': school},
    );
    var calls = 0;
    expect(
      await recoverMissingSheetRecords(
        school,
        collection,
        [
          {'id': id, 'revision': 'cloud-revision', 'deleted': false},
        ],
        request: (action, body) async {
          calls++;
          expect(body['operation'], 'recover');
          expect(body['data'], original);
          return {
            'schoolId': school,
            'success': true,
            'syncProtocol': 2,
            'recovered': true,
            'recordRevision': 'cloud-revision',
          };
        },
      ),
      1,
    );
    expect(calls, 1);
    expect(
      (await db.collection(collection).doc(id).get()).data()?['name'],
      'New offline edit',
    );
    expect(
      (await db.collection('_windows_firebase_outbox').get()).docs.single
          .data()['operationId'],
      pending['operationId'],
    );
  });
  test('failed recovery or mismatched receipt retains the pending edit across restart', () async {
    await cacheVerifiedSheetRecord(school, collection, id, {
      'schoolId': school, '_syncRevision': 'verified-revision', 'name': 'Verified',
    });
    await db.collection(collection).doc(id).set({'schoolId': school, 'name': 'Offline edit'});
    final operation = (await db.collection('_windows_firebase_outbox').get()).docs.single.data()['operationId'];
    for (final mismatch in [false, true]) {
      await expectLater(recoverMissingSheetRecords(school, collection, [
        {'id': id, 'revision': 'verified-revision'},
      ], request: (action, body) async {
        if (!mismatch) throw StateError('Synthetic transport failure');
        return {'schoolId': school, 'success': true, 'syncProtocol': 2,
          'recovered': true, 'recordRevision': 'different-revision'};
      }), throwsStateError);
    }
    final profile = db.activeProfileId;
    await db.resetVolatileSession();
    await db.switchProfile(profile, identity: {'schoolSyncId': school, 'schoolId': school});
    expect((await db.collection(collection).doc(id).get()).data()?['name'], 'Offline edit');
    expect((await db.collection('_windows_firebase_outbox').get()).docs.single.data()['operationId'], operation);
  });
  test('unknown, stale and deleted rows are not guessed or uploaded; foreign school is rejected', () async {
    await cacheVerifiedSheetRecord(school, collection, id, {
      'schoolId': school,
      '_syncRevision': 'old',
      'name': 'Old',
    });
    expect(
      await recoverMissingSheetRecords(school, collection, [
        {'id': id, 'revision': 'new'},
        {'id': 'missing', 'revision': 'unknown'},
        {'id': id, 'revision': 'old', 'deleted': true},
      ], request: (a, b) async => fail('No unverified recovery write')),
      0,
    );
    await expectLater(
      cacheVerifiedSheetRecord('other', collection, id, {
        'schoolId': 'other',
        '_syncRevision': 'x',
      }),
      throwsStateError,
    );
  });
}

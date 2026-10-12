import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = FirebaseFirestore.instance;
  const schoolA = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const schoolB = 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  late String profileA;
  late String profileB;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    final suffix = DateTime.now().microsecondsSinceEpoch;
    profileA = 'backup-a-$suffix';
    profileB = 'backup-b-$suffix';
    await db.switchProfile(profileB, identity: {'schoolSyncId': schoolB});
    await db.collection('students_directory').doc('foreign').set({
      'schoolId': schoolB,
      'name': 'FOREIGN PRIVATE PUPIL',
    });
    await db.switchProfile(profileA, identity: {'schoolSyncId': schoolA});
  });

  Map<String, dynamic> collections(Map<String, dynamic> snapshot) =>
      Map<String, dynamic>.from(
        ((snapshot['profiles'] as Map)[profileA] as Map)['collections'] as Map,
      );

  test('snapshot contains all own collections, pending operations and cache, excluding other profiles', () async {
    await db.collection('students_directory').doc('own').set({
      'schoolId': schoolA,
      'name': 'OWN OFFLINE PUPIL',
    });
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() async {
      await db
          .collection('_windows_school_registration_cache')
          .doc('cache')
          .set({'schoolId': schoolA, 'name': 'LOCAL REGISTRATION CACHE'});
      await db.collection('_windows_document_outbox').doc('binary').set({
        'schoolId': schoolA,
        'operationId': 'retained-document-op',
        'state': 'pending',
      });
      await db.collection('_windows_local_deletions').doc('removed').set({
        'schoolId': schoolA,
        'snapshot': {'name': 'RECYCLE SNAPSHOT'},
      });
    });
    final snapshot = await db.exportActiveSchoolSnapshot();
    expect((snapshot['profiles'] as Map).keys, [profileA]);
    final own = collections(snapshot);
    expect(
      own.keys,
      containsAll([
        'students_directory',
        '_windows_firebase_outbox',
        '_windows_school_registration_cache',
        '_windows_document_outbox',
        '_windows_local_deletions',
      ]),
    );
    expect(
      (own['_windows_firebase_outbox'] as Map).values,
      contains(
        predicate((dynamic row) => row is Map && row['documentId'] == 'own'),
      ),
    );
    expect(jsonEncode(snapshot), isNot(contains('FOREIGN PRIVATE PUPIL')));
    expect(jsonEncode(snapshot), isNot(contains(schoolB)));
    expect(
      (await db.collection('_windows_document_outbox').doc('binary').get())
          .exists,
      true,
    );
  });

  test('serialized snapshot includes preceding committed write and remains immutable after later edit', () async {
    final first = db.collection('teachers_directory').doc('teacher').set({
      'name': 'BEFORE SNAPSHOT',
    });
    final exporting = db.exportActiveSchoolSnapshot();
    final later = db.collection('teachers_directory').doc('teacher').set({
      'name': 'AFTER SNAPSHOT',
    });
    await first;
    final snapshot = await exporting;
    await later;
    expect(
      (collections(snapshot)['teachers_directory'] as Map)['teacher']['name'],
      'BEFORE SNAPSHOT',
    );
    expect(
      (await db.collection('teachers_directory').doc('teacher').get())
          .data()?['name'],
      'AFTER SNAPSHOT',
    );
    (collections(snapshot)['teachers_directory'] as Map)['teacher']['name'] =
        'MUTATED EXPORT';
    expect(
      (await db.collection('teachers_directory').doc('teacher').get())
          .data()?['name'],
      'AFTER SNAPSHOT',
    );
  });

  test('queued school switch fails old-school snapshot instead of exporting new school', () async {
    final switching = db.switchProfile(
      profileB,
      identity: {'schoolSyncId': schoolB},
    );
    final exporting = db.exportActiveSchoolSnapshot();
    await expectLater(exporting, throwsStateError);
    await switching;
    expect(db.activeProfileId, profileB);
    expect(
      (await db.collection('students_directory').doc('foreign').get())
          .data()?['name'],
      'FOREIGN PRIVATE PUPIL',
    );
  });

  test('unverified school scope cannot produce portable snapshot', () async {
    await db.switchProfile('unbound-$profileA');
    expect(() => db.exportActiveSchoolSnapshot(), throwsStateError);
  });
}

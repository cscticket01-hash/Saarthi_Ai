import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../lib/platform/platform_config.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_sync_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final db = FirebaseFirestore.instance, engine = WindowsSyncEngine.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      CentralSchoolCloud.key: jsonEncode({
        'managed': true,
        'schoolId': school,
        'uid': 'A',
        'folderId': 'managed',
        'projectId': platformProjectId,
        'endpoint': 'https://unreachable.example/school-cloud',
        'firebaseRefreshToken': 'synthetic',
      }),
    });
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile(
      'recovery-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolSyncId': school, 'schoolId': school},
    );
  });
  Map<String, dynamic> cloud(
    Map<String, String> revisions, {
    bool deleted = false,
  }) => {
    for (final c in revisions.keys)
      c: {
        'syncProtocol': 2,
        'collectionRevision': 'verified-$c',
        'unchanged': revisions[c] == 'verified-$c',
        'records': revisions[c] == 'verified-$c' || c != 'students_directory'
            ? <String, dynamic>{}
            : {
                'pupil': {
                  'schoolId': school,
                  'name': 'Verified cloud pupil',
                  'entryCapturedAt': 123456,
                  '_syncRevision': 'cloud-record',
                  if (deleted) '_syncDeleted': true,
                },
              },
      },
  };
  Future<void> seed({bool deleted = false}) =>
      engine.reconcileManagedCacheForTesting(
        school,
        (revisions) async => cloud(revisions, deleted: deleted),
      );
  test('actual reconciliation restores accidentally missing cache despite unchanged cloud checkpoint', () async {
    await seed();
    final inventory=(await db.collection('_windows_sync_downloads').doc('students_directory').get()).data()!;
    expect(inventory['schoolId'],school);
    expect(inventory['inventoryScope'],'records_only');
    expect(inventory['remaining'],0);
    expect(inventory['verified'],1);
    expect(inventory['state'],'verified');
    expect(inventory['lastVerifiedLocalReadbackAt'],isA<int>());
    expect(
      (await db.collection('students_directory').doc('pupil').get())
          .data()?['entryCapturedAt'],
      123456,
    );
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
      () => db.collection('students_directory').doc('pupil').delete(),
    );
    await db.resetVolatileSession();
    var forced = false;
    await engine.reconcileManagedCacheForTesting(school, (revisions) async {
      forced = revisions['students_directory'] == '';
      return cloud(revisions);
    });
    expect(forced, true);
    expect(
      (await db.collection('students_directory').doc('pupil').get())
          .data()?['name'],
      'Verified cloud pupil',
    );
    expect(
      (await db.collection('_windows_firebase_outbox').get()).docs,
      isEmpty,
    );
    await engine.reconcileManagedCacheForTesting(school, (revisions) async {
      expect(revisions['students_directory'], 'verified-students_directory');
      return cloud(revisions);
    });
  });
  test('intentional pending delete survives recovery and never resurrects cloud copy', () async {
    await seed();
    await db.collection('students_directory').doc('pupil').delete();
    final before = (await db.collection('_windows_firebase_outbox').get())
        .docs
        .single
        .data();
    await engine.reconcileManagedCacheForTesting(school, (revisions) async {
      expect(revisions['students_directory'], 'verified-students_directory');
      return cloud(revisions);
    });
    expect(
      (await db.collection('students_directory').doc('pupil').get()).exists,
      false,
    );
    expect(
      (await db.collection('_windows_firebase_outbox').get()).docs.single
          .data()['operationId'],
      before['operationId'],
    );
  });
  test('verified tombstone is not repeatedly fetched or resurrected', () async {
    await seed(deleted: true);
    await engine.reconcileManagedCacheForTesting(school, (revisions) async {
      expect(revisions['students_directory'], 'verified-students_directory');
      return cloud(revisions, deleted: true);
    });
    expect(
      (await db.collection('students_directory').doc('pupil').get()).exists,
      false,
    );
  });
  test(
    'pending newer edit remains durable under authoritative recovery',
    () async {
      await seed();
      await db.collection('students_directory').doc('pupil').update({
        'name': 'Newer local',
      });
      await seed();
      expect(
        (await db.collection('students_directory').doc('pupil').get())
            .data()?['name'],
        'Newer local',
      );
      expect(
        (await db.collection('_windows_firebase_outbox').get()).docs,
        hasLength(1),
      );
    },
  );
  test('foreign response and school switch during read are rejected', () async {
    await expectLater(
      engine.reconcileManagedCacheForTesting(school, (revisions) async {
        final result = cloud(revisions);
        result['students_directory']['records']['pupil']['schoolId'] =
            'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
        return result;
      }),
      throwsStateError,
    );
    expect((await db.collection('students_directory').get()).docs, isEmpty);
    expect((await db.collection('_windows_sync_downloads').get()).docs,isEmpty);
    await expectLater(
      engine.reconcileManagedCacheForTesting(school, (revisions) async {
        await db.switchProfile(
          'other-school',
          identity: {'schoolSyncId': 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'},
        );
        return cloud(revisions);
      }),
      throwsStateError,
    );
    expect((await db.collection('students_directory').get()).docs, isEmpty);
  });
  test('download inventory retains newer local edits without a successful readback claim', () async {
    await seed();
    await db.collection('students_directory').doc('pupil').update({'name':'Offline newer'});
    final original=(await db.collection('_windows_firebase_outbox').get()).docs.single.data();
    await engine.reconcileManagedCacheForTesting(school,(revisions)async=>cloud({for(final c in revisions.keys)c:''}));
    final inventory=(await db.collection('_windows_sync_downloads').doc('students_directory').get()).data()!;
    expect(inventory['state'],'needsReview');
    expect(inventory['remaining'],1);
    expect(inventory['blocked'],1);
    expect(inventory['verified'],0);
    expect(inventory.containsKey('lastVerifiedLocalReadbackAt'),false);
    expect((await db.collection('_windows_firebase_outbox').get()).docs.single.data()['operationId'],original['operationId']);
    expect((await db.collection('students_directory').doc('pupil').get()).data()?['name'],'Offline newer');
  });
}

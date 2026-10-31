import 'dart:convert';
import 'dart:io';

import '../lib/windows_local_storage.dart';

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
    if (WindowsLocalStorage.sqliteEnabled) {
      await db.changeLocalStorageLocation((await Directory.systemTemp.createTemp('smart-recovery-sql-')).path);
    }
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
  test('bounded school reads finish without an oversized full-school request', () async {
    final seen = <String>{};
    var requests = 0;
    await engine.reconcileManagedCacheForTesting(school, (revisions) async {
      requests++;
      // Model the server boundary that times out for an oversized census.
      if (revisions.length > 2) throw const SocketException('Synthetic oversized census timeout');
      expect(seen.intersection(revisions.keys.toSet()), isEmpty);
      seen.addAll(revisions.keys);
      return cloud(revisions);
    });
    expect(requests, greaterThan(1));
    expect(seen, containsAll(['students_directory', 'teachers_directory', 'documents', 'exams']));
    expect((await db.collection('students_directory').doc('pupil').get()).data()?['name'], 'Verified cloud pupil');
    expect((await db.collection('_windows_sync_manifest').get()).docs.length, seen.length);
  });
  test('later read timeout retains earlier verified progress and offline pending work after reopen', () async {
    await db.collection('school_expenses').doc('offline').set({'schoolId': school, 'amount': 17});
    final operation = (await db.collection('_windows_firebase_outbox').get()).docs.single.data()['operationId'];
    var calls = 0;
    await expectLater(engine.reconcileManagedCacheForTesting(school, (revisions) async {
      if (++calls == 2) {
        expect((await db.collection('students_directory').doc('pupil').get()).data()?['name'], 'Verified cloud pupil');
        throw const SocketException('Synthetic later read timeout');
      }
      return cloud(revisions);
    }), throwsA(isA<SocketException>()));
    final profile = db.activeProfileId;
    await db.resetVolatileSession();
    await db.switchProfile(profile, identity: {'schoolSyncId': school, 'schoolId': school});
    expect((await db.collection('students_directory').doc('pupil').get()).data()?['name'], 'Verified cloud pupil');
    expect((await db.collection('_windows_firebase_outbox').get()).docs.single.data()['operationId'], operation);
    expect((await db.collection('_windows_sync_manifest').doc(base64Url.encode(utf8.encode('managed\nstudents_directory')).replaceAll('=', '')).get()).data()?['revision'], 'verified-students_directory');
    await engine.reconcileManagedCacheForTesting(school, (revisions) async {
      if (revisions.containsKey('students_directory')) expect(revisions['students_directory'], 'verified-students_directory');
      return cloud(revisions);
    });
    expect((await db.collection('school_expenses').doc('offline').get()).data()?['amount'], 17);
    expect((await db.collection('_windows_firebase_outbox').get()).docs.single.data()['operationId'], operation);
  });
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
      if (revisions.containsKey('students_directory')) forced = revisions['students_directory'] == '';
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
      if (revisions.containsKey('students_directory')) expect(revisions['students_directory'], 'verified-students_directory');
      return cloud(revisions);
    });
  });
  test('stalled same-head download gets an authoritative scoped recovery and local readback', () async {
    await seed();
    final checkpoint=db.collection('_windows_sync_downloads').doc('students_directory');
    final prior=(await checkpoint.get()).data()!;
    await checkpoint.set({
      ...prior,'state':'downloading','remaining':1,'verified':0,
      'observedAt':DateTime.now().millisecondsSinceEpoch-180000,
      'repairAttempts':1,'repairLastAttemptAt':DateTime.now().millisecondsSinceEpoch-1000000,
    });
    var readCount=0;
    await engine.reconcileStalledDownloadForTesting(school,'students_directory',(revisions)async{
      readCount++;
      expect(revisions,{'students_directory':''},
        reason:'same collection head must not suppress unverified local readback');
      return cloud(revisions);
    });
    expect(readCount,1);
    final healed=(await checkpoint.get()).data()!;
    expect(healed['state'],'verified');
    expect(healed['remaining'],0);
    expect(healed['verified'],1);
    expect(healed['repairAttempts'],1,
      reason:'recovery attempt evidence remains bounded if the next read fails');
    expect(healed['lastVerifiedLocalReadbackAt'],isA<int>());
    expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
  });
  test('self repair cannot replace a newer local edit or fabricate a cloud ACK',() async {
    await seed();
    await db.collection('students_directory').doc('pupil').update({'name':'Offline newer'});
    final pending=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    final originalOperation=pending.data()['operationId'];
    final checkpoint=db.collection('_windows_sync_downloads').doc('students_directory');
    await checkpoint.set({
      'schoolId':school,'collection':'students_directory',
      'collectionRevision':'verified-students_directory',
      'state':'needsReview','remaining':1,'verified':0,'blocked':1,
      'observedAt':DateTime.now().millisecondsSinceEpoch-180000,
      'repairAttempts':1,'repairLastAttemptAt':DateTime.now().millisecondsSinceEpoch-1000000,
    });
    await engine.reconcileStalledDownloadForTesting(
      school,'students_directory',(revisions)async=>cloud(revisions));
    final unresolved=(await checkpoint.get()).data()!;
    expect(unresolved['remaining'],1);
    expect(unresolved['state'],'needsReview');
    expect(unresolved['blocked'],1);
    expect((await db.collection('students_directory').doc('pupil').get()).data()?['name'],'Offline newer');
    expect((await db.collection('_windows_firebase_outbox').get()).docs.single.data()['operationId'],
      originalOperation);
  });
  test('offline device reconciles retired generations from a live replacement student', () async {
    await db.collection('students_directory').doc('pupil').set({
      'schoolId': school, 'mobileStableId': 'old-person', 'name': 'Retired',
    });
    await db.collection('fee_payments').doc('old-fee').set({
      'schoolId': school, 'studentId': 'pupil', 'personId': 'old-person', 'amount': 100,
    });
    await db.collection('fee_payments').doc('new-fee').set({
      'schoolId': school, 'studentId': 'pupil', 'personId': 'new-person', 'amount': 200,
    });
    final retained = (await db.collection('_windows_firebase_outbox').get()).docs
        .singleWhere((d) => d.data()['documentId'] == 'new-fee').data()['operationId'];
    await engine.reconcileManagedCacheForTesting(school, (revisions) async {
      final result = cloud({for (final c in revisions.keys) c: ''});
      if (result.containsKey('students_directory')) result['students_directory']['records']['pupil'] = {
        'schoolId': school, 'mobileStableId': 'new-person', 'name': 'Replacement',
        '_syncRevision': 'replacement-revision', '_syncRetiredStudentGenerations': ['old-person'],
      };
      return result;
    });
    expect((await db.collection('students_directory').doc('pupil').get()).data()?['mobileStableId'], 'new-person');
    expect((await db.collection('fee_payments').doc('old-fee').get()).exists, false);
    expect((await db.collection('fee_payments').doc('new-fee').get()).data()?['amount'], 200);
    expect((await db.collection('_windows_firebase_outbox').get()).docs.single.data()['operationId'], retained);
  });
  test('intentional pending delete survives recovery and never resurrects cloud copy', () async {
    await seed();
    await db.collection('students_directory').doc('pupil').delete();
    final before = (await db.collection('_windows_firebase_outbox').get())
        .docs
        .single
        .data();
    await engine.reconcileManagedCacheForTesting(school, (revisions) async {
      if (revisions.containsKey('students_directory')) expect(revisions['students_directory'], 'verified-students_directory');
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
      if (revisions.containsKey('students_directory')) expect(revisions['students_directory'], 'verified-students_directory');
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

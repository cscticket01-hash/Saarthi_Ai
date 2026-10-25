import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_sync_inbox.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_sync_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final db = FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(true);
    final dir = await Directory.systemTemp.createTemp('sync-intelligent-');
    await db.changeLocalStorageLocation(dir.path);
    await db.switchProfile(
      'intelligent-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolSyncId': school, 'schoolId': school},
    );
  });
  tearDown(() async {
    await db.resetVolatileSession();
  });
  Map<String, dynamic> record(String id, String revision) => {
    'id': id,
    'schoolId': school,
    'name': 'Original',
    'teacherId': 'person-$id',
    '_syncRevision': revision,
  };
  test('received notification and cursor survive restart; applied checkpoint requires explicit owner completion', () async {
    final profile = db.activeProfileId,
        event = {
          'schoolId': school,
          'cursor': 'empty:2',
          'reset': false,
          'collections': ['teachers_directory'],
          'records': {
            'teachers_directory': ['one'],
          },
        };
    await WindowsSyncInbox.receive(profile, school, event);
    await db.resetVolatileSession();
    expect(await WindowsSyncInbox.cursor(profile, school), 'empty:2');
    final rows = await WindowsSyncInbox.pending(profile, school);
    expect(rows, hasLength(1));
    expect(
      (await db.collection('_windows_sync_status').doc('applied-events').get())
          .exists,
      false,
    );
    await WindowsSyncInbox.applied(profile, school, rows);
    expect(await WindowsSyncInbox.pending(profile, school), isEmpty);
    expect(
      (await db.collection('_windows_sync_status').doc('applied-events').get())
          .data()?['cursors'],
      ['empty:2'],
    );
    await db.switchProfile('other', identity: {'schoolSyncId': school});
    await expectLater(
      WindowsSyncInbox.receive(profile, school, event),
      throwsStateError,
    );
  });
  test('exact record fetch preserves unrelated cached records and the whole collection checkpoint', () async {
    final engine = WindowsSyncEngine.instance;
    await engine.reconcileManagedRecordDeltaForTesting(
      school,
      (known, records) async => {
        'teachers_directory': {
          'syncProtocol': 2,
          'collectionRevision': 'whole-r1',
          'records': {'one': record('one', 'r1'), 'two': record('two', 'r1')},
        },
      },
      selectedCollections: {'teachers_directory'},
    );
    await engine.reconcileManagedPointTargetsForTesting(
      school,
      {
        'teachers_directory': {'one'},
      },
      (collection, ids) async {
        expect(ids, {'one'});
        return {
          'one': {...record('one', 'r2'), 'name': 'Corrected'},
        };
      },
    );
    expect(
      (await db.collection('teachers_directory').doc('one').get())
          .data()?['name'],
      'Corrected',
    );
    expect(
      (await db.collection('teachers_directory').doc('two').get())
          .data()?['name'],
      'Original',
    );
    final manifests =
        (await db.collection('_windows_sync_manifest').get()).docs;
    final manifest = manifests
        .singleWhere((r) => r.data()['collection'] == 'teachers_directory')
        .data();
    expect(manifest['revision'], 'whole-r1');
    expect(manifest['recordRevisions']['one'], 'r2');
    expect(manifest['recordRevisions']['two'], 'r1');
  });
  test('legacy teacher delete recovers identity from original deletion evidence and retries exact operation', () async {
    final ref = db.collection('teachers_directory').doc('one');
    await db.applySyncedDocument(ref, record('one', 'r1'));
    await ref.delete();
    final row =
        (await db.collection('_windows_firebase_outbox').get()).docs.single;
    final legacy = {...row.data(), 'syncState': 'conflict'}
      ..remove('deletedRecordIdentity');
    await row.reference.set(legacy);
    final events = <Map<String, dynamic>>[];
    expect(
      await WindowsPendingSchoolSync.repair(
        profileId: db.activeProfileId,
        school: school,
        onActivity: events.add,
        read: (col, id) async => {
          'schoolId': school,
          'syncProtocol': 2,
          'pointRead': true,
          'records': {id: record(id, 'r2')},
        },
      ),
      1,
    );
    final next = (await row.reference.get()).data()!;
    expect(next['operationId'], legacy['operationId']);
    expect(next['baseCloudRevision'], 'r2');
    expect(next['syncState'], 'pending');
    expect(events.single['outcome'], 'retry_admitted');
    await WindowsPendingSchoolSync.flush(
      profileId: db.activeProfileId,
      send: (a, b, c, d) async {},
      sendVersioned: (_) async => 'deleted-r3',
    );
    expect(
      (await db
              .collection('_windows_local_deletions')
              .doc(legacy['operationId'])
              .get())
          .data()?['cloudDeletionVerified'],
      true,
    );
  });
  test('same-field conflict is retained, probes back off, and authorization is never reopened', () async {
    final ref = db.collection('teachers_directory').doc('one');
    await db.applySyncedDocument(ref, record('one', 'r1'));
    await ref.update({'name': 'Local edit'});
    final row =
        (await db.collection('_windows_firebase_outbox').get()).docs.single;
    await row.reference.update({'syncState': 'conflict'});
    var probes = 0;
    Future<Map<String, dynamic>> read(String c, String id) async {
      probes++;
      return {
        'schoolId': school,
        'syncProtocol': 2,
        'pointRead': true,
        'records': {
          id: {...record(id, 'r2'), 'name': 'Other edit'},
        },
      };
    }

    for (var i = 0; i < 2; i++)
      expect(
        await WindowsPendingSchoolSync.repair(
          profileId: db.activeProfileId,
          school: school,
          read: read,
        ),
        0,
      );
    expect(probes, 1);
    expect((await row.reference.get()).data()?['syncState'], 'conflict');
    expect((await ref.get()).data()?['name'], 'Local edit');
    await row.reference.update({
      'syncState': 'needsAttention',
      'failureCategory': 'authorization',
    });
    await WindowsPendingSchoolSync.repair(
      profileId: db.activeProfileId,
      school: school,
      read: read,
    );
    expect(probes, 1);
  });
}

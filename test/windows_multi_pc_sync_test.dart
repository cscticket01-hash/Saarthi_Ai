import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/platform/platform_config.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_local_storage.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_sync_engine.dart';
import '../lib/windows_sync_dependencies.dart';

const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

// Two physical SQLite files, switched sequentially through the production API.
// The shared cloud is the real signed Apps Script implementation in a Node VM.
// All files/accounts/records are synthetic; no production endpoint is called.
class _Rig {
  final db = FirebaseFirestore.instance;
  late Directory root;
  late Process server;
  late StreamIterator<String> replies;
  final measurements = <String, dynamic>{
    'environment': 'synthetic-two-SQLite-PCs-and-Apps-Script-VM',
  };
  String pc = '';
  Future<void> start() async {
    root = await Directory.systemTemp.createTemp('saarthi-two-pc-');
    server = await Process.start(
      'node',
      ['test/helpers/two-pc-cloud.cjs'],
      workingDirectory:
          '${Directory.current.path}${Platform.pathSeparator}functions',
    );
    replies = StreamIterator(
      server.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    server.stderr
        .transform(utf8.decoder)
        .listen((e) => fail('Synthetic Script worker: $e'));
    FlutterSecureStorage.setMockInitialValues({
      CentralSchoolCloud.key: jsonEncode({
        'managed': true,
        'projectId': platformProjectId,
        'folderId': 'managed',
        'schoolId': school,
        'uid': 'synthetic-multi-pc',
        'firebaseRefreshToken': 'synthetic',
        'endpoint': 'https://unreachable.example/school-cloud',
      }),
    });
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await open('pc1');
  }

  Future<void> open(String name) async {
    await db.resetVolatileSession();
    final dir = Directory('${root.path}${Platform.pathSeparator}$name');
    await dir.create(recursive: true);
    // Configure independent disks without invoking the user folder migration
    // (which intentionally copies old data and must never join these PCs).
    await WindowsLocalStorage.controlDirectory.create(recursive: true);
    await File(
      '${WindowsLocalStorage.controlDirectory.path}${Platform.pathSeparator}storage_config_v1.json',
    ).writeAsString(jsonEncode({'dataPath': dir.path}), flush: true);
    await WindowsLocalStorage.initialize();
    await db.switchProfile('synthetic-unbound');
    await db.switchProfile(
      'same-school',
      identity: {'schoolId': school, 'schoolSyncId': school},
    );
    final sql = await WindowsLocalStorage.sqliteFile();
    if (!await sql.exists() &&
        await (await WindowsLocalStorage.databaseFile()).exists()) {
      await db.migrateLocalDatabaseToSqlite(approved: true);
    }
    expect(await sql.exists(), true);
    pc = name;
  }

  Future<Map<String, dynamic>> request(Map<String, dynamic> body) async {
    server.stdin.writeln(jsonEncode(migrationJsonValue(body)));
    if (!await replies.moveNext()) throw StateError('Synthetic server closed');
    final out = Map<String, dynamic>.from(jsonDecode(replies.current) as Map);
    if (out['success'] != true) {
      final conflict = RegExp(
        'revision conflict|operation ID conflict',
        caseSensitive: false,
      ).hasMatch(out['message']?.toString() ?? '');
      throw CentralCloudException(
        conflict ? 409 : 422,
        'school_cloud',
        out['message']?.toString() ?? 'Synthetic failure',
        diagnosticCode: conflict
            ? 'RECORD_REVISION_CONFLICT'
            : out['code']?.toString() ?? '',
      );
    }
    return out;
  }

  Future<String> send(Map<String, dynamic> item) async {
    final out = await request({
      'action': 'managed_records',
      'operation': item['operation'] == 'delete' ? 'delete' : 'write',
      'collection': item['collection'],
      'id': item['documentId'],
      'syncProtocol': 2,
      'operationId': item['operationId'],
      'expectedRecordRevision': item['baseCloudRevision'] ?? '',
      if (item['deletedStudentGeneration'] != null)
        'deletedStudentGeneration': item['deletedStudentGeneration'],
      if (item['operation'] != 'delete') 'data': item['data'],
    });
    expect(out['schoolId'], school);
    expect(out['syncProtocol'], 2);
    expect(out['recordRevision'], isNotEmpty);
    return out['recordRevision'] as String;
  }

  Future<void> flush({
    Future<String> Function(Map<String, dynamic>)? sender,
    bool explicitRetry = false,
  }) async {
    final rows = explicitRetry ? await queue() : null;
    await WindowsPendingSchoolSync.flush(
      profileId: db.activeProfileId,
      onlyOperationId: explicitRetry
          ? rows!.single.data()['operationId'] as String
          : null,
      send: (a, b, c, d) async {},
      sendVersioned: sender ?? send,
    );
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> queue() async =>
      (await db.collection('_windows_firebase_outbox').get()).docs;
  Future<void> pull(Set<String> collections) async {
    await WindowsSyncEngine.instance.reconcileManagedRecordDeltaForTesting(
      school,
      (known, checkpoints) async {
        final result = await request({
          'action': 'managed_delta',
          'collections': known.keys.toList(),
          'knownRevisions': known,
          if (checkpoints.isNotEmpty) 'knownRecordRevisions': checkpoints,
        });
        return Map<String, dynamic>.from(result['changes'] as Map);
      },
      selectedCollections: collections,
    );
  }

  Future<void> close() async {
    await db.resetVolatileSession();
    await server.stdin.close();
    await replies.cancel();
    await server.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        server.kill();
        return -1;
      },
    );
    // Preserve synthetic measurements as CI artifacts, never user data.
    final report = File(
      'build/multi-pc/$pc-${DateTime.now().microsecondsSinceEpoch}.json',
    );
    await report.parent.create(recursive: true);
    await report.writeAsString(jsonEncode(measurements));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Rig rig;
  setUp(() async {
    expect(
      WindowsLocalStorage.sqliteEnabled,
      true,
      reason: 'Requires actual independent SQLite files',
    );
    rig = _Rig();
    await rig.start();
  });
  tearDown(() async => rig.close());

  test('offline identical entry adopts cloud original on independent SQLite PC and unchanged head repair stays incremental', () async {
    const values = {'schoolId':school,'title':'Same notice','message':'Identical content'};
    await rig.db.collection('school_notices').doc('N1').set(values);
    await rig.flush();
    final cloud = (await rig.request({'action':'managed_records','operation':'read',
      'collection':'school_notices','syncProtocol':2}))['records']['N1'] as Map;
    await rig.open('pc2');
    await rig.db.collection('school_notices').doc('N1').set(values);
    final original = (await rig.queue()).single.data();
    await expectLater(rig.flush(),throwsA(isA<CentralCloudException>()));
    await rig.pull({'school_notices'});
    expect(await rig.queue(),isEmpty);
    expect((await rig.db.collection('school_notices').doc('N1').get()).data()?['_syncRevision'],cloud['_syncRevision']);
    final archived = (await rig.db.collection('_windows_sync_conflict_history').get()).docs.single.data();
    expect(archived['operationId'],original['operationId']);
    expect(WindowsSyncEngine.instance.recoveryHistory.any((e) =>
      e['category']=='verifiedDuplicate' && e['outcome']=='duplicate_reconciled'),true);
    await rig.open('pc2');
    expect(await rig.queue(),isEmpty);

    // A retained stale operation can conflict even with unchanged collection
    // heads. Fetch only this missing checkpoint, retaining every other one.
    // Restore an old-version pending fixture explicitly: unchanged Save now
    // correctly creates no queue entry after a verified download.
    await rig.db.collection('school_notices').doc('N1').set(values);
    expect(await rig.queue(), isEmpty);
    await rig.db.collection('_windows_firebase_outbox').doc('legacy-stale-fixture').set({
      ...original, 'operationId':'legacy-stale-operation',
      'baseCloudRevision':'', 'syncState':'pending',
    });
    await expectLater(rig.flush(),throwsA(isA<CentralCloudException>()));
    await rig.pull({'school_notices'});
    expect(await rig.queue(),isEmpty);
    final unchanged = (await rig.request({'action':'managed_records','operation':'read',
      'collection':'school_notices','syncProtocol':2}))['records']['N1'] as Map;
    expect(unchanged['_syncRevision'],cloud['_syncRevision']);
    expect(unchanged['_syncOperationId'],cloud['_syncOperationId']);
  });

  test('changed directory Save uses authenticated CAS and a third edit conflicts again', () async {
    await rig.db.collection('teachers_directory').doc('T1').set({
      'schoolId':school,'teacherId':'person-1','name':'Synthetic teacher','subject':'Original',
    });
    await rig.flush();
    await rig.open('pc2');
    await rig.pull({'teachers_directory'});
    await rig.db.collection('teachers_directory').doc('T1').update({'subject':'Offline PC2'});
    await rig.open('pc1');
    await rig.db.collection('teachers_directory').doc('T1').update({'subject':'New PC1'});
    await rig.flush();
    await rig.open('pc2');
    await expectLater(rig.flush(),throwsA(isA<CentralCloudException>()));
    await rig.pull({'teachers_directory'});
    final conflict=(await rig.queue()).single.data();
    expect(conflict['syncState'],'conflict');
    await rig.db.collection('teachers_directory').doc('T1').update({'subject':'Offline PC2'});
    expect((await rig.queue()).single.data()['operationId'],conflict['operationId']);
    await rig.db.collection('teachers_directory').doc('T1').update({'subject':'Explicit Save PC2'});
    expect((await rig.queue()).single.data()['syncState'],'pending');
    await rig.open('pc1');
    await rig.db.collection('teachers_directory').doc('T1').update({'subject':'Intervening PC1'});
    await rig.flush();
    await rig.open('pc2');
    await expectLater(rig.flush(),throwsA(isA<CentralCloudException>()));
    expect((await rig.queue()).single.data()['syncState'],'conflict');
    await rig.pull({'teachers_directory'});
    await rig.db.collection('teachers_directory').doc('T1').update({'subject':'Final explicit PC2'});
    await rig.flush();
    expect(await rig.queue(),isEmpty);
    await rig.open('pc1');
    await rig.pull({'teachers_directory'});
    final rows=(await rig.db.collection('teachers_directory').get()).docs;
    expect(rows.length,1);
    expect(rows.single.data()['subject'],'Final explicit PC2');
  });

  test('dependent work survives SQLite restart without requiring a full idle scan', () async {
    await WindowsSyncDependencies.retain(school, 'notices', 'N1', 'notice-1');
    expect(await WindowsSyncDependencies.read(school), isEmpty);
    await WindowsSyncDependencies.retain(school, 'students_directory', 'S1', 'r1');
    await WindowsSyncDependencies.retain(school, 'students_directory', 'S1', 'r1');
    await rig.open('pc1');
    final captured = await WindowsSyncDependencies.read(school);
    expect(captured.length, 1);
    expect(captured.single.data()['documentId'], 'S1');
    expect((await rig.db.collection('_windows_firebase_outbox').get()).docs, isEmpty);
    // A later input arriving while the captured work runs must survive its ACK.
    await WindowsSyncDependencies.retain(school, 'students_directory', 'S1', 'r2');
    await WindowsSyncDependencies.complete(school, captured);
    await rig.open('pc1');
    final remaining = await WindowsSyncDependencies.read(school);
    expect(remaining.single.data()['revision'], 'r2');
    await rig.open('pc2');
    expect(await WindowsSyncDependencies.read(school), isEmpty);
    await expectLater(WindowsSyncDependencies.read('vs-foreign'), throwsStateError);
    await rig.open('pc1');
    await WindowsSyncDependencies.complete(school, await WindowsSyncDependencies.read(school));
    await rig.open('pc1');
    expect(await WindowsSyncDependencies.read(school), isEmpty);
  });

  test('restart uses durable heads once and requests only changed or missing baselines', () async {
    final engine = WindowsSyncEngine.instance;
    final names = <String>[];
    final initial = await engine.changedManagedCollectionsForTesting(school, (
      known,
    ) async {
      names.addAll(known.keys);
      expect(known.values.every((r) => r.isEmpty), true);
      return {for (final key in known.keys) key: 'r1'};
    });
    expect(initial.toSet(), names.toSet());
    String manifestId(String col) =>
        base64UrlEncode(utf8.encode('managed\n$col')).replaceAll('=', '');
    for (final col in names) {
      await rig.db
          .collection('_windows_sync_manifest')
          .doc(manifestId(col))
          .set({
            'collection': col,
            'revision': 'r1',
            'recordRevisions': <String, String>{},
          });
    }
    await rig.open('pc1');
    var reads = 0;
    final unchanged = await engine.changedManagedCollectionsForTesting(school, (
      known,
    ) async {
      reads++;
      expect(known.values.every((r) => r == 'r1'), true);
      return {...known};
    });
    expect(reads, 1);
    expect(unchanged, isEmpty);
    final changed = await engine.changedManagedCollectionsForTesting(
      school,
      (known) async => {...known, 'fee_payments': 'r2'},
    );
    expect(changed, {'fee_payments'});
    await rig.db
        .collection('_windows_sync_manifest')
        .doc(manifestId('students_directory'))
        .set({'revision': 'r1'});
    final baseline = await engine.changedManagedCollectionsForTesting(
      school,
      (known) async => {for (final key in known.keys) key: 'r1'},
    );
    expect(baseline, {'students_directory'});
    await expectLater(
      engine.changedManagedCollectionsForTesting('vs-foreign', (known) async {
        fail('Foreign read must not be sent');
        return known;
      }),
      throwsStateError,
    );
  });

  test('bounded download batch preserves pending payment, operation identity and school isolation across reopen', () async {
    final payments = rig.db.collection('fee_payments');
    await payments.doc('pending').set({'schoolId': school, 'amount': 100});
    final original = (await rig.queue()).single.data();
    await rig.db.applySyncedCollectionBatch('fee_payments', {
      'pending': {
        'schoolId': school,
        'amount': 200,
        '_syncRevision': 'different-cloud',
      },
      'clean': {
        'schoolId': school,
        'amount': 50,
        '_syncRevision': 'clean-cloud',
      },
    });
    expect((await payments.doc('pending').get()).data()?['amount'], 100);
    expect((await payments.doc('clean').get()).data()?['amount'], 50);
    expect(
      (await rig.queue()).single.data()['operationId'],
      original['operationId'],
    );
    await rig.db.applySyncedCollectionBatch('fee_payments', {
      'pending': {
        'schoolId': school,
        '_syncDeleted': true,
        '_syncRevision': 'deleted-cloud',
      },
    });
    expect((await payments.doc('pending').get()).data()?['amount'], 100);
    expect(
      () => rig.db.applySyncedCollectionBatch('fee_payments', {
        'must-not-apply': {'schoolId': school, 'amount': 1},
        'foreign': {
          'schoolId': 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          'amount': 1,
        },
      }),
      throwsStateError,
    );
    expect(
      () => rig.db.applySyncedCollectionBatch('fee_payments', {
        for (var i = 0; i < 101; i++)
          'too-many-$i': {'schoolId': school, 'amount': 1},
      }),
      throwsStateError,
    );
    await rig.open('pc1');
    expect(
      (await rig.db.collection('fee_payments').doc('pending').get())
          .data()?['amount'],
      100,
    );
    expect(
      (await rig.db.collection('fee_payments').doc('must-not-apply').get())
          .exists,
      false,
    );
    expect(
      (await rig.queue()).single.data()['operationId'],
      original['operationId'],
    );
    await rig.db.collection('fee_payments').doc('clean').update({'amount': 60});
    final queued = await rig.queue();
    expect(queued, hasLength(2));
    expect(
      queued
          .singleWhere((row) => row.data()['documentId'] == 'clean')
          .data()['baseCloudRevision'],
      'clean-cloud',
    );
  });

  test(
    'five independent SQLite devices converge without joining their queues',
    () async {
      final timer = Stopwatch()..start();
      for (var device = 1; device <= 5; device++) {
        await rig.open('pc$device');
        expect(
          (await rig.db.collection('students_directory').get()).docs,
          isEmpty,
        );
        await rig.db
            .collection('students_directory')
            .doc('five-pupil-$device')
            .set({
              'schoolId': school,
              'name': 'Device $device',
              'class': '5',
              'rollNo': '$device',
            });
        expect(await rig.queue(), hasLength(1));
      }
      for (var device = 1; device <= 5; device++) {
        await rig.open('pc$device');
        await rig.flush();
        expect(await rig.queue(), isEmpty);
      }
      for (var device = 1; device <= 5; device++) {
        await rig.open('pc$device');
        await rig.pull({'students_directory'});
        expect(
          (await rig.db.collection('students_directory').get()).docs,
          hasLength(5),
        );
        expect(
          await rig.queue(),
          isEmpty,
          reason: 'Cloud apply must not echo into upload queue',
        );
      }
      await rig.open('pc3');
      await rig.db.collection('students_directory').doc('five-pupil-1').update({
        'name': 'Edited on another PC',
      });
      await rig.flush();
      for (var device = 1; device <= 5; device++) {
        await rig.open('pc$device');
        await rig.pull({'students_directory'});
        expect(
          (await rig.db
                  .collection('students_directory')
                  .doc('five-pupil-1')
                  .get())
              .data()?['name'],
          'Edited on another PC',
        );
        await rig.open('pc$device');
        await rig.pull({'students_directory'});
        expect(
          (await rig.db.collection('students_directory').get()).docs,
          hasLength(5),
          reason: 'Reopening must not duplicate shared records',
        );
        expect(await rig.queue(), isEmpty);
      }
      await rig.open('pc2');
      await rig.db
          .collection('students_directory')
          .doc('five-pupil-1')
          .delete();
      await rig.flush();
      for (var device = 1; device <= 5; device++) {
        await rig.open('pc$device');
        await rig.pull({'students_directory'});
        expect(
          (await rig.db
                  .collection('students_directory')
                  .doc('five-pupil-1')
                  .get())
              .exists,
          false,
        );
        expect(
          (await rig.db.collection('students_directory').get()).docs,
          hasLength(4),
        );
        expect(await rig.queue(), isEmpty);
      }
      timer.stop();
      rig.measurements['fivePcAddEditReopenDeleteApplyMillis'] =
          timer.elapsedMilliseconds;
      rig.measurements['fivePcEnvironment'] = 'five independent SQLite files; signed Apps Script VM; sequential disk switching; no network';
    },
  );

  test('both directions, independent student additions, stale edit evidence and school isolation', () async {
    await rig.db.collection('students_directory').doc('pupil1').set({
      'schoolId': school,
      'name': 'PC1',
      'class': '1',
      'rollNo': '1',
    });
    await rig.open('pc2');
    expect((await rig.db.collection('students_directory').get()).docs, isEmpty);
    await rig.db.collection('students_directory').doc('pupil2').set({
      'schoolId': school,
      'name': 'PC2',
      'class': '1',
      'rollNo': '2',
    });
    // Both independent disks hold additions before either PC uploads.
    await rig.open('pc1');
    await rig.flush();
    expect(await rig.queue(), isEmpty);
    await rig.open('pc2');
    await rig.flush();
    await rig.pull({'students_directory'});
    expect(
      (await rig.db.collection('students_directory').get()).docs,
      hasLength(2),
    );
    await rig.open('pc1');
    await rig.pull({'students_directory'});
    expect(
      (await rig.db.collection('students_directory').get()).docs,
      hasLength(2),
    );
    await rig.db.collection('students_directory').doc('pupil1').update({
      'name': 'First edit',
    });
    await rig.open('pc2');
    await rig.db.collection('students_directory').doc('pupil1').update({
      'name': 'Different offline edit',
    });
    // Both PCs edited from the same baseline before either edit committed.
    await rig.open('pc1');
    await rig.flush();
    await rig.open('pc2');
    await expectLater(rig.flush(), throwsA(isA<CentralCloudException>()));
    await rig.pull({'students_directory'});
    expect((await rig.queue()).single.data()['syncState'], 'conflict');
    expect(
      (await rig.db.collection('students_directory').doc('pupil1').get())
          .data()?['name'],
      'Different offline edit',
    );
    expect(
      (await rig.db.collection('_windows_sync_conflicts').get()).docs,
      isNotEmpty,
    );
    await rig.db.switchProfile(
      'foreign',
      identity: {
        'schoolId': 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        'schoolSyncId': 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      },
    );
    expect((await rig.db.collection('students_directory').get()).docs, isEmpty);
    expect(await rig.queue(), isEmpty);
  });

  test('fee lost ACK, distinct payments, genuine conflict, offline deletion and legitimate recreation', () async {
    final fee = rig.db.collection('fee_payments').doc('payment');
    await fee.set({
      'schoolId': school,
      'amount': 500,
      'receiptNo': 'synthetic-1',
    });
    final original = (await rig.queue()).single.data();
    for (var attempt = 0; attempt < 5; attempt++) {
      await expectLater(
        rig.flush(
          sender: (row) async {
            await rig.send(row);
            throw TimeoutException('Response lost after commit');
          },
        ),
        throwsA(isA<TimeoutException>()),
      );
    }
    expect((await rig.queue()).single.data()['syncState'], 'needsAttention');
    await rig.pull({'fee_payments'});
    expect(
      (await rig.queue()).single.data()['operationId'],
      original['operationId'],
    );
    expect((await rig.queue()).single.data()['syncState'], 'pending');
    await rig.flush();
    expect(await rig.queue(), isEmpty);
    await rig.open('pc2');
    await rig.pull({'fee_payments'});
    await rig.db.collection('fee_payments').doc('separate-payment').set({
      'schoolId': school,
      'amount': 250,
      'receiptNo': 'synthetic-2',
    });
    await rig.flush();
    await rig.open('pc1');
    await rig.pull({'fee_payments'});
    expect((await rig.db.collection('fee_payments').get()).docs, hasLength(2));
    await rig.db.collection('fee_payments').doc('payment').update({
      'amount': 550,
    });
    await rig.flush();
    await rig.open('pc2');
    await rig.db.collection('fee_payments').doc('payment').update({
      'amount': 600,
    });
    final offline = (await rig.queue()).single.data();
    await expectLater(rig.flush(), throwsA(isA<CentralCloudException>()));
    await rig.pull({'fee_payments'});
    expect((await rig.queue()).single.data()['syncState'], 'conflict');
    expect(
      (await rig.db.collection('fee_payments').doc('payment').get())
          .data()?['amount'],
      600,
    );
    await rig.open('pc1');
    await rig.db.collection('fee_payments').doc('payment').delete();
    await rig.flush();
    await rig.open('pc2');
    await rig.pull({'fee_payments'});
    expect(
      (await rig.db.collection('fee_payments').doc('payment').get()).exists,
      false,
    );
    expect(await rig.queue(), isEmpty);
    final history =
        (await rig.db.collection('_windows_sync_conflict_history').get()).docs;
    expect(
      history.any((r) => r.data()['operationId'] == offline['operationId']),
      true,
    );
    await rig.db.collection('fee_payments').doc('payment').set({
      'schoolId': school,
      'amount': 700,
      'receiptNo': 'synthetic-fresh',
    });
    await rig.flush();
    await rig.open('pc1');
    await rig.pull({'fee_payments'});
    expect(
      (await rig.db.collection('fee_payments').doc('payment').get())
          .data()?['amount'],
      700,
    );
    expect(await rig.queue(), isEmpty);
  });

  test('offline PC cannot attach old student or fee edits to a new Class/Roll generation', () async {
    final old = 'p-${List.filled(32, '1').join()}',
        fresh = 'p-${List.filled(32, '2').join()}';
    await rig.db.collection('students_directory').doc('slot').set({
      'schoolId': school,
      'name': 'Old pupil',
      'class': 'Class 1',
      'rollNo': '1',
      'mobileStableId': old,
    });
    await rig.db.collection('fee_payments').doc('old-fee').set({
      'schoolId': school,
      'studentId': 'slot',
      'personId': old,
      'amount': 100,
    });
    await rig.flush();
    await rig.open('pc2');
    await rig.pull({'students_directory', 'fee_payments'});
    await rig.db.collection('students_directory').doc('slot').update({
      'name': 'Offline old edit',
    });
    await rig.db.collection('fee_payments').doc('old-fee').update({
      'amount': 200,
    });
    await rig.open('pc1');
    await rig.db.collection('students_directory').doc('slot').delete();
    await rig.flush();
    await rig.db.collection('students_directory').doc('slot').set({
      'schoolId': school,
      'name': 'Fresh pupil',
      'class': 'Class 1',
      'rollNo': '1',
      'mobileStableId': fresh,
    });
    await rig.flush();
    await rig.open('pc2');
    await rig.pull({'students_directory', 'fee_payments'});
    expect(
      (await rig.db.collection('students_directory').doc('slot').get())
          .data()?['mobileStableId'],
      fresh,
    );
    expect(
      (await rig.db.collection('fee_payments').doc('old-fee').get()).exists,
      false,
    );
    expect(await rig.queue(), isEmpty);
    await rig.open('pc1');
    await rig.pull({'students_directory', 'fee_payments'});
    expect(
      (await rig.db.collection('students_directory').get()).docs,
      hasLength(1),
    );
  });

  test('502/503/504, 45-second timeout and lock failure preserve operation across reopen', () async {
    await rig.db.collection('school_notices').doc('retry').set({
      'schoolId': school,
      'title': 'Retained',
    });
    final original = (await rig.queue()).single.data();
    for (final error in <Object>[
      for (final status in [502, 503, 504])
        CentralCloudException(status, 'school_cloud', 'Synthetic transport'),
      TimeoutException(
        'Synthetic 45-second deadline',
        const Duration(seconds: 45),
      ),
      CentralCloudException(503, 'school_cloud', 'Synthetic Script lock busy'),
    ]) {
      await expectLater(
        rig.flush(sender: (row) async => throw error),
        throwsA(anything),
      );
      await rig.open('pc1');
      final retained = (await rig.queue()).single.data();
      expect(retained['operationId'], original['operationId']);
      expect(retained['data'], original['data']);
    }
    expect((await rig.queue()).single.data()['syncState'], 'needsAttention');
    await rig.flush(explicitRetry: true);
    expect(await rig.queue(), isEmpty);
    // A record validation fault cannot starve a later independent operation.
    final profile = rig.db
        .collection('school_config')
        .doc('school_profile_cache');
    final blank = {
      'schoolId': school,
      'schoolName': '',
      'principalName': '',
      'schoolContactNo': '',
    };
    await profile.set(blank);
    expect(
      await rig.queue(),
      isEmpty,
      reason: 'Current admission already blocks blank profiles',
    );
    await profile.set({
      'schoolId': school,
      'schoolName': 'Synthetic School',
      'principalName': 'Synthetic Principal',
      'schoolContactNo': '0000000000',
    });
    final legacy = (await rig.queue()).single;
    // Reproduce a bad row retained from an older client. Never weaken the
    // current local admission guard just to manufacture a pending operation.
    await legacy.reference.set({...legacy.data(), 'data': blank});
    await rig.db.collection('school_settings').doc('independent').set({
      'schoolId': school,
      'value': 1,
    });
    await expectLater(rig.flush(), throwsA(isA<CentralCloudException>()));
    expect((await rig.queue()).single.data()['collection'], 'school_config');
    expect((await rig.queue()).single.data()['syncState'], 'needsAttention');
    await rig.open('pc2');
    await rig.pull({'school_settings'});
    expect(
      (await rig.db.collection('school_settings').doc('independent').get())
          .data()?['value'],
      1,
    );
  });

  for (final count in [1000, 5000]) {
    test(
      '$count queued students -> real Script VM -> independent SQLite PC, measured',
      () async {
        final save = Stopwatch()..start();
        final batch = rig.db.batch();
        for (var i = 0; i < count; i++)
          batch.set(rig.db.collection('students_directory').doc('load-$i'), {
            'schoolId': school,
            'name': 'Synthetic $i',
            'class': 'Load',
            'rollNo': '$i',
          });
        await batch.commit();
        save.stop();
        expect(await rig.queue(), hasLength(count));
        final upload = Stopwatch()..start();
        await rig.flush();
        upload.stop();
        expect(await rig.queue(), isEmpty);
        await rig.open('pc2');
        final discovery = Stopwatch()..start();
        final heads = await rig.request({
          'action': 'managed_delta',
          'headOnly': true,
          'collections': ['students_directory'],
          'knownRevisions': {},
        });
        discovery.stop();
        expect(heads['headOnly'], true);
        final propagation = Stopwatch()..start();
        await rig.pull({'students_directory'});
        propagation.stop();
        expect(
          (await rig.db.collection('students_directory').get()).docs,
          hasLength(count),
        );
        expect(await rig.queue(), isEmpty);
        rig.measurements.addAll({
          'students': count,
          'localSaveMicros': save.elapsedMicroseconds,
          'uploadAndAckMicros': upload.elapsedMicroseconds,
          'discoveryRequestMicros': discovery.elapsedMicroseconds,
          'downloadAndVerifiedApplyMicros': propagation.elapsedMicroseconds,
          'discoveryScheduleSeconds': 30,
          'liveNetworkMeasured': false,
        });
        print('MULTI_PC_MEASUREMENTS ${jsonEncode(rig.measurements)}');
        await rig.open('pc1');
        expect(
          (await rig.db.collection('students_directory').get()).docs,
          hasLength(count),
        );
      },
      tags: const ['load'],
      timeout: const Timeout(Duration(minutes: 12)),
    );
  }
}

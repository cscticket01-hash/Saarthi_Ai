import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import '../lib/storage/windows_sqlite_store.dart';

const schoolA = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    schoolB = 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
Map<String, dynamic> fixture(String file) => {
      'version': 2,
      'activeProfileHint': 'A',
      'unknownRootMetadata': {'keep': true},
      'profiles': {
        'A': {
          'identity': {'schoolId': schoolA, 'schoolSyncId': schoolA},
          'unknownProfileMetadata': 'retained',
          'collections': {
            for (final name in [
              'students_directory',
              'teachers_directory',
              'attendance_records',
              'attendance_logs',
              'teacher_attendance',
              'school_notices',
              'school_config',
              'school_settings',
              'school_calendar',
              'fee_settings',
              'fee_ledger',
              'fee_payments',
              'teacher_salary',
              'exams',
              'exam_center_results',
              'exam_results',
              'documents'
            ])
              name: {
                'fixture-$name': {
                  'schoolId': schoolA,
                  'value': 'বাংলা हिन्दी',
                  'timestamp': {'__type': 'timestamp', 'ms': 1791500000123},
                  '_syncRevision': 'revision-$name',
                  'originalPath': file
                }
              },
            'empty_collection': <String, dynamic>{},
            '_windows_firebase_outbox': {
              'fee': {
                'schoolId': schoolA,
                'collection': 'fee_payments',
                'documentId': 'fixture-fee_payments',
                'operationId': 'original-fee-operation',
                'baseCloudRevision': 'old-fee',
                'syncState': 'conflict',
                'retryCount': 4,
                'data': {'amount': 100}
              },
              'doc1': {
                'schoolId': schoolA,
                'collection': 'documents',
                'documentId': 'doc1',
                'operationId': 'original-document-operation-1',
                'syncState': 'conflict',
                'data': {'originalPath': file}
              },
              'doc2': {
                'schoolId': schoolA,
                'collection': 'documents',
                'documentId': 'doc2',
                'operationId': 'original-document-operation-2',
                'syncState': 'conflict',
                'data': {'originalPath': file}
              }
            },
            '_windows_document_outbox': {
              'file': {
                'schoolId': schoolA,
                'localPath': file,
                'optimizedPath': file,
                'syncState': 'retry',
                'retryCount': 2,
                'documentRevision': 'original-doc-revision'
              }
            },
            '_windows_sync_receipts': {
              'ack': {
                'schoolId': schoolA,
                'operationId': 'ack',
                'recordRevision': 'verified-ack',
                'acknowledgedAt': 1234
              }
            },
            '_windows_sync_conflict_history': {
              'old': {
                'schoolId': schoolA,
                'data': {'amount': 90}
              }
            }
          }
        },
        'B': {
          'identity': {'schoolId': schoolB},
          'collections': {
            'students_directory': {
              'same-id': {'schoolId': schoolB, 'name': 'School B only'}
            }
          }
        },
      }
    };
void main() {
  test('100000 records across 17 categories survive explicit migration with queue evidence', () async {
    final dir = await Directory.systemTemp.createTemp('vs-sql-large-migration-');
    final root = fixture('retained-photo.jpg');
    final collections = root['profiles']['A']['collections'] as Map;
    final categories = collections.keys.where((name) => !name.toString().startsWith('_') && name != 'empty_collection').toList();
    expect(categories.length, 17);
    for (var i = 0; i < 100000; i++) {
      collections[categories[i % 17]]['synthetic-$i'] = {
        'schoolId': schoolA, '_syncRevision': 'revision-$i',
        'operationId': 'operation-$i', 'originalPath': 'retained-photo.jpg', 'value': i
      };
    }
    final source = File('${dir.path}/local_database_v1.json');
    final original = jsonEncode(root);
    await source.writeAsString(original, flush: true);
    await WindowsSqliteMigration.migrate(dir, approved: true);
    expect(await source.readAsString(), original);
    final reopened = await WindowsSqliteStore.open('${dir.path}/${WindowsSqliteStore.databaseName}');
    try {
      expect(await reopened.inventory(), sqliteInventory(root));
      expect((await reopened.inventory())['pendingStates'], {'conflict': 3, 'retry': 1});
      expect((await reopened.readDocument('A', categories[99999 % 17], 'synthetic-99999'))!['operationId'], 'operation-99999');
      await reopened.verify();
    } finally { await reopened.close(); }
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('schema reopen preserves data and a newer schema refuses downgrade', () async {
    final dir = await Directory.systemTemp.createTemp('vs-sql-schema-');
    final path = '${dir.path}/${WindowsSqliteStore.databaseName}';
    final first = await WindowsSqliteStore.open(path);
    await first.writeRoot(fixture('original.pdf'));
    final expected = await first.inventory();
    await first.close();
    final reopened = await WindowsSqliteStore.open(path);
    expect(await reopened.inventory(), expected);
    await reopened.close();
    final raw = sqlite3.open(path);
    expect(raw.select('PRAGMA user_version').single.values.first, 1);
    final count = raw.select('SELECT COUNT(*) AS n FROM records').single['n'];
    raw.execute('PRAGMA user_version=2');
    raw.dispose();
    await expectLater(WindowsSqliteStore.open(path), throwsStateError);
    final retained = sqlite3.open(path);
    try {
      expect(retained.select('PRAGMA user_version').single.values.first, 2);
      expect(retained.select('SELECT COUNT(*) AS n FROM records').single['n'], count);
      expect(retained.select('PRAGMA integrity_check').single.values.first, 'ok');
    } finally { retained.dispose(); }
  });

  test('migration approval is mandatory, including isolated copies', () async {
    final dir = await Directory.systemTemp.createTemp('vs-sql-consent-');
    await expectLater(
        WindowsSqliteMigration.migrate(dir, approved: false), throwsStateError);
    expect(await dir.list().isEmpty, true);
  });
  test('orphan WAL is retained and blocks migration cutover', () async {
    final dir = await Directory.systemTemp.createTemp('vs-sql-orphan-');
    final source = File('${dir.path}/local_database_v1.json');
    await source.writeAsString(jsonEncode(fixture('retained.pdf')));
    final wal = File('${dir.path}/${WindowsSqliteStore.databaseName}-wal');
    await wal.writeAsString('recovery evidence');
    await expectLater(
        WindowsSqliteMigration.migrate(dir, approved: true), throwsStateError);
    expect(await wal.readAsString(), 'recovery evidence');
    expect(
        await File('${dir.path}/${WindowsSqliteStore.databaseName}').exists(),
        false);
  });
  test('rollback with missing SQLite never creates an empty database',
      () async {
    final dir = await Directory.systemTemp.createTemp('vs-sql-no-rollback-');
    await expectLater(
        WindowsSqliteMigration.rollback(dir, approved: true), throwsStateError);
    expect(await dir.list().isEmpty, true);
  });
  test(
      '17 categories, 3 conflicts, original files, queue IDs and ACK history survive exact verified migration',
      () async {
    final dir = await Directory.systemTemp.createTemp('vs-sql-migrate-');
    final doc = File('${dir.path}/LocalFiles/A/original.pdf');
    await doc.parent.create(recursive: true);
    await doc.writeAsBytes(List.generate(2048, (i) => i % 251), flush: true);
    final root = fixture(doc.path),
        json = File('${dir.path}/local_database_v1.json');
    final original = jsonEncode(root);
    await json.writeAsString(original, flush: true);
    await File('${json.path}.pending').writeAsString(original, flush: true);
    await File('${json.path}.bak').writeAsString(original, flush: true);
    final proof = await WindowsSqliteMigration.migrate(dir, approved: true);
    expect(await json.readAsString(), original);
    expect(await File('${json.path}.pending').readAsString(), original);
    expect(await File('${json.path}.bak').readAsString(), original);
    final store = await WindowsSqliteStore.open(
        '${dir.path}/${WindowsSqliteStore.databaseName}');
    try {
      expect(await store.inventory(), sqliteInventory(root));
      expect((await store.inventory())['pendingStates'],
          {'conflict': 3, 'retry': 1});
      expect(
          await store.readDocument('A', '_windows_firebase_outbox', 'fee'),
          root['profiles']['A']['collections']['_windows_firebase_outbox']
              ['fee']);
      expect(await store.readDocument('A', 'students_directory', 'same-id'),
          isNull);
      expect(
          (await store.readDocument(
              'B', 'students_directory', 'same-id'))!['schoolId'],
          schoolB);
      expect((await sha256.bind(doc.openRead()).first).toString(),
          (proof['fileHashes'] as Map).values.single);
      expect(
          await File('${proof['backup']}/LocalFiles/A/original.pdf')
              .readAsBytes(),
          await doc.readAsBytes());
    } finally {
      await store.close();
    }
  });
  for (final stage in [
    'backupComplete',
    'sqliteWritten',
    'validated',
    'cutover'
  ]) {
    test(
        'restart at $stage retains original and safely resumes/cutovers without losing queues',
        () async {
      final dir = await Directory.systemTemp.createTemp('vs-sql-interrupt-');
      final root = fixture('retained.pdf'),
          source = File('${dir.path}/local_database_v1.json');
      final original = jsonEncode(root);
      await source.writeAsString(original, flush: true);
      await expectLater(
          WindowsSqliteMigration.migrate(dir, approved: true,
              interruption: (name) async {
            if (name == stage)
              throw StateError('Injected process interruption');
          }),
          throwsStateError);
      expect(await source.readAsString(), original);
      final file = File('${dir.path}/${WindowsSqliteStore.databaseName}');
      if (stage != 'cutover') {
        expect(await file.exists(), false);
        expect(
            sqliteInventory(Map<String, dynamic>.from(
                jsonDecode(await source.readAsString()) as Map)),
            sqliteInventory(root));
        await WindowsSqliteMigration.migrate(dir, approved: true);
      }
      final reopened = await WindowsSqliteStore.open(file.path);
      try {
        expect(await reopened.inventory(), sqliteInventory(root));
      } finally {
        await reopened.close();
      }
    });
  }
  test('concurrent legacy edits abort cutover and retain newer original',
      () async {
    final dir = await Directory.systemTemp.createTemp('vs-sql-concurrent-');
    final source = File('${dir.path}/local_database_v1.json');
    final original = fixture('original.pdf');
    await source.writeAsString(jsonEncode(original));
    await expectLater(
        WindowsSqliteMigration.migrate(dir, approved: true,
            interruption: (stage) async {
          if (stage == 'validated') {
            original['newerEdit'] = 'retained';
            await source.writeAsString(jsonEncode(original), flush: true);
          }
        }),
        throwsStateError);
    expect((jsonDecode(await source.readAsString()) as Map)['newerEdit'],
        'retained');
    expect(
        await File('${dir.path}/${WindowsSqliteStore.databaseName}').exists(),
        false);
  });
  test(
      'invalid JSON and all corrupt generations fail closed without resetting anything',
      () async {
    final dir = await Directory.systemTemp.createTemp('vs-sql-invalid-');
    final source = File('${dir.path}/local_database_v1.json');
    await source.writeAsString('{truncated', flush: true);
    await expectLater(
        WindowsSqliteMigration.migrate(dir, approved: true), throwsStateError);
    expect(await source.readAsString(), '{truncated');
    expect(
        await File('${dir.path}/${WindowsSqliteStore.databaseName}').exists(),
        false);
  });
  test(
      'valid pending generation recovers corrupt primary without replacing primary bytes',
      () async {
    final dir = await Directory.systemTemp.createTemp('vs-sql-pending-');
    final source = File('${dir.path}/local_database_v1.json');
    await source.writeAsString('{truncated');
    await File('${source.path}.pending')
        .writeAsString(jsonEncode(fixture('original.pdf')));
    final proof = await WindowsSqliteMigration.migrate(dir, approved: true);
    expect(proof['selectedGeneration'], 'local_database_v1.json.pending');
    expect(await source.readAsString(), '{truncated');
  });
  test(
      'rollback retains SQL generation and original; post-migration edits prohibit stale JSON rollback',
      () async {
    final dir = await Directory.systemTemp.createTemp('vs-sql-rollback-');
    final source = File('${dir.path}/local_database_v1.json');
    final original = jsonEncode(fixture('original.pdf'));
    await source.writeAsString(original);
    await WindowsSqliteMigration.migrate(dir, approved: true);
    await WindowsSqliteMigration.rollback(dir, approved: true);
    expect(await source.readAsString(), original);
    expect(
        (await dir.list().toList()).any((e) => e.path.contains('.rollback-')),
        true);
    await WindowsSqliteMigration.migrate(dir, approved: true);
    final store = await WindowsSqliteStore.open(
        '${dir.path}/${WindowsSqliteStore.databaseName}');
    final root = await store.readRoot('A');
    root['profiles']['A']['collections']['school_notices']
        ['newer'] = {'schoolId': schoolA, 'title': 'Newer SQLite edit'};
    await store.writeRoot(root);
    await store.close();
    await expectLater(
        WindowsSqliteMigration.rollback(dir, approved: true), throwsStateError);
    expect(
        await File('${dir.path}/${WindowsSqliteStore.databaseName}').exists(),
        true);
    expect(await source.readAsString(), original);
  });
  test(
      'local record and outbox commit atomically, failed transaction changes neither',
      () async {
    final dir = await Directory.systemTemp.createTemp('vs-sql-atomic-');
    final store = await WindowsSqliteStore.open(
        '${dir.path}/${WindowsSqliteStore.databaseName}');
    try {
      final root = fixture('original.pdf');
      await store.writeRoot(root);
      final before = await store.inventory();
      final edit = await store.readRoot('A');
      edit['profiles']['A']['collections']['students_directory']
          ['new'] = {'schoolId': schoolA, 'name': 'New'};
      edit['profiles']['A']['collections']['_windows_firebase_outbox']
          ['new'] = {
        'schoolId': schoolA,
        'operationId': 'stable-new-op',
        'syncState': 'pending'
      };
      await expectLater(
          store.writeRoot(edit, failBeforeCommit: true), throwsStateError);
      expect(await store.inventory(), before);
      await store.writeRoot(edit);
      await store.close();
      final reopened = await WindowsSqliteStore.open(
          '${dir.path}/${WindowsSqliteStore.databaseName}');
      try {
        expect(
            (await reopened.readDocument(
                'A', '_windows_firebase_outbox', 'new'))!['operationId'],
            'stable-new-op');
        expect(
            (await reopened.readDocument(
                'A', 'students_directory', 'new'))!['name'],
            'New');
      } finally {
        await reopened.close();
      }
    } finally {
      await store.close();
    }
  });
  test(
      'scoped point updates preserve all unloaded records and foreign profiles',
      () async {
    final dir = await Directory.systemTemp.createTemp('vs-sql-point-');
    final store = await WindowsSqliteStore.open(
        '${dir.path}/${WindowsSqliteStore.databaseName}');
    try {
      final root = fixture('original.pdf');
      root['profiles']['A']['collections']['students_directory']
          ['unloaded'] = {'name': 'Keep'};
      await store.writeRoot(root);
      final edit = await store.readRoot('A', collections: {
        'students_directory'
      }, recordScope: {
        'students_directory': ['fixture-students_directory']
      });
      edit['profiles']['A']['collections']['students_directory']
          ['fixture-students_directory']['name'] = 'Updated';
      await store.writeRoot(edit);
      expect(
          (await store.readDocument(
              'A', 'students_directory', 'unloaded'))!['name'],
          'Keep');
      expect(
          (await store.readDocument(
              'B', 'students_directory', 'same-id'))!['name'],
          'School B only');
      expect(
          (await store.readDocument(
              'A', 'fee_payments', 'fixture-fee_payments'))!['_syncRevision'],
          'revision-fee_payments');
    } finally {
      await store.close();
    }
  });
  test(
      'stale storage generation refuses to overwrite another connection newer commit',
      () async {
    final dir = await Directory.systemTemp.createTemp('vs-sql-cas-');
    final path = '${dir.path}/${WindowsSqliteStore.databaseName}';
    final one = await WindowsSqliteStore.open(path);
    await one.writeRoot(fixture('original.pdf'));
    final two = await WindowsSqliteStore.open(path);
    try {
      final stale = await one.readRoot('A'), fresh = await two.readRoot('A');
      fresh['profiles']['A']['collections']['school_notices']
          ['new'] = {'title': 'New'};
      await two.writeRoot(fresh);
      await expectLater(one.writeRoot(stale), throwsStateError);
      expect((await one.readDocument('A', 'school_notices', 'new'))!['title'],
          'New');
    } finally {
      await one.close();
      await two.close();
    }
  });
  test('corrupt SQLite never silently replaces itself with stale JSON',
      () async {
    final dir = await Directory.systemTemp.createTemp('vs-sql-corrupt-');
    final file = File('${dir.path}/${WindowsSqliteStore.databaseName}');
    await file.writeAsString('not sqlite');
    await expectLater(WindowsSqliteStore.open(file.path), throwsStateError);
    expect(await file.readAsString(), 'not sqlite');
  });
  test('consistent online backup preserves all records, metadata and outboxes',
      () async {
    final dir = await Directory.systemTemp.createTemp('vs-sql-backup-');
    final store = await WindowsSqliteStore.open(
        '${dir.path}/${WindowsSqliteStore.databaseName}');
    try {
      await store.writeRoot(fixture('original.pdf'));
      await store.snapshot('${dir.path}/backup.sqlite');
      final backup = await WindowsSqliteStore.open('${dir.path}/backup.sqlite');
      try {
        expect(await backup.inventory(), await store.inventory());
      } finally {
        await backup.close();
      }
    } finally {
      await store.close();
    }
  });
  test('legacy v1 data is quarantined, never assigned to selected school',
      () async {
    final dir = await Directory.systemTemp.createTemp('vs-sql-quarantine-');
    await File('${dir.path}/local_database_v1.json').writeAsString(jsonEncode({
      'version': 1,
      'collections': {
        'students_directory': {
          'legacy': {'name': 'Legacy'}
        }
      }
    }));
    await WindowsSqliteMigration.migrate(dir, approved: true);
    final store = await WindowsSqliteStore.open(
        '${dir.path}/${WindowsSqliteStore.databaseName}');
    try {
      expect(await store.readDocument('A', 'students_directory', 'legacy'),
          isNull);
      expect(
          (await store.readDocument(
              'legacy_v1_quarantine', 'students_directory', 'legacy'))!['name'],
          'Legacy');
    } finally {
      await store.close();
    }
  });
}

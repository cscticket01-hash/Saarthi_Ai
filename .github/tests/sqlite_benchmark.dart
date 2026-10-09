import 'dart:convert';
import 'dart:io';
import '../../lib/storage/windows_sqlite_store.dart';

Future<void> main() async {
  final evidence = <Map<String, dynamic>>[];
  Map<String, dynamic> stats(List<int> values) {
    values.sort();
    return {
      'samples': values.length,
      'p50Micros': values[(values.length * .5).ceil() - 1],
      'p95Micros': values[(values.length * .95).ceil() - 1]
    };
  }

  for (final count in [100, 1000, 10000, 100000]) {
    final dir = await Directory.systemTemp.createTemp('vs-sqlite-benchmark-');
    final sizes = {
      'students_directory': count * 6 ~/ 10,
      'fee_payments': count * 2 ~/ 10,
      'attendance_records': count * 2 ~/ 10
    };
    final source = {
      'version': 2,
      'profiles': {
        'A': {
          'identity': {'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'},
          'collections': {
            for (final collection in sizes.entries)
              collection.key: {
                for (var i = 0; i < collection.value; i++)
                  'record-$i': {
                    'name': 'Synthetic ${collection.key} $i',
                    'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                    'capturedAt': 123456789,
                    if (collection.key == 'fee_payments') 'amount': i * 100,
                    if (collection.key == 'attendance_records')
                      'entryCapturedAt': 123456789
                  }
              },
            '_windows_firebase_outbox': <String, dynamic>{}
          }
        }
      }
    };
    final json = File('${dir.path}/local_database_v1.json');
    await json.writeAsString(jsonEncode(source), flush: true);
    final store = await WindowsSqliteStore.open(
        '${dir.path}/${WindowsSqliteStore.databaseName}');
    await store.writeRoot(source);
    final jsonTimes = <int>[],
        sqlTimes = <int>[],
        jsonReads = <int>[],
        sqlReads = <int>[];
    for (var n = 0; n < 31; n++) {
      final c = Stopwatch()..start();
      final root = jsonDecode(await json.readAsString()) as Map;
      jsonReads.add(c.elapsedMicroseconds);
      root['profiles']['A']['collections']['students_directory']['record-0']
          ['sample'] = n;
      root['profiles']['A']['collections']['_windows_firebase_outbox']
          ['record-0'] = {
        'operationId': 'synthetic-$n',
        'syncState': 'pending'
      };
      final pending = File('${json.path}.pending');
      await pending.writeAsString(jsonEncode(root), flush: true);
      await json.copy('${json.path}.bak');
      await json.delete();
      await pending.rename(json.path);
      jsonTimes.add(c.elapsedMicroseconds);
      final read = Stopwatch()..start();
      await store.readDocument('A', 'students_directory', 'record-0');
      sqlReads.add(read.elapsedMicroseconds);
      final sc = Stopwatch()..start();
      final edit = await store.readRoot('A', collections: {
        'students_directory',
        '_windows_firebase_outbox'
      }, recordScope: {
        'students_directory': ['record-0']
      });
      edit['profiles']['A']['collections']['students_directory']['record-0']
          ['sample'] = n;
      edit['profiles']['A']['collections']['_windows_firebase_outbox']
          ['record-0'] = {
        'operationId': 'synthetic-$n',
        'syncState': 'pending'
      };
      await store.writeRoot(edit);
      sqlTimes.add(sc.elapsedMicroseconds);
    }
    if ((await store.readCollection('A', 'students_directory')).length !=
        sizes['students_directory']) throw StateError('Benchmark lost records');
    await store.close();
    for (final entry in sizes.entries) {
      final verified = await WindowsSqliteStore.open(
          '${dir.path}/${WindowsSqliteStore.databaseName}');
      try {
        if ((await verified.readCollection('A', entry.key)).length !=
            entry.value)
          throw StateError('Benchmark lost ${entry.key} records');
      } finally {
        await verified.close();
      }
    }
    evidence.add({
      'records': count,
      'recordsByCollection': sizes,
      'jsonDurableSave': stats(jsonTimes),
      'sqliteDurableSave': stats(sqlTimes),
      'jsonPointReadViaRoot': stats(jsonReads),
      'sqliteIndexedPointRead': stats(sqlReads)
    });
  }
  await Directory('build/sqlite-evidence').create(recursive: true);
  await File('build/sqlite-evidence/benchmark.json').writeAsString(jsonEncode({
    'scope':
        'Hosted synthetic local disk; 31 measured samples per size; no cloud load',
    'results': evidence
  }));
  print(jsonEncode(evidence));
}

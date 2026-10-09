import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import '../../lib/storage/windows_sqlite_store.dart';

Future<void> main(List<String> args) async {
  final store = await WindowsSqliteStore.open(args[0]);
  await store.close();
  final db = sqlite3.open(args[0]);
  db.execute('PRAGMA synchronous=FULL');
  db.execute('PRAGMA foreign_keys=ON');
  db.execute('INSERT OR IGNORE INTO profiles VALUES(?,?)',
      ['A', '{"identity":{"schoolId":"vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}']);
  for (final collection in ['students_directory', '_windows_firebase_outbox'])
    db.execute(
        'INSERT OR IGNORE INTO collections VALUES(?,?)', ['A', collection]);
  db.execute('BEGIN IMMEDIATE');
  db.execute('INSERT INTO records VALUES(?,?,?,?,?,?,?,?,?,?)', [
    'A',
    'students_directory',
    'crash-person',
    jsonEncode({
      'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'name': 'Synthetic crash fixture',
      'capturedAt': 123456789
    }),
    null,
    null,
    null,
    null,
    123456789,
    0
  ]);
  if (args[1] == 'committed') {
    db.execute('INSERT INTO records VALUES(?,?,?,?,?,?,?,?,?,?)', [
      'A',
      '_windows_firebase_outbox',
      'crash-op',
      jsonEncode({
        'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'operationId': 'unchanged-crash-operation',
        'syncState': 'pending',
        'capturedAt': 123456789
      }),
      null,
      null,
      'unchanged-crash-operation',
      'pending',
      123456789,
      0
    ]);
    db.execute('COMMIT');
  }
  stdout.writeln('READY_TO_KILL');
  await stdout.flush();
  await Completer<void>().future;
}

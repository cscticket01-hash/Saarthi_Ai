import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:sqflite/sqflite.dart';

/// Platform storage for SchoolSession's existing sync worker, not a second engine.
/// Payloads contain GPS/time metadata only; session, QR and permit tokens stay out.
class AttendanceStore {
  AttendanceStore({this.openDatabaseOverride});
  final Future<Database> Function()? openDatabaseOverride;
  Future<Database>? _database;
  Future<Database> get database => _database ??= _open();
  Future<Database> _open() async {
    if (openDatabaseOverride != null) return openDatabaseOverride!();
    return openDatabase('${await getDatabasesPath()}/vs_attendance_v2.db',
      version: 1, onConfigure: (db) async {
        await db.rawQuery('PRAGMA journal_mode=WAL');
        await db.execute('PRAGMA synchronous=FULL');
      }, onCreate: (db, _) => createSchema(db));
  }
  static Future<void> createSchema(Database db) async {
    await db.execute('CREATE TABLE attendance (id TEXT PRIMARY KEY, owner TEXT NOT NULL, capturedAt INTEGER NOT NULL, day TEXT NOT NULL, mode TEXT NOT NULL, payload TEXT NOT NULL, state TEXT NOT NULL, operationId TEXT, attempts INTEGER NOT NULL DEFAULT 0, nextAt INTEGER NOT NULL DEFAULT 0, claim TEXT, error TEXT NOT NULL DEFAULT \'\', completedAt INTEGER)');
    await db.execute('CREATE INDEX attendance_due ON attendance(owner, state, nextAt)');
  }
  static String owner(String endpoint, String school, String role, String person) =>
    sha256.convert(utf8.encode(jsonEncode([endpoint, school, role, person]))).toString();
  Future<String> save(String owner, String day, String mode, int capturedAt,
      Map<String, dynamic> gps) async {
    final id = sha256.convert(utf8.encode(jsonEncode([owner, day, mode]))).toString();
    await (await database).insert('attendance', {
      'id': id, 'owner': owner, 'day': day, 'mode': mode,
      'capturedAt': capturedAt, 'payload': jsonEncode({
        'latitude': gps['latitude'], 'longitude': gps['longitude'],
        'accuracy': gps['accuracy'], 'clientCapturedAt': capturedAt,
      }), 'state': 'pending',
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    return id; // Only after the durable transaction commits.
  }
  Future<List<Map<String, Object?>>> pending(String owner) async =>
    (await database).query('attendance', where: 'owner=? AND state<>?',
      whereArgs: [owner, 'completed'], orderBy: 'capturedAt', limit: 1000);
  Future<Map<String, Object?>?> claim(String owner, int now, String lease) async =>
    (await database).transaction((tx) async {
      final rows = await tx.query('attendance', where: 'owner=? AND state IN (?,?) AND nextAt<=?',
        whereArgs: [owner, 'pending', 'accepted', now], orderBy: 'capturedAt', limit: 1);
      if (rows.isEmpty) return null;
      final row = rows.first;
      await tx.update('attendance', {'claim': lease, 'nextAt': now + 90000},
        where: 'id=?', whereArgs: [row['id']]);
      return row;
    });
  Future<Map<String, Object?>> summary(String owner) async {
    final db = await database;
    final counts = (await db.rawQuery("SELECT COUNT(*) AS pending, SUM(CASE WHEN state='accepted' THEN 1 ELSE 0 END) AS accepted FROM attendance WHERE owner=? AND state<>'completed'", [owner])).single;
    final last = (await db.rawQuery("SELECT MAX(completedAt) AS ack FROM attendance WHERE owner=? AND state='completed'", [owner])).single;
    return {...counts, ...last};
  }
  Future<void> finish(String owner, String id, String lease, Map<String, Object?> values) async {
    await (await database).update('attendance', {...values, 'claim': null},
      where: 'id=? AND owner=? AND claim=? AND state<>?',
      whereArgs: [id, owner, lease, 'completed']);
  }
  Future<void> close() async { if (_database != null) await (await _database!).close(); }
}

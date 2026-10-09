import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

/// Existing Firestore-shaped APIs use this storage adapter. Cloud protocols and
/// operation identities are unchanged. SQLite work runs outside the UI isolate.
class WindowsSqliteStore {
  WindowsSqliteStore._(this.path, this._port, this._isolate, this._responses) {
    _subscription = _responses.listen((dynamic message) {
      final response = message as List;
      final pending = _waiting.remove(response[0]);
      if (response[1] == true) {
        pending?.complete(response[2]);
      } else {
        pending?.completeError(StateError(response[2] as String));
      }
    });
  }
  static const databaseName = 'local_database_v2.sqlite';
  final String path;
  final SendPort _port;
  final Isolate _isolate;
  final ReceivePort _responses;
  late final StreamSubscription<dynamic> _subscription;
  final _waiting = <int, Completer<dynamic>>{};
  int _next = 0;
  bool _closed = false;

  static Future<WindowsSqliteStore> open(String path) async {
    if (path.startsWith(r'\\') || path.startsWith('//')) {
      throw StateError(
          'SQLite WAL needs a local disk; network folders are unsupported.');
    }
    await File(path).parent.create(recursive: true);
    final ready = ReceivePort();
    final responses = ReceivePort();
    final isolate = await Isolate.spawn(_worker, [path, ready.sendPort]);
    final result = await ready.first as List;
    ready.close();
    if (result[0] != true) {
      responses.close();
      isolate.kill();
      throw StateError(result[1] as String);
    }
    return WindowsSqliteStore._(
        path, result[1] as SendPort, isolate, responses);
  }

  Future<dynamic> _call(String action, [dynamic arguments]) {
    if (_closed) throw StateError('SQLite connection is closed.');
    final id = ++_next;
    final completer = Completer<dynamic>();
    _waiting[id] = completer;
    _port.send([id, _responses.sendPort, action, arguments]);
    return completer.future;
  }

  Future<Map<String, dynamic>> readRoot(String profile,
          {Set<String>? collections,
          Map<String, List<String>>? recordScope}) async =>
      Map<String, dynamic>.from(
          await _call('root', [profile, collections?.toList(), recordScope]));
  Future<Map<String, dynamic>?> readDocument(
      String profile, String collection, String id) async {
    final result = await _call('document', [profile, collection, id]);
    return result == null ? null : Map<String, dynamic>.from(result);
  }

  Future<Map<String, Map<String, dynamic>>> readCollection(
          String profile, String collection) async =>
      (await _call('collection', [profile, collection]) as Map).map(
          (key, value) =>
              MapEntry(key as String, Map<String, dynamic>.from(value as Map)));
  Future<void> writeRoot(Map<String, dynamic> root,
          {bool failBeforeCommit = false}) async =>
      await _call('write', [root, failBeforeCommit]);
  Future<Map<String, dynamic>> inventory() async =>
      Map<String, dynamic>.from(await _call('inventory'));
  Future<Map<String, dynamic>> readAllRoot() async =>
      Map<String, dynamic>.from(await _call('allRoot'));
  Future<void> verify() async => await _call('verify');
  Future<Map<String, dynamic>> migrationProof() async =>
      Map<String, dynamic>.from(await _call('migrationProof'));
  Future<void> verifiedMigration(Map<String, dynamic> proof) async =>
      await _call('migration', proof);
  Future<void> snapshot(String target) async => await _call('snapshot', target);
  Future<void> close() async {
    if (_closed) return;
    await _call('close');
    _closed = true;
    await _subscription.cancel();
    _responses.close();
    _isolate.kill();
  }

  static void _worker(List<dynamic> setup) {
    final reply = setup[1] as SendPort;
    _SqliteDriver driver;
    try {
      driver = _SqliteDriver(setup[0] as String);
    } catch (_) {
      reply.send([
        false,
        'SQLite open/integrity check failed. Existing files retained; recovery required.'
      ]);
      return;
    }
    final incoming = ReceivePort();
    reply.send([true, incoming.sendPort]);
    incoming.listen((dynamic message) {
      final request = message as List;
      final output = request[1] as SendPort;
      try {
        final result = driver.dispatch(request[2] as String, request[3]);
        output.send([request[0], true, result]);
        if (request[2] == 'close') incoming.close();
      } catch (e) {
        // Never expose row payloads, file contents or credentials in error UI.
        output.send([
          request[0],
          false,
          e is StateError
              ? e.message.toString()
              : 'SQLite transaction failed; pending records retained.'
        ]);
      }
    });
  }
}

class _SqliteDriver {
  _SqliteDriver(String path) : db = sqlite3.open(path) {
    db.execute('PRAGMA busy_timeout=5000');
    final version = db.select('PRAGMA user_version').single.values.first as int;
    if (version > 1) {
      db.close();
      throw StateError('Newer database schema; downgrade blocked.');
    }
    // A single worker/connection owns normal app writes. The bundled SQLite
    // also must contain the 2026 WAL-reset fix before enabling WAL.
    final nativeVersionParts =
        (db.select('SELECT sqlite_version() AS v').single['v'] as String)
            .split('.')
            .map(int.parse)
            .toList();
    final nativeVersion = nativeVersionParts[0] * 1000000 +
        nativeVersionParts[1] * 1000 +
        nativeVersionParts[2];
    if (nativeVersion < 3051003 &&
        nativeVersion != 3050007 &&
        nativeVersion != 3044006) {
      db.close();
      throw StateError('A WAL-safe SQLite build is required.');
    }
    db.execute('PRAGMA journal_mode=WAL');
    db.execute('PRAGMA synchronous=FULL');
    db.execute('PRAGMA foreign_keys=ON');
    db.execute('PRAGMA wal_autocheckpoint=1000');
    db.execute('PRAGMA trusted_schema=OFF');
    db.execute(
        '''CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID''');
    db.execute(
        '''CREATE TABLE IF NOT EXISTS profiles(id TEXT PRIMARY KEY, content TEXT NOT NULL) WITHOUT ROWID''');
    db.execute(
        '''CREATE TABLE IF NOT EXISTS collections(profile TEXT NOT NULL, name TEXT NOT NULL,
      PRIMARY KEY(profile,name), FOREIGN KEY(profile) REFERENCES profiles(id)) WITHOUT ROWID''');
    db.execute(
        '''CREATE TABLE IF NOT EXISTS records(profile TEXT NOT NULL, collection TEXT NOT NULL, id TEXT NOT NULL,
      content TEXT NOT NULL, school_id TEXT, revision TEXT, operation_id TEXT, sync_state TEXT,
      captured_at INTEGER, deleted INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY(profile,collection,id), FOREIGN KEY(profile,collection) REFERENCES collections(profile,name)) WITHOUT ROWID''');
    db.execute(
        'CREATE INDEX IF NOT EXISTS pending_state ON records(profile,collection,sync_state)');
    db.execute(
        'CREATE INDEX IF NOT EXISTS operation_identity ON records(profile,operation_id)');
    db.execute(
        'CREATE INDEX IF NOT EXISTS school_capture ON records(profile,school_id,collection,captured_at)');
    db.execute("INSERT OR IGNORE INTO metadata VALUES('generation','0')");
    db.execute(
        "INSERT OR IGNORE INTO metadata VALUES('root','{\"version\":2}')");
    db.execute('PRAGMA user_version=1');
    verify();
  }
  final Database db;
  int get generation => int.parse(db
      .select("SELECT value FROM metadata WHERE key='generation'")
      .single['value'] as String);
  void verify() {
    if (db
            .select('PRAGMA quick_check')
            .any((row) => row.values.first != 'ok') ||
        db.select('PRAGMA foreign_key_check').isNotEmpty) {
      throw StateError(
          'SQLite integrity failed. Writes blocked; original files retained.');
    }
  }

  Map<String, dynamic> collection(String profile, String name) => {
        for (final row in db.select(
            'SELECT id,content FROM records WHERE profile=? AND collection=?',
            [profile, name]))
          row['id'] as String: jsonDecode(row['content'] as String),
      };
  Map<String, dynamic> root(String? profile, List<dynamic>? names,
      [Map? recordScope]) {
    final result = Map<String, dynamic>.from(jsonDecode(db
        .select("SELECT value FROM metadata WHERE key='root'")
        .single['value'] as String) as Map);
    final profiles = <String, dynamic>{};
    for (final row in db.select('SELECT id,content FROM profiles')) {
      final id = row['id'] as String;
      final saved = Map<String, dynamic>.from(
          jsonDecode(row['content'] as String) as Map);
      final collections = <String, dynamic>{};
      if (profile == null || id == profile) {
        for (final item in db
            .select('SELECT name FROM collections WHERE profile=?', [id])) {
          final name = item['name'] as String;
          if (names == null || names.contains(name))
            collections[name] = recordScope?[name] is List
                ? {
                    for (final row in db.select(
                        'SELECT id,content FROM records WHERE profile=? AND collection=? AND id IN (${List.filled((recordScope![name] as List).length, "?").join(",")})',
                        [id, name, ...recordScope[name] as List]))
                      row['id'] as String: jsonDecode(row['content'] as String)
                  }
                : collection(id, name);
        }
      }
      saved['collections'] = collections;
      profiles[id] = saved;
    }
    result['profiles'] = profiles;
    result['_sqliteGeneration'] = generation;
    if (recordScope != null) result['_sqliteRecordScope'] = recordScope;
    return result;
  }

  dynamic dispatch(String action, dynamic args) {
    switch (action) {
      case 'allRoot':
        return root(null, null);
      case 'root':
        return root(args[0] as String, args[1] as List?,
            args.length > 2 ? args[2] as Map? : null);
      case 'document':
        final rows = db.select(
            'SELECT content FROM records WHERE profile=? AND collection=? AND id=?',
            List<Object?>.from(args as List));
        return rows.isEmpty
            ? null
            : jsonDecode(rows.single['content'] as String);
      case 'collection':
        return collection(args[0] as String, args[1] as String);
      case 'write':
        write(Map<String, dynamic>.from(args[0] as Map), args[1] == true);
        return null;
      case 'inventory':
        return sqliteInventory(root(null, null));
      case 'migrationProof':
        return {
          'generation': generation,
          'proof': jsonDecode(db
              .select("SELECT value FROM metadata WHERE key='migration'")
              .single['value'] as String)
        };
      case 'verify':
        verify();
        return null;
      case 'migration':
        db.execute("INSERT OR REPLACE INTO metadata VALUES('migration',?)",
            [jsonEncode(args)]);
        return null;
      case 'snapshot':
        verify();
        if (File(args as String).existsSync())
          throw StateError('Backup destination already exists.');
        db.execute('VACUUM INTO ?', [args]);
        return null;
      case 'close':
        db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
        db.close();
        return null;
      default:
        throw StateError('Unknown storage command.');
    }
  }

  void write(Map<String, dynamic> value, bool fail) {
    db.execute('BEGIN IMMEDIATE');
    try {
      if (value['_sqliteGeneration'] != null &&
          value['_sqliteGeneration'] != generation) {
        throw StateError(
            'Local database changed concurrently. Reopen and retry; newer data retained.');
      }
      final metadata = {...value}
        ..remove('profiles')
        ..remove('_sqliteGeneration')
        ..remove('_sqliteRecordScope');
      db.execute("UPDATE metadata SET value=? WHERE key='root'",
          [jsonEncode(metadata)]);
      final insert =
          db.prepare('''INSERT INTO records VALUES(?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(profile,collection,id) DO UPDATE SET content=excluded.content,school_id=excluded.school_id,
        revision=excluded.revision,operation_id=excluded.operation_id,sync_state=excluded.sync_state,
        captured_at=excluded.captured_at,deleted=excluded.deleted''');
      try {
        for (final profile in (value['profiles'] as Map).entries) {
          final data = Map<String, dynamic>.from(profile.value as Map);
          final collections = data.remove('collections') as Map? ?? {};
          db.execute(
              'INSERT INTO profiles VALUES(?,?) ON CONFLICT(id) DO UPDATE SET content=excluded.content',
              [profile.key, jsonEncode(data)]);
          for (final col in collections.entries) {
            db.execute('INSERT OR IGNORE INTO collections VALUES(?,?)',
                [profile.key, col.key]);
            final scope =
                (value['_sqliteRecordScope'] as Map?)?[col.key] as List?;
            final old = <String, String>{
              for (final row in db.select(
                  scope == null
                      ? 'SELECT id,content FROM records WHERE profile=? AND collection=?'
                      : 'SELECT id,content FROM records WHERE profile=? AND collection=? AND id IN (${List.filled(scope.length, "?").join(",")})',
                  [profile.key, col.key, if (scope != null) ...scope]))
                row['id'] as String: row['content'] as String
            };
            for (final record in (col.value as Map).entries) {
              if (record.value is! Map)
                throw StateError(
                    'Invalid record shape; migration/write aborted.');
              final content = jsonEncode(record.value);
              final previous = old.remove(record.key);
              if (previous == content) continue;
              final r = record.value as Map;
              final captured = r['entryCapturedAt'] ?? r['capturedAt'];
              insert.execute([
                profile.key,
                col.key,
                record.key,
                content,
                r['schoolId'] is String ? r['schoolId'] : null,
                r['_syncRevision'] is String ? r['_syncRevision'] : null,
                r['operationId'] is String ? r['operationId'] : null,
                r['syncState'] is String ? r['syncState'] : null,
                captured is int ? captured : null,
                r['_syncDeleted'] == true ? 1 : 0
              ]);
            }
            for (final id in old.keys)
              db.execute(
                  'DELETE FROM records WHERE profile=? AND collection=? AND id=?',
                  [profile.key, col.key, id]);
          }
        }
      } finally {
        insert.close();
      }
      if (fail) throw StateError('Injected pre-commit interruption');
      db.execute(
          "UPDATE metadata SET value=CAST(value AS INTEGER)+1 WHERE key='generation'");
      db.execute('COMMIT');
    } catch (_) {
      db.execute('ROLLBACK');
      rethrow;
    }
  }
}

String canonicalLocalJson(dynamic value) {
  dynamic sort(dynamic input) {
    if (input is Map) {
      final keys = input.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sort(input[key])};
    }
    if (input is List) return input.map(sort).toList();
    return input;
  }

  return jsonEncode(sort(value));
}

Map<String, dynamic> sqliteInventory(Map<String, dynamic> root) {
  final clean = {...root}
    ..remove('_sqliteGeneration')
    ..remove('_sqliteRecordScope');
  final counts = <String, int>{};
  final pending = <String, int>{};
  var records = 0;
  for (final profile in (clean['profiles'] as Map).entries) {
    for (final col
        in ((profile.value as Map)['collections'] as Map? ?? {}).entries) {
      counts['${profile.key}/${col.key}'] = (col.value as Map).length;
      records += (col.value as Map).length;
      if (col.key.toString().contains('outbox')) {
        for (final item in (col.value as Map).values) {
          final state = (item as Map)['syncState']?.toString() ?? 'pending';
          pending[state] = (pending[state] ?? 0) + 1;
        }
      }
    }
  }
  return {
    'profiles': (clean['profiles'] as Map).length,
    'records': records,
    'counts': counts,
    'pendingStates': pending,
    'contentSha256':
        sha256.convert(utf8.encode(canonicalLocalJson(clean))).toString()
  };
}

/// Explicit consent applies to the installation/copy, not to cloud data.
/// No original JSON generation or LocalFiles is changed by this migrator.
class WindowsSqliteMigration {
  static Future<void> rollback(Directory directory,
      {required bool approved}) async {
    if (!approved) throw StateError('Explicit rollback approval required.');
    final path =
        '${directory.path}${Platform.pathSeparator}${WindowsSqliteStore.databaseName}';
    final store = await WindowsSqliteStore.open(path);
    try {
      final checkpoint = await store.migrationProof();
      if (checkpoint['generation'] != 1)
        throw StateError(
            'SQLite contains post-migration edits; automatic JSON rollback would lose them. Both retained.');
      final proof = checkpoint['proof'] as Map;
      for (final entry in (proof['sourceHashes'] as Map).entries) {
        final file =
            File('${directory.path}${Platform.pathSeparator}${entry.key}');
        if (!await file.exists() ||
            (await sha256.bind(file.openRead()).first).toString() !=
                entry.value)
          throw StateError('Original JSON changed; rollback blocked.');
      }
    } finally {
      await store.close();
    }
    await File(path)
        .rename('$path.rollback-${DateTime.now().microsecondsSinceEpoch}');
  }

  static Future<Map<String, dynamic>> migrate(Directory directory,
      {required bool approved,
      Future<void> Function(String stage)? interruption}) async {
    if (!approved)
      throw StateError('Explicit installation migration approval required.');
    await directory.create(recursive: true);
    final guard = await File(
            '${directory.path}${Platform.pathSeparator}sqlite_migration_v1.lock')
        .open(mode: FileMode.append);
    try {
      await guard.lock(FileLock.exclusive);
      return await _migrateLocked(directory,
          approved: approved, interruption: interruption);
    } finally {
      await guard.unlock();
      await guard.close();
    }
  }

  static Future<Map<String, dynamic>> _migrateLocked(Directory directory,
      {required bool approved,
      Future<void> Function(String stage)? interruption}) async {
    if (!approved)
      throw StateError('Explicit installation migration approval required.');
    final source = File(
        '${directory.path}${Platform.pathSeparator}local_database_v1.json');
    final finalFile = File(
        '${directory.path}${Platform.pathSeparator}${WindowsSqliteStore.databaseName}');
    if (await finalFile.exists())
      throw StateError('SQLite already exists; migration cannot overwrite it.');
    final nonce =
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
    final backup = Directory(
        '${directory.path}${Platform.pathSeparator}MigrationBackups${Platform.pathSeparator}$nonce');
    await backup.create(recursive: true);
    final journal = File(
        '${directory.path}${Platform.pathSeparator}sqlite_migration_v1.journal');
    Future<void> stage(String name) async {
      await journal.writeAsString(
          '${jsonEncode({
                'stage': name,
                'attempt': nonce,
                'at': DateTime.now().toUtc().toIso8601String()
              })}\n',
          mode: FileMode.append,
          flush: true);
      await interruption?.call(name);
    }

    final hashes = <String, String>{};
    final sourceCopies = <String, File>{};
    for (final suffix in ['', '.pending', '.bak']) {
      final file = File('${source.path}$suffix');
      if (await file.exists()) {
        final name = 'local_database_v1.json$suffix';
        final copied =
            await file.copy('${backup.path}${Platform.pathSeparator}$name');
        final hash = (await sha256.bind(file.openRead()).first).toString();
        if ((await sha256.bind(copied.openRead()).first).toString() != hash)
          throw StateError('Source backup verification failed.');
        hashes[name] = hash;
        sourceCopies[name] = copied;
      }
    }
    Map<String, dynamic>? root;
    String? selected;
    for (final entry in sourceCopies.entries) {
      try {
        final value = jsonDecode(await entry.value.readAsString());
        if (value is Map &&
            (value['profiles'] is Map || value['collections'] is Map)) {
          root = Map<String, dynamic>.from(value);
          selected = entry.key;
          break;
        }
      } catch (_) {}
    }
    if (root == null)
      throw StateError('No valid JSON generation. Original data retained.');
    if (root['collections'] is Map) {
      final profiles =
          Map<String, dynamic>.from(root['profiles'] as Map? ?? {});
      if ((root['collections'] as Map).isNotEmpty)
        profiles.putIfAbsent(
            'legacy_v1_quarantine',
            () => {
                  'identity': {
                    'mode': 'legacy-quarantine',
                    'note':
                        'Pre-isolation data preserved; never auto-activated.'
                  },
                  'collections': root!['collections']
                });
      root.remove('collections');
      root['profiles'] = profiles;
      root['version'] = 2;
    }
    final fileHashes = <String, String>{};
    Future<void> copyFiles(Directory from, Directory to) async {
      await to.create(recursive: true);
      await for (final entity in from.list(followLinks: false)) {
        final name = entity.uri.pathSegments.where((v) => v.isNotEmpty).last;
        if (entity is Link)
          throw StateError(
              'LocalFiles symbolic links require explicit review.');
        if (entity is Directory) {
          await copyFiles(
              entity, Directory('${to.path}${Platform.pathSeparator}$name'));
        }
        if (entity is File) {
          final relative = entity.path.substring(directory.path.length + 1);
          final hash = (await sha256.bind(entity.openRead()).first).toString();
          final copied =
              await entity.copy('${to.path}${Platform.pathSeparator}$name');
          if ((await sha256.bind(copied.openRead()).first).toString() != hash)
            throw StateError('LocalFiles backup verification failed.');
          fileHashes[relative] = hash;
        }
      }
    }

    final files =
        Directory('${directory.path}${Platform.pathSeparator}LocalFiles');
    if (await files.exists())
      await copyFiles(files,
          Directory('${backup.path}${Platform.pathSeparator}LocalFiles'));
    final expected = sqliteInventory(root);
    final proof = {
      'sourceHashes': hashes,
      'selectedGeneration': selected,
      'fileHashes': fileHashes,
      'inventory': expected,
      'backup': backup.path
    };
    await File('${backup.path}${Platform.pathSeparator}manifest.json')
        .writeAsString(jsonEncode(proof), flush: true);
    // Sealed generations are never reused or overwritten by this application.
    final sealed = await Process.run(
        Platform.isWindows ? 'attrib' : 'chmod',
        Platform.isWindows
            ? ['+R', '${backup.path}\\*', '/S']
            : ['-R', 'a-w', backup.path]);
    if (sealed.exitCode != 0)
      throw StateError(
          'Backup could not be write-protected. Migration stopped.');
    await stage('backupComplete');
    final temp = '${finalFile.path}.migrating-$nonce';
    final store = await WindowsSqliteStore.open(temp);
    try {
      await store.writeRoot(root);
      await stage('sqliteWritten');
      await store.verify();
      final actual = await store.inventory();
      if (canonicalLocalJson(actual) != canonicalLocalJson(expected))
        throw StateError('Migration content/count/outbox integrity mismatch.');
      await store.verifiedMigration(proof);
      await stage('validated');
    } finally {
      await store.close();
    }
    // Detect concurrent legacy edits/new files before the atomic cutover.
    for (final suffix in ['', '.pending', '.bak']) {
      final name = 'local_database_v1.json$suffix',
          file = File('${source.path}$suffix');
      if (await file.exists()) {
        if ((await sha256.bind(file.openRead()).first).toString() !=
            hashes[name])
          throw StateError(
              'JSON changed during migration. Original remains active.');
      } else if (hashes.containsKey(name)) {
        throw StateError('JSON generation changed during migration.');
      }
    }
    final nowFiles = <String, String>{};
    if (await files.exists()) {
      await for (final entity
          in files.list(recursive: true, followLinks: false)) {
        if (entity is Link)
          throw StateError('LocalFiles changed during migration.');
        if (entity is File)
          nowFiles[entity.path.substring(directory.path.length + 1)] =
              (await sha256.bind(entity.openRead()).first).toString();
      }
    }
    if (canonicalLocalJson(nowFiles) != canonicalLocalJson(fileHashes))
      throw StateError('LocalFiles changed during migration.');
    await File(temp).rename(finalFile.path);
    await stage('cutover');
    return proof;
  }
}

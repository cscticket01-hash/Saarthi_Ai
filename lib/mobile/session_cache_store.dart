import 'dart:convert';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart';

class SessionCacheSnapshot {
  const SessionCacheSnapshot(this.version, this.value);
  final int version;
  final String? value;
}
class StaleSessionCache extends StateError {
  StaleSessionCache() : super('Another app worker updated the session cache; reload before writing.');
}

/// One encrypted snapshot, fenced by SQLite's cross-isolate write transaction.
/// The secure key remains in platform secure storage; the database has no raw
/// session/QR/token. Tombstone versions prevent stale workers undoing logout.
class MobileSessionCacheStore {
  MobileSessionCacheStore({this.openDatabaseOverride,
    FlutterSecureStorage storage = const FlutterSecureStorage()}) : _secure=storage;
  final Future<Database> Function()? openDatabaseOverride;
  final FlutterSecureStorage _secure;
  Future<Database>? _database;
  int? _version, _lastOwnWriteVersion;
  final _cipher=AesGcm.with256bits();
  static const _keyName='vs_mobile_shared_cache_key_v1';
  Future<Database> get database => _database ??= _open();
  Future<Database> _open() async {
    if(openDatabaseOverride!=null)return openDatabaseOverride!();
    return openDatabase('${await getDatabasesPath()}/vs_mobile_session_v1.db',version:1,singleInstance:false,
      onConfigure:(db)async{await db.execute('PRAGMA busy_timeout=5000');await db.execute('PRAGMA synchronous=FULL');},
      onCreate:(db,_)=>createSchema(db));
  }
  static Future<void> createSchema(Database db)=>db.execute(
    'CREATE TABLE session_snapshot (id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, envelope TEXT)');
  Future<SecretKey> _key() async {
    var raw=await _secure.read(key:_keyName);
    if(raw==null){raw=base64Encode(await _cipher.newSecretKey().then((k)=>k.extractBytes()));await _secure.write(key:_keyName,value:raw);}
    final bytes=base64Decode(raw);
    if(bytes.length!=32)throw StateError('Shared session cache key is invalid; data retained.');
    return SecretKey(bytes);
  }
  Future<String?> _decode(Object? raw) async {
    if(raw==null)return null;
    final d=jsonDecode(raw as String) as Map;
    return utf8.decode(await _cipher.decrypt(SecretBox(base64Decode(d['cipher']),
      nonce:base64Decode(d['nonce']),mac:Mac(base64Decode(d['mac']))),
      secretKey:await _key(),aad:utf8.encode('vidya-mobile-session-v1')));
  }
  Future<String> _encode(String value) async {
    final box=await _cipher.encrypt(utf8.encode(value),secretKey:await _key(),
      aad:utf8.encode('vidya-mobile-session-v1'));
    return jsonEncode({'nonce':base64Encode(box.nonce),'cipher':base64Encode(box.cipherText),'mac':base64Encode(box.mac.bytes)});
  }
  Future<Map<String,Object?>> _row(Transaction tx) async {
    final rows=await tx.query('session_snapshot',where:'id=1');
    if(rows.isNotEmpty)return rows.single;
    // Migrate only once under the same database writer lock. A tombstone row
    // is deliberately never treated as a missing/migratable legacy cache.
    final legacy=await _secure.read(key:'vs_mobile_session');
    final row=<String,Object?>{'id':1,'version':0,'envelope':legacy==null?null:await _encode(legacy)};
    await tx.insert('session_snapshot',row);return row;
  }
  Future<SessionCacheSnapshot> readSnapshot() async {
    final db=await database;
    return db.transaction((tx)async{
      final row=await _row(tx),value=await _decode(row['envelope']);
      _version=row['version'] as int;
      return SessionCacheSnapshot(_version!,value);
    },exclusive:true);
  }
  Future<String?> read() async => (await readSnapshot()).value;
  Future<int> write(String value,{int? expectedVersion}) async {
    if(_version==null)await read();
    final expected=expectedVersion??_version,db=await database;
    final next=await db.transaction((tx)async{
      final row=await _row(tx);
      // Sequential writes already queued by this SAME owner may advance its
      // prior version. A read of another owner's newer version grants no write.
      // Explicit snapshot CAS is never bypassed by this owner's prior write.
      // Only an implicit queued write may follow a verified own commit.
      if(row['version']!=expected &&
          (expectedVersion!=null || row['version']!=_lastOwnWriteVersion)) {
        throw StaleSessionCache();
      }
      final version=(row['version'] as int)+1;
      await tx.update('session_snapshot',{'version':version,'envelope':await _encode(value)},where:'id=1 AND version=?',whereArgs:[row['version']]);return version;
    },exclusive:true);
    _version=next;_lastOwnWriteVersion=next;
    await _secure.delete(key:'vs_mobile_session');return next;
  }
  Future<int> clear(String? expectedQr) async {
    final db=await database;
    final next=await db.transaction((tx)async{
      final row=await _row(tx),raw=await _decode(row['envelope']);
      if(raw!=null&&(expectedQr==null||(jsonDecode(raw) as Map)['qr']!=expectedQr))throw StaleSessionCache();
      final version=(row['version'] as int)+1;
      await tx.update('session_snapshot',{'version':version,'envelope':null},where:'id=1');return version;
    },exclusive:true);
    _version=next;_lastOwnWriteVersion=next;
    await _secure.delete(key:'vs_mobile_session');
    return next;
  }
  Future<void> close() async {final db=_database;if(db!=null)await (await db).close();_database=null;}
}

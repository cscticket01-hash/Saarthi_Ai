import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;
import 'package:cryptography/cryptography.dart';

/// School-scoped portable backup. Decryption only creates a new staging folder;
/// existing storage is never activated, overwritten or deleted by this API.
class WindowsSchoolBackupExport {
  static const iterations = 310000;
  static const maxBytes = 128 * 1024 * 1024;
  static final _cipher = AesGcm.with256bits();
  static final _kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  );
  static final _random = Random.secure();
  static List<int> _randomBytes(int n) =>
      List.generate(n, (_) => _random.nextInt(256));
  static void _school(String school) {
    if (!RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school))
      throw StateError('School identity required');
  }

  static void _path(String path) {
    if (path.split('/').any(
          (p) =>
              p.isEmpty ||
              p == '.' ||
              p == '..' ||
              p.contains(String.fromCharCode(92)) ||
              RegExp(r'[\x00-\x1f]').hasMatch(p) ||
              p.endsWith('.') ||
              p.endsWith(' ') ||
              p.contains(':'),
        )) throw StateError('Unsafe backup path');
  }

  static dynamic _redact(
    dynamic value,
    List<String> excluded, [
    String path = 'records',
  ]) {
    if (value is Map) {
      final result = <String, dynamic>{};
      for (final e in value.entries) {
        final key = e.key.toString();
        if (RegExp(
          r'password|secret|token|credential|privatekey',
          caseSensitive: false,
        ).hasMatch(key)) {
          excluded.add('$path/$key');
          continue;
        }
        result[key] = _redact(e.value, excluded, '$path/$key');
      }
      return result;
    }
    if (value is List)
      return [
        for (var i = 0; i < value.length; i++)
          _redact(value[i], excluded, '$path/$i'),
      ];
    return value;
  }

  static Future<Map<String, dynamic>> export({
    required String schoolId,
    required String password,
    required Map<String, dynamic> snapshot,
    required Map<String, File> files,
    required File destination,
    required bool Function() stillSameSchool,
    List<String> missingData = const [],
  }) async {
    _school(schoolId);
    if (password.length < 12 || password.length > 1024)
      throw StateError('Use a backup password of at least 12 characters');
    if (!stillSameSchool() || snapshot['schoolId'] != schoolId)
      throw StateError('School changed');
    final excluded = <String>[];
    final sanitized = _redact(snapshot, excluded);
    final content = <String, List<int>>{
      'records/school_snapshot.json': utf8.encode(jsonEncode(sanitized)),
    };
    final missing = List<String>.from(missingData);
    var size = content.values.first.length;
    if (size > maxBytes)
      throw StateError('School snapshot exceeds export limit');
    for (final entry in files.entries) {
      _path(entry.key);
      final path = 'files/${entry.key}';
      if (await FileSystemEntity.type(entry.value.path, followLinks: false) !=
          FileSystemEntityType.file) {
        missing.add(path);
        continue;
      }
      final length = await entry.value.length();
      if (size + length > maxBytes)
        throw StateError(
          'Backup exceeds 128 MB safe export limit; originals retained',
        );
      final data = await entry.value.readAsBytes();
      size += data.length;
      if (size > maxBytes)
        throw StateError('Backup source changed beyond size limit');
      content[path] = data;
    }
    final manifest = {
      'version': 1,
      'schoolId': schoolId,
      'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
      'complete': missing.isEmpty,
      'missingData': missing,
      'excludedCredentialFields': excluded,
      'restoreFormat':
          'school-scoped-json-v1; staged import requires validation',
      'files': content.entries
          .map(
            (e) => {
              'path': e.key,
              'bytes': e.value.length,
              'sha256': sha256.convert(e.value).toString(),
            },
          )
          .toList(),
    };
    final plain = utf8.encode(
      jsonEncode({
        'manifest': manifest,
        'content': content.map(
          (key, value) => MapEntry(key, base64Encode(value)),
        ),
      }),
    );
    final salt = _randomBytes(16);
    final key = await _kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    final header = {
      'format': 'VS-SCHOOL-BACKUP',
      'version': 1,
      'schoolId': schoolId,
      'kdf': 'PBKDF2-HMAC-SHA256',
      'iterations': iterations,
      'salt': base64Encode(salt),
    };
    final box = await _cipher.encrypt(
      plain,
      secretKey: key,
      aad: utf8.encode(jsonEncode(header)),
    );
    final output = utf8.encode(
      jsonEncode({
        'header': header,
        'nonce': base64Encode(box.nonce),
        'ciphertext': base64Encode(box.cipherText),
        'mac': base64Encode(box.mac.bytes),
      }),
    );
    if (!stillSameSchool())
      throw StateError('School changed before export commit');
    if (await FileSystemEntity.type(destination.path, followLinks: false) !=
        FileSystemEntityType.notFound)
      throw StateError('Backup destination exists; retained');
    final temp = File(
      '${destination.path}.partial-${base64UrlEncode(_randomBytes(12))}',
    );
    try {
      await temp.writeAsBytes(output, flush: true);
      await _decrypt(
        temp,
        password,
        schoolId,
      ); // Authenticated readback before commit.
      if (!stillSameSchool() || await destination.exists())
        throw StateError('Export destination or school changed');
      await temp.rename(destination.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
    return manifest;
  }

  static Future<Map<String, dynamic>> _decrypt(
    File file,
    String password,
    String schoolId,
  ) async {
    _school(schoolId);
    if (password.length > 1024) throw StateError('Invalid password length');
    if (await file.length() > maxBytes * 3)
      throw StateError('Backup exceeds read limit');
    final envelope = jsonDecode(await file.readAsString()) as Map;
    final header = Map<String, dynamic>.from(envelope['header'] as Map);
    if (header['format'] != 'VS-SCHOOL-BACKUP' ||
        header['version'] != 1 ||
        header['schoolId'] != schoolId ||
        header['iterations'] != iterations ||
        header['kdf'] != 'PBKDF2-HMAC-SHA256')
      throw StateError('Unsupported or foreign-school backup');
    final nonce = base64Decode(envelope['nonce'] as String);
    final mac = base64Decode(envelope['mac'] as String);
    if (nonce.length != 12 || mac.length != 16)
      throw StateError('Invalid authentication fields');
    final salt = base64Decode(header['salt'] as String);
    if (salt.length != 16) throw StateError('Invalid backup salt');
    final key = await _kdf.deriveKey(
      secretKey: SecretKey(utf8.encode(password)),
      nonce: salt,
    );
    final plain = await _cipher.decrypt(
      SecretBox(
        base64Decode(envelope['ciphertext'] as String),
        nonce: nonce,
        mac: Mac(mac),
      ),
      secretKey: key,
      aad: utf8.encode(jsonEncode(header)),
    );
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(plain)) as Map);
  }

  static Future<Map<String, dynamic>> stageRestore({
    required File backup,
    required String password,
    required String schoolId,
    required Directory destination,
  }) async {
    final data = await _decrypt(backup, password, schoolId);
    final manifest = Map<String, dynamic>.from(data['manifest'] as Map);
    if (manifest['schoolId'] != schoolId || manifest['version'] != 1)
      throw StateError('Invalid manifest');
    final content = Map<String, dynamic>.from(data['content'] as Map);
    if (!content.containsKey('records/school_snapshot.json'))
      throw StateError('School snapshot missing');
    final verified = <String, List<int>>{};
    var size = 0;
    for (final raw in manifest['files'] as List) {
      final item = raw as Map;
      final path = item['path'] as String;
      _path(path);
      if (verified.containsKey(path)) throw StateError('Duplicate backup file');
      final bytes = base64Decode(content[path] as String);
      size += bytes.length;
      if (size > maxBytes ||
          bytes.length != item['bytes'] ||
          sha256.convert(bytes).toString() != item['sha256'])
        throw StateError('Backup integrity failure');
      verified[path] = bytes;
    }
    if (verified.length != content.length)
      throw StateError('Unlisted backup files');
    if (await FileSystemEntity.type(destination.path, followLinks: false) !=
        FileSystemEntityType.notFound)
      throw StateError('Restore destination exists; retained');
    final snapshot = jsonDecode(
      utf8.decode(verified['records/school_snapshot.json']!),
    );
    if (snapshot is! Map || snapshot['schoolId'] != schoolId)
      throw StateError('Snapshot school mismatch');
    final parent = await destination.parent.resolveSymbolicLinks();
    if (parent != destination.parent.absolute.path)
      throw StateError('Restore parent links require review');
    final backupPath = await backup.resolveSymbolicLinks();
    final target = destination.absolute.path;
    if (backupPath == target ||
        backupPath.startsWith('$target${Platform.pathSeparator}'))
      throw StateError('Separate restore directory required');
    final partial = Directory(
        '${destination.path}.partial-${base64UrlEncode(_randomBytes(12))}');
    await partial.create();
    try {
      for (final e in verified.entries) {
        final file = File('${partial.path}/${e.key}');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(e.value, flush: true);
      }
      await File('${partial.path}/manifest.json')
          .writeAsString(jsonEncode(manifest), flush: true);
      if (await FileSystemEntity.type(destination.path, followLinks: false) !=
          FileSystemEntityType.notFound)
        throw StateError('Restore destination changed; retained');
      await partial.rename(destination.path);
      return manifest;
    } finally {
      if (await partial.exists()) await partial.delete(recursive: true);
    }
  }
}

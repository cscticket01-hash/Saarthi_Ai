import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

/// Local generation readback. Hashes detect corruption, not malicious manifest replacement.
class WindowsBackupIntegrity {
  static const manifestName = 'backup_integrity_v1.json';

  static Future<void> seal(Directory root) async {
    final files = <Map<String, dynamic>>[];
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is Link) throw StateError('Backup link requires review');
      if (entity is! File) continue;
      final relative = entity.path.substring(root.path.length + 1).replaceAll(r'\', '/');
      if (relative == manifestName) continue;
      files.add({'path': relative, 'bytes': await entity.length(),
        'sha256': (await sha256.bind(entity.openRead()).first).toString()});
    }
    if (files.isEmpty) throw StateError('Empty backup cannot be verified');
    files.sort((a,b) => (a['path'] as String).compareTo(b['path'] as String));
    await File('${root.path}${Platform.pathSeparator}$manifestName').writeAsString(
      jsonEncode({'version': 1, 'createdAtUtc': DateTime.now().toUtc().toIso8601String(), 'files': files}), flush: true);
    await verify(root);
  }

  static Future<int> verify(Directory root) async {
    final manifest = File('${root.path}${Platform.pathSeparator}$manifestName');
    if (await manifest.length() > 10 * 1024 * 1024) throw StateError('Backup manifest exceeds review limit');
    final data = jsonDecode(await manifest.readAsString());
    if (data is! Map || data['version'] != 1 || data['files'] is! List || (data['files'] as List).isEmpty)
      throw StateError('Backup manifest is invalid');
    final seen = <String>{};
    for (final item in data['files'] as List) {
      if (item is! Map || item['path'] is! String || item['bytes'] is! int || item['sha256'] is! String)
        throw StateError('Backup entry is invalid');
      final path = item['path'] as String;
      final parts = path.split('/');
      if (parts.any((p) => p.isEmpty || p == '.' || p == '..' || p.contains(r'\') || p.contains(':')) ||
          path == manifestName || !seen.add(path)) throw StateError('Backup path requires review');
      var current = root.path;
      for (final part in parts) {
        current += '${Platform.pathSeparator}$part';
        if (await FileSystemEntity.type(current, followLinks: false) == FileSystemEntityType.link)
          throw StateError('Backup link requires review');
      }
      final file = File(current);
      if (!await file.exists() || await file.length() != item['bytes'] ||
          (await sha256.bind(file.openRead()).first).toString() != item['sha256'])
        throw StateError('Backup content verification failed');
    }
    return seen.length;
  }
}

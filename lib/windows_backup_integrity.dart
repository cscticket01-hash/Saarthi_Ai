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
    if (await FileSystemEntity.type(root.path, followLinks: false) != FileSystemEntityType.directory)
      throw StateError('Backup folder requires review');
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
    // Extra databases/files must not be silently admitted into a restore.
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is Link) throw StateError('Backup link requires review');
      if (entity is File) {
        final relative = entity.path.substring(root.path.length + 1).replaceAll(r'\', '/');
        if (relative != manifestName && !seen.contains(relative))
          throw StateError('Unlisted backup content requires review');
      }
    }
    return seen.length;
  }

  /// Readback rehearsal only: never activates a database or changes current data.
  /// A fresh destination prevents accidental overwrites, including earlier attempts.
  static Future<int> stageRestore(Directory backup, Directory destination) async {
    await verify(backup);
    final sourcePath = await backup.resolveSymbolicLinks();
    final targetPath = destination.absolute.path;
    final normalizedSource = sourcePath.replaceAll(r'\', '/').toLowerCase();
    final normalizedTarget = targetPath.replaceAll(r'\', '/').toLowerCase();
    if (normalizedTarget == normalizedSource || normalizedTarget.startsWith('$normalizedSource/') ||
        normalizedSource.startsWith('$normalizedTarget/'))
      throw StateError('Choose a separate restore rehearsal folder');
    if (await FileSystemEntity.type(destination.path, followLinks: false) != FileSystemEntityType.notFound)
      throw StateError('Restore destination already exists; retained without changes');
    // Resolve the parent before containment checks. Windows may legitimately
    // expand an 8.3 folder alias; it must not redirect a copy inside the backup.
    final parent = destination.parent;
    if (!await parent.exists())
      throw StateError('Restore parent requires review');
    final resolvedParent = (await parent.resolveSymbolicLinks()).replaceAll(r'\', '/').toLowerCase();
    final name = destination.uri.pathSegments.where((part) => part.isNotEmpty).last;
    final resolvedTarget = '$resolvedParent/${name.toLowerCase()}';
    if (resolvedTarget == normalizedSource || resolvedTarget.startsWith('$normalizedSource/') ||
        normalizedSource.startsWith('$resolvedTarget/'))
      throw StateError('Choose a separate restore rehearsal folder');
    await destination.create();
    await for (final entity in backup.list(recursive: true, followLinks: false)) {
      if (entity is Link) throw StateError('Backup changed during restore rehearsal');
      final relative = entity.path.substring(backup.path.length + 1);
      final target = '${destination.path}${Platform.pathSeparator}$relative';
      if (entity is Directory) await Directory(target).create(recursive: true);
      if (entity is File) {
        await File(target).parent.create(recursive: true);
        await entity.copy(target);
      }
    }
    // Recheck both generations to detect changes during copy. Failed staging is
    // retained for review and never becomes active school storage.
    final count = await verify(destination);
    await verify(backup);
    return count;
  }
}

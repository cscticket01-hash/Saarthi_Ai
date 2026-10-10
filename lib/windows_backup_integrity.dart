import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';

/// Local generation readback. Hashes detect corruption, not malicious manifest replacement.
class WindowsBackupIntegrity {
  static const manifestName = 'backup_integrity_v1.json';
  static final _restoring = <String>{};

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
    if (await FileSystemEntity.type(manifest.path, followLinks: false) != FileSystemEntityType.file)
      throw StateError('Backup manifest requires review');
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

  /// Resumes only a separately staged copy bound to the same verified manifest.
  /// Every reused file is hashed again; a checkpoint never certifies its bytes.
  /// The sibling checkpoint is retained and no database is activated here.
  static Future<int> resumeRestore(Directory backup, Directory destination,
      {Future<void> Function(int verifiedFiles)? onFileVerified}) async {
    await verify(backup);
    final source = (await backup.resolveSymbolicLinks()).replaceAll(r'\', '/').toLowerCase();
    if (!await destination.parent.exists()) throw StateError('Restore parent requires review');
    final parent = (await destination.parent.resolveSymbolicLinks()).replaceAll(r'\', '/').toLowerCase();
    final name = destination.uri.pathSegments.where((part) => part.isNotEmpty).last;
    final target = '$parent/${name.toLowerCase()}';
    if (target == source || target.startsWith('$source/') || source.startsWith('$target/'))
      throw StateError('Choose a separate restore folder');
    if (!_restoring.add(target)) throw StateError('Restore already in progress');
    try {
      final manifest = File('${backup.path}${Platform.pathSeparator}$manifestName');
      final manifestBytes = await manifest.readAsBytes();
      final digest = sha256.convert(manifestBytes).toString();
      final checkpoint = File('${destination.path}.restore-checkpoint.json');
      final expected = {'version': 1, 'manifestSha256': digest, 'source': source, 'target': target};
      final checkpointType = await FileSystemEntity.type(checkpoint.path, followLinks: false);
      final targetType = await FileSystemEntity.type(destination.path, followLinks: false);
      if (checkpointType == FileSystemEntityType.notFound) {
        if (targetType != FileSystemEntityType.notFound)
          throw StateError('Unrecognized restore destination retained');
        await checkpoint.writeAsString(jsonEncode(expected), flush: true);
      } else {
        if (checkpointType != FileSystemEntityType.file || await checkpoint.length() > 16384 ||
            jsonEncode(jsonDecode(await checkpoint.readAsString())) != jsonEncode(expected))
          throw StateError('Restore checkpoint does not match backup');
        if (targetType != FileSystemEntityType.directory && targetType != FileSystemEntityType.notFound)
          throw StateError('Restore destination requires review');
      }
      await destination.create();
      final entries = (jsonDecode(utf8.decode(manifestBytes)) as Map)['files'] as List;
      final allowed = {manifestName, ...entries.map((item) => (item as Map)['path'] as String)};
      await for (final entity in destination.list(recursive: true, followLinks: false)) {
        if (entity is Link) throw StateError('Restore link requires review');
        if (entity is File && !allowed.contains(entity.path.substring(destination.path.length + 1).replaceAll(r'\', '/')))
          throw StateError('Unrecognized restore content retained');
      }
      var count = 0;
      for (final raw in entries) {
        final entry = raw as Map;
        final relative = (entry['path'] as String).replaceAll('/', Platform.pathSeparator);
        final output = File('${destination.path}${Platform.pathSeparator}$relative');
        var current = destination.path;
        for (final part in (entry['path'] as String).split('/')) {
          current += '${Platform.pathSeparator}$part';
          if (await FileSystemEntity.type(current, followLinks: false) == FileSystemEntityType.link)
            throw StateError('Restore link requires review');
        }
        Future<bool> matches() async => await output.exists() && await output.length() == entry['bytes'] &&
            (await sha256.bind(output.openRead()).first).toString() == entry['sha256'];
        if (!await matches()) {
          await output.parent.create(recursive: true);
          // Recopy only this incomplete staging file; the backup is never changed.
          await File('${backup.path}${Platform.pathSeparator}$relative').copy(output.path);
          if (!await matches()) throw StateError('Restore file verification failed');
        }
        count++;
        if (onFileVerified != null) await onFileVerified(count);
      }
      await File('${destination.path}${Platform.pathSeparator}$manifestName').writeAsBytes(manifestBytes, flush: true);
      await verify(destination);
      await verify(backup);
      if (sha256.convert(await manifest.readAsBytes()).toString() != digest)
        throw StateError('Backup generation changed during restore');
      return count;
    } finally {
      _restoring.remove(target);
    }
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

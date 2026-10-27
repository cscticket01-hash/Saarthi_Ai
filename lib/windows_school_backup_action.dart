import 'windows_appearance.dart';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'windows_local_firestore.dart' show FirebaseFirestore;
import 'windows_local_settings.dart';
import 'windows_local_storage.dart';
import 'windows_school_backup_export.dart';
import 'windows_school_id_backup.dart';
import 'windows_school_cloud_backup.dart';

/// Export only the current school. The unencrypted multi-profile backup API is
/// deliberately not used for portable school exports.
Future<void> exportWindowsSchoolBackup(BuildContext context) async {
  final db = FirebaseFirestore.instance;
  final origin = db.activeProfileId;
  final school = db.activeProfileIdentity['schoolSyncId']?.toString() ?? '';
  bool own() =>
      db.activeProfileId == origin &&
      db.activeProfileIdentity['schoolSyncId'] == school;
  if (!RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school)) {
    throw StateError('Select the verified school before exporting.');
  }
  if (!WindowsLocalSecurity.configured) {
    throw StateError('Set an App Lock password before exporting school data.');
  }
  final lock = TextEditingController();
  final password = TextEditingController();
  final confirm = TextEditingController();
  String? accepted;
  try {
    accepted = await showDialog<String>(
      context: context,
      builder: (dialog) {
        String? error;
        return StatefulBuilder(
          builder: (dialog, update) => AlertDialog(
            title: const Text('Backup School Data'),
            content: SizedBox(
              width: 430,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Unlock this school and choose a separate backup password. Keep it safe; it is required to decrypt the export.',
                    ),
                    TextField(
                      controller: lock,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'App Lock password',
                      ),
                    ),
                    TextField(
                      controller: password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Backup password (12+ characters)',
                      ),
                    ),
                    TextField(
                      controller: confirm,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Confirm backup password',
                      ),
                    ),
                    if (error != null)
                      Text(error!, style:       TextStyle(fontFamily: 'Segoe UI', color: WindowsAppearance.foreground(Colors.red))),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (!own() ||
                      !WindowsLocalSecurity.verifyPassword(lock.text)) {
                    update(
                      () => error =
                          'School changed or App Lock password is incorrect.',
                    );
                  } else if (password.text.length < 12 ||
                      password.text != confirm.text) {
                    update(
                      () => error = 'Use matching backup passwords of at least 12 characters.',
                    );
                  } else {
                    Navigator.pop(dialog, password.text);
                  }
                },
                child: const Text('Export encrypted backup'),
              ),
            ],
          ),
        );
      },
    );
  } finally {
    lock.dispose();
    password.dispose();
    confirm.dispose();
  }
  if (accepted == null) return;
  final location = await getSaveLocation(
    suggestedName:
        'School-$school-${DateTime.now().millisecondsSinceEpoch}.vsbackup',
  );
  if (location == null) return;
  if (!own()) throw StateError('School changed; backup cancelled.');
  final snapshot = await db.exportActiveSchoolSnapshot();
  final files = <String, File>{};
  final missing = <String>[];
  final root = await WindowsLocalStorage.localFilesDirectory();
  final cloudSnapshot = await collectWindowsSchoolCloudBackup(
    schoolId: school,
    own: own,
    cacheRoot: Directory(
      '${root.path}${Platform.pathSeparator}Verified_Cloud_Cache',
    ),
    missing: missing,
  );
  final folderName = origin
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ');
  final roots = <String, Directory>{
    'documents': Directory('${root.path}${Platform.pathSeparator}$folderName'),
    'verified-cloud-cache': Directory(
      '${root.path}${Platform.pathSeparator}Verified_Cloud_Cache${Platform.pathSeparator}$school',
    ),
  };
  final includedPaths = <String>{};
  for (final entry in roots.entries) {
    final directory = entry.value;
    if (!await directory.exists()) continue;
    if (_backupHasLinkedAncestor(directory.path)) {
      missing.add('${entry.key}: symbolic-link folder requires review');
      continue;
    }
    final canonicalRoot = await directory.resolveSymbolicLinks();
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Link) {
        missing.add('${entry.key}: linked file excluded');
        continue;
      }
      if (entity is! File) continue;
      final canonical = await entity.resolveSymbolicLinks();
      if (!_backupCanonicalPath(canonical)
          .startsWith('${_backupCanonicalPath(canonicalRoot)}/')) {
        missing.add('${entry.key}: outside-school file excluded');
        continue;
      }
      final relative = canonical
          .substring(canonicalRoot.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      files['${entry.key}/$relative'] = File(canonical);
      includedPaths.add(_backupCanonicalPath(canonical));
    }
  }
  void inspect(dynamic value, String path) {
    if (value is Map) {
      for (final entry in value.entries) {
        if ([
              'localPath',
              'originalPath',
              'processedPath',
            ].contains(entry.key) &&
            entry.value is String &&
            (entry.value as String).isNotEmpty &&
            !includedPaths.contains(
              _referenceCanonicalPath(entry.value as String),
            )) {
          missing.add(
            '$path/${entry.key}: local media unavailable or outside current school',
          );
        }
        inspect(entry.value, '$path/${entry.key}');
      }
    } else if (value is List) {
      for (var index = 0; index < value.length; index++) {
        inspect(value[index], '$path/$index');
      }
    }
  }

  inspect(snapshot, 'snapshot');
  // Preserve all known local records, including queues/cache. Cloud-only files
  // and external encrypted designer stores need separate authenticated reads.

  final idWorkspace = await collectWindowsSchoolIdBackup(school, own, missing);
  final refreshed = await db.exportActiveSchoolSnapshot();
  if (!own() ||
      sha256.convert(utf8.encode(jsonEncode(snapshot))) !=
          sha256.convert(utf8.encode(jsonEncode(refreshed)))) {
    throw StateError('School data changed during collection; retry backup.');
  }
  final result = await WindowsSchoolBackupExport.export(
    schoolId: school,
    password: accepted,
    snapshot: {
      'schoolId': school,
      'data': snapshot,
      'idWorkspace': idWorkspace,
      if (cloudSnapshot != null) 'cloudSnapshot': cloudSnapshot,
    },
    files: files,
    destination: File(location.path),
    stillSameSchool: own,
    missingData: missing,
  );
  if (context.mounted) {
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Encrypted backup exported'),
        content: Text(
          '${result['files'] is List ? (result['files'] as List).length : 0} verified entries.\n\nMissing or unverified:\n${(result['missingData'] as List).join('\n')}\n\nRestore decrypts into a new staging folder; it does not replace current school data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

String _backupCanonicalPath(String path) {
  var value = path.replaceAll(String.fromCharCode(92), '/');
  if (Platform.isWindows) {
    if (value.startsWith('//?/')) value = value.substring(4);
    value = value.toLowerCase();
  }
  return value.replaceAll(RegExp(r'/+$'), '');
}

bool _backupHasLinkedAncestor(String path) {
  var current = Directory(path).absolute;
  while (true) {
    if (FileSystemEntity.typeSync(current.path, followLinks: false) ==
        FileSystemEntityType.link)
      return true;
    final parent = current.parent;
    if (parent.path == current.path) break;
    current = parent;
  }
  return false;
}

String _referenceCanonicalPath(String path) {
  try {
    if (_backupHasLinkedAncestor(File(path).parent.path)) return '';
    return _backupCanonicalPath(File(path).resolveSymbolicLinksSync());
  } catch (_) {
    return '';
  }
}

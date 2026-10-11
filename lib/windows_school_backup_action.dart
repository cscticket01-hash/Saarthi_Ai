import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'windows_local_firestore.dart' show FirebaseFirestore;
import 'windows_local_settings.dart';
import 'windows_local_storage.dart';
import 'windows_school_backup_export.dart';

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
                      Text(error!, style: const TextStyle(color: Colors.red)),
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
    if (await directory.resolveSymbolicLinks() != directory.absolute.path) {
      missing.add('${entry.key}: symbolic-link folder requires review');
      continue;
    }
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
      if (!canonical.startsWith(
        '${directory.absolute.path}${Platform.pathSeparator}',
      )) {
        missing.add('${entry.key}: outside-school file excluded');
        continue;
      }
      final relative = canonical
          .substring(directory.absolute.path.length + 1)
          .replaceAll(Platform.pathSeparator, '/');
      files['${entry.key}/$relative'] = File(canonical);
      includedPaths.add(canonical);
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
              File(entry.value as String).absolute.path,
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
  missing.add(
    'Full cloud file inventory was not fetched; cloud-only files are unverified.',
  );
  missing.add(
    'External designer/bulk job stores require a separate portable export.',
  );
  final refreshed = await db.exportActiveSchoolSnapshot();
  if (!own() ||
      sha256.convert(utf8.encode(jsonEncode(snapshot))) !=
          sha256.convert(utf8.encode(jsonEncode(refreshed)))) {
    throw StateError('School data changed during collection; retry backup.');
  }
  final result = await WindowsSchoolBackupExport.export(
    schoolId: school,
    password: accepted,
    snapshot: {'schoolId': school, 'data': snapshot},
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

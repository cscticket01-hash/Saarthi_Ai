import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'id_card_draft_storage_io.dart';
import 'id_card_bulk_job_store.dart';

/// Portable decrypted design snapshots are handed directly to the authenticated
/// encrypted exporter. OS encryption keys are never exported.
Future<Map<String, dynamic>> collectWindowsSchoolIdBackup(
  String school,
  bool Function() own,
  List<String> missing,
) async {
  final support = await getApplicationSupportDirectory();
  final result = <String, dynamic>{
    'designs': <String, dynamic>{},
    'bulkJobs': <String, dynamic>{},
  };
  final designs = Directory(
    '${support.path}${Platform.pathSeparator}id_card_drafts',
  );
  if (await designs.exists() && _backupHasLinkedAncestor(designs.path)) {
    missing.add('Designer root links require review');
  } else if (await designs.exists()) {
    await for (final entity in designs.list(followLinks: false)) {
      if (entity is Link) {
        missing.add('Linked designer folder excluded');
        continue;
      }
      if (entity is! Directory) continue;
      final id = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!RegExp(r'^[a-z][a-z0-9-]{1,80}$').hasMatch(id) ||
          _backupHasLinkedAncestor(entity.path)) {
        missing.add('Designer folder requires review');
        continue;
      }
      if (!own()) throw StateError('School changed during design export');
      final stem = sha256.convert(utf8.encode(school)).toString();
      if (!await File('${entity.path}${Platform.pathSeparator}$stem.draft.json')
              .exists() &&
          !await File(
            '${entity.path}${Platform.pathSeparator}$stem.applied.json',
          ).exists())
        continue;
      final revisions = await entity
          .list(followLinks: false)
          .where(
            (f) => f.uri.pathSegments.last.startsWith('$stem.draft.json.bak.'),
          )
          .length;
      if (revisions > 1)
        missing.add(
          'Designer $id: ${revisions - 1} older historical draft revisions are not included; originals retained',
        );
      try {
        final store = IdCardDraftStorageIo(
          rootPath: entity.path,
          schoolId: school,
        );
        (result['designs'] as Map)[id] = {
          'draft': await store.loadDraft(),
          'applied': await store.loadAppliedTemplate(),
          'previousRevision': await store.readPreviousRevision(),
        };
      } catch (_) {
        missing.add('Designer $id: protected snapshot unavailable');
      }
    }
  }
  final bulk = Directory(
    '${support.path}${Platform.pathSeparator}id_card_bulk_jobs${Platform.pathSeparator}${sha256.convert(utf8.encode(school))}',
  );
  if (await bulk.exists()) {
    if (_backupHasLinkedAncestor(bulk.path)) {
      missing.add('Bulk job folder links require review');
    } else {
      try {
        final store = IdCardBulkJobStore(rootPath: bulk.path, schoolId: school);
        for (final job in await store.listJobs()) {
          if (!own()) throw StateError('School changed during bulk backup');
          final id = job['jobId'] as String;
          final plan = await store.resumePlan(id);
          final pdf = await store.readCompletedPdf(id);
          (result['bulkJobs'] as Map)[id] = {
            'metadata': job,
            'selection': plan.durableSnapshot,
            if (pdf != null) 'completedPdf': base64Encode(pdf),
          };
        }
      } catch (_) {
        missing.add(
          'Protected bulk jobs unavailable or corrupt; originals retained',
        );
      }
    }
  }
  if (!own()) throw StateError('School changed during ID backup');
  return result;
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

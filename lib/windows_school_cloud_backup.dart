import 'dart:io';

import 'windows_binary_downloads.dart';
import 'windows_connect/managed_school_session.dart';

const schoolBackupCollections = <String>{
  'students_directory', 'teachers_directory', 'attendance_logs',
  'teacher_attendance', 'attendance_records', 'teacher_schedules',
  'school_notices', 'school_calendar', 'exam_results', 'teacher_salary',
  'school_config', 'school_settings', 'fee_settings', 'fee_ledger',
  'fee_payments', 'school_expenses', 'student_scan_index', 'scanner_devices',
  'documents', 'backups', 'exams', 'exam_center_results',
};

/// Read-only cloud capture. Local edits remain a separate snapshot; no remote
/// record replaces a newer local record during backup.
Future<Map<String, dynamic>?> collectWindowsSchoolCloudBackup({
  required String schoolId,
  required bool Function() own,
  required Directory cacheRoot,
  required List<String> missing,
  Future<Map<String, dynamic>> Function(
    String action,
    Map<String, dynamic> body,
  )?
  request,
}) async {
  Future<Map<String, dynamic>> call(
    String action,
    Map<String, dynamic> body,
  ) async {
    if (!own()) throw StateError('School changed during cloud backup');
    final result = await (request != null
        ? request(action, body)
        : ManagedSchoolSession.callForSchool(schoolId, action, body));
    if (!own() || result['success'] != true || result['schoolId'] != schoolId) {
      throw StateError('Cloud backup school proof unavailable');
    }
    return result;
  }

  Map<String, dynamic>? snapshot;
  try {
    final response = await call(
      'managed/backup/snapshot',
      {},
    ).timeout(const Duration(seconds: 60));
    if (response['snapshotProtocol'] != 1 ||
        response['recordsComplete'] != true ||
        response['collections'] is! List ||
        (response['collections'] as List).length != schoolBackupCollections.length ||
        !(response['collections'] as List).toSet().containsAll(schoolBackupCollections) ||
        response['records'] is! Map ||
        response['collectionRevisions'] is! Map) {
      throw StateError('Full record census unavailable');
    }
    final records = response['records'] as Map;
    final revisions = response['collectionRevisions'] as Map;
    for (final collection in schoolBackupCollections) {
      if (records[collection] is! Map || revisions[collection] is! String) {
        throw StateError('Incomplete record census');
      }
      for (final value in (records[collection] as Map).values) {
        if (value is! Map || value['schoolId'] != schoolId) {
          throw StateError('Foreign or malformed cloud record');
        }
      }
    }
    snapshot = Map<String, dynamic>.from(response);
  } catch (_) {
    missing.add('Cloud record census unavailable; local snapshot retained.');
  }
  if (!own()) throw StateError('School changed during cloud backup');
  final downloads = WindowsBinaryDownloads(
    schoolId: schoolId,
    storageDirectory: cacheRoot,
    currentSchool: () => own() ? schoolId : '',
    request: (body) => call(body['action'] as String, body),
  );
  final watch = Stopwatch()..start();
  try {
    var pages = 0;
    do {
      if (++pages > 200 || watch.elapsed > const Duration(minutes: 3)) {
        throw StateError('Cloud inventory limit reached');
      }
      await downloads.refreshInventory(restart: pages == 1);
    } while (downloads.summary['hasMore'] == true);
    if (downloads.summary['inventory'] != 'VERIFIED') {
      missing.add('Cloud application file inventory is partial or unverified.');
    }
    for (
      var attempted = 0;
      attempted < WindowsBinaryDownloads.maxItems;
      attempted++
    ) {
      if (downloads.summary['pending'] == 0 ||
          watch.elapsed > const Duration(minutes: 3))
        break;
      if (!await downloads.repairNext()) break;
    }
    for (final entry in downloads.entries) {
      if (entry['state'] != 'verified') {
        missing.add('Cloud file ${entry['fileId']}: ${entry['state']}');
      }
    }
    if (snapshot != null) snapshot['cloudFileInventory'] = downloads.entries;
  } catch (_) {
    missing.add(
      'Cloud files could not be fully verified/downloaded; cached originals retained.',
    );
  }
  if (!own()) throw StateError('School changed during cloud backup');
  return snapshot;
}

import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'windows_local_firestore.dart';

/// Explicit local-only QA fixture. These records are NOT Google Drive ACKs,
/// are never auto-enqueued, and must never be injected into another school.
class WindowsTestSchoolLocalDemoSeed {
  WindowsTestSchoolLocalDemoSeed._();

  static const schoolId = 'vs-db8afb01a3be46a983c8284714d06e5d';
  static const target = 100000;
  static const batchSize = 250;
  static const prefix = 'TEST2-LOCAL-';
  static const marker = 'TEST2-LOCAL-100K';

  static String idFor(int index) {
    if (index < 1 || index > target) {
      throw RangeError.range(index, 1, target, 'studentIndex');
    }
    return '$prefix${index.toString().padLeft(6, '0')}';
  }

  static Map<String, dynamic> student(int index) {
    final id = idFor(index);
    final category = 'Class ${1 + (index - 1) % 12}';
    final section = String.fromCharCode(65 + (index - 1) % 10);
    final token = sha256.convert(utf8.encode('$schoolId/$id')).toString();
    return {
      'schoolId': schoolId,
      'id': id,
      'studentId': id,
      'name': 'Demo Student ${index.toString().padLeft(6, '0')}',
      'class': category,
      'studentClass': category,
      'section': section,
      // Class/section repeats every 60 entries, so this must not restart.
      'rollNo': index.toString(),
      'mobileStableId': 'p-${token.substring(0, 32)}',
      'fatherName': 'Demo Guardian',
      'dob': '2015-01-01',
      'syntheticTest': true,
      'syntheticTestLocal': true,
      'syntheticBatch': marker,
      'qaSource': 'local-only-no-drive-ack'
    };
  }

  /// `verifyActiveSchool` must check the authenticated TEST session on the
  /// server before this is called. Repeated profile checks fence logout,
  /// school switch and licence change throughout the operation.
  static Future<int> create({
    required Future<bool> Function() verifyActiveSchool,
    void Function(int present, int total)? onProgress,
    int count = target,
  }) async {
    if (count < 1 || count > target) throw ArgumentError('Invalid TEST student count.');
    final db = FirebaseFirestore.instance;
    final profile = db.activeProfileId;

    void scope() {
      if (db.activeProfileId != profile ||
          db.activeProfileIdentity['schoolSyncId'] != schoolId ||
          db.activeProfileIdentity['blocked'] == true) {
        throw StateError('School changed. Local TEST data was not added to another school.');
      }
    }

    scope();
    if (!await verifyActiveSchool()) {
      throw StateError('Authenticated TEST school permission required.');
    }
    scope();
    if (!await db.localPersistenceEnabled()) {
      throw StateError('Persistent school storage must be enabled before the TEST import.');
    }
    scope();

    // This is an explicit local UI fixture, not a fake server download.
    // Existing rows with this prefix must be genuine same-school QA rows.
    final rows = await db.collection('students_directory').get();
    scope();
    final existing = <String>{};
    for (final row in rows.docs) {
      if (!row.id.startsWith(prefix)) continue;
      final data = row.data();
      if (data['schoolId'] != schoolId ||
          data['syntheticTestLocal'] != true ||
          data['syntheticBatch'] != marker) {
        throw StateError('TEST ID collision: existing record preserved.');
      }
      existing.add(row.id);
    }
    var present = 0;
    for (var index = 1; index <= count; index += batchSize) {
      scope();
      final batch = db.batch();
      var newRows = 0;
      final end = index + batchSize - 1 < count
          ? index + batchSize - 1
          : count;
      for (var item = index; item <= end; item++) {
        final id = idFor(item);
        if (existing.contains(id)) continue; // Safe repeat/resume.
        final ref = db.collection('students_directory').doc(id);
        // Another writer winning between snapshot and disk commit is never
        // overwritten, even if it uses a TEST-prefixed ID.
        batch.requireUnchanged(ref, null);
        batch.set(ref, student(item));
        newRows++;
      }
      if (newRows > 0) {
        // Deliberately suppresses cloud outbox creation. A local fixture is
        // not allowed to show fake Cloudflare / Google Drive success.
        await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
          () => batch.commit(),
        );
      }
      scope();
      present += end - index + 1;
      onProgress?.call(present, count);
      // Allow progress UI events between bounded commits.
      await Future<void>.delayed(Duration.zero);
    }
    return present;
  }
}

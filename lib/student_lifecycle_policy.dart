/// A Class/Roll is a slot; mobileStableId identifies its current occupant.
/// Only explicit owner references qualify for cascade deletion.
const studentOwnedCollections = <String>{
  'documents',
  'attendance_records',
  'attendance_logs',
  'fee_ledger',
  'fee_payments',
  'exam_results',
  'exam_center_results',
  'student_scan_index',
};

bool recordBelongsToStudent(
  String collection,
  String recordId,
  Map row,
  String studentId,
  String generation, {
  List<String> aliases = const [],
}) {
  if (row['role'] == 'teacher' || row['ownerRole'] == 'teacher') return false;
  if (row['personId'] != null) return row['personId'] == generation;
  final ids = {studentId, ...aliases};
  return [
        'studentId',
        'studentDocId',
        'studentDocumentId',
        'documentId',
        'oldStudentId',
        'previousStudentId',
      ].any((key) => ids.contains(row[key])) ||
      collection == 'student_scan_index' && ids.contains(recordId);
}

bool deletesSameStudentGeneration(Map pending, Map remote) =>
    pending['collection'] == 'students_directory' &&
    pending['operation'] == 'delete' &&
    pending['deletedStudentGeneration'] is String &&
    pending['deletedStudentGeneration'] ==
        (remote['_syncDeleted'] == true
            ? remote['_syncDeletedOwner']
            : remote['mobileStableId'] ?? pending['documentId']);

bool replacesDeletedStudent(Map pending, Map remote) {
  final data = pending['data'];
  return pending['collection'] == 'students_directory' &&
      data is Map &&
      data['mobileStableId'] is String &&
      data['replacesStudentGeneration'] is String &&
      data['mobileStableId'] != data['replacesStudentGeneration'] &&
      data['replacesStudentGeneration'] ==
          (remote['_syncDeleted'] == true
              ? remote['_syncDeletedOwner']
              : remote['mobileStableId']);
}

/// Purge an acknowledged student generation, retaining only deletion identity.
/// A newer occupant of the same Class/Roll is never selected by the old slot.
Set<String> purgeStudentGeneration(
  Map<String, dynamic> collections,
  String school,
  String studentId,
  String generation,
) {
  final paths = <String>{};
  final mediaIds = <String>{};
  final directory = collections['students_directory'];
  final live = directory is Map ? directory[studentId] : null;
  final newer =
      live is Map &&
      live['mobileStableId'] != null &&
      live['mobileStableId'] != generation;
  bool belongs(String collection, String id, Map row) {
    if (row['schoolId'] != null && row['schoolId'] != school) return false;
    if (collection == 'students_directory')
      return id == studentId &&
          (row['mobileStableId'] ?? studentId) == generation;
    if (newer && row['personId'] == null) return false;
    return recordBelongsToStudent(collection, id, row, studentId, generation);
  }

  bool nested(dynamic value) {
    if (value is Map) {
      if (value['schoolId'] != null && value['schoolId'] != school)
        return false;
      if (value['personId'] == generation ||
          value['mobileStableId'] == generation)
        return true;
      if (!newer &&
          [
            'studentId',
            'studentDocId',
            'studentDocumentId',
          ].any((k) => value[k] == studentId))
        return true;
      return value.values.any(nested);
    }
    return value is List && value.any(nested);
  }

  for (final name in {
    'students_directory',
    ...studentOwnedCollections,
    '_local_student_documents',
    '_windows_document_outbox',
  }) {
    final rows = collections[name];
    if (rows is! Map) continue;
    rows.removeWhere((id, row) {
      if (row is! Map || !belongs(name, id.toString(), row)) return false;
      for (final field in ['fileId', 'photoFileId'])
        if (row[field] is String) mediaIds.add(row[field]);
      final photo = row['photoUrl'];
      if (photo is String) {
        final match = RegExp(
          r'^https://drive\.google\.com/file/d/([A-Za-z0-9_-]+)',
        ).firstMatch(photo);
        if (match != null) mediaIds.add(match.group(1)!);
      }
      for (final field in ['localPath', 'highQualityLocalPath'])
        if (row[field] is String) paths.add(row[field]);
      for (final path in row['retainedLocalPaths'] as List? ?? [])
        if (path is String) paths.add(path);
      return true;
    });
  }
  final queue = collections['_windows_firebase_outbox'];
  if (queue is Map)
    queue.removeWhere(
      (id, row) =>
          row is Map &&
          (row['collection'] == 'students_directory' &&
                  row['documentId'] == studentId &&
                  (row['operation'] == 'delete' &&
                          row['deletedStudentGeneration'] == generation ||
                      row['data'] is Map &&
                          (row['data']['mobileStableId'] ?? studentId) ==
                              generation) ||
              studentOwnedCollections.contains(row['collection']) &&
                  row['data'] is Map &&
                  belongs(
                    row['collection'],
                    row['documentId'].toString(),
                    row['data'],
                  )),
    );
  for (final name in [
    '_windows_sync_conflicts',
    '_windows_sync_conflict_history',
    '_windows_sync_resolution_history',
    '_windows_verified_cloud_records',
  ]) {
    final rows = collections[name];
    if (rows is Map) rows.removeWhere((id, row) => nested(row));
  }
  bool referencesMedia(dynamic value, String fileId) {
    if (value is Map)
      return value.entries.any(
        (e) =>
            (e.key == 'fileId' || e.key.toString().endsWith('FileId')) &&
                e.value == fileId ||
            referencesMedia(e.value, fileId),
      );
    return value is List && value.any((v) => referencesMedia(v, fileId));
  }

  final images = collections['_windows_school_image_cache'];
  if (images is Map)
    images.removeWhere(
      (key, row) =>
          row is Map &&
          row['schoolId'] == school &&
          mediaIds.contains(row['fileId']) &&
          !collections.entries
              .where((e) => !e.key.startsWith('_'))
              .any((e) => referencesMedia(e.value, row['fileId'])),
    );
  final deleted = collections['_windows_local_deletions'];
  if (deleted is Map)
    for (final row in deleted.values) {
      if (row is Map &&
          row['schoolId'] == school &&
          row['collection'] == 'students_directory' &&
          row['documentId'] == studentId &&
          row['snapshot'] is Map &&
          (row['snapshot']['mobileStableId'] ?? studentId) == generation) {
        row['snapshot'] = {'mobileStableId': generation};
        row['studentPayloadPurged'] = true;
      }
    }
  return paths;
}

List<String> verifiedDeletedStudentGenerations(Map record) => {
  if (record['_syncDeletedOwner'] is String)
    record['_syncDeletedOwner'] as String,
  ...(record['_syncRetiredStudentGenerations'] as List? ?? [])
      .whereType<String>(),
}.toList();

bool reusesDeletedStudentRecord(Map pending, Map remote, Map? parent) {
  final data = pending['data'];
  if (!studentOwnedCollections.contains(pending['collection']) ||
      pending['collection'] == 'documents' ||
      remote['_syncDeleted'] != true ||
      data is! Map ||
      parent == null)
    return false;
  final person = data['personId'] ?? parent['mobileStableId'];
  return person is String &&
      person == parent['mobileStableId'] &&
      person != remote['_syncDeletedOwner'] &&
      (remote['_syncDeletedOwner'] is String ||
          parent['replacesStudentGeneration'] is String);
}

import 'dart:math';

// Durable owner deletion is authority; absence alone never is.
bool retireDeletedOwnerDocuments(
  Map<String, dynamic> collections,
  String school,
) {
  if (school.isEmpty) return false;
  final evidence = collections['_windows_local_deletions'];
  if (evidence is! Map) return false;
  final queue = Map<String, dynamic>.from(
    collections['_windows_document_outbox'] as Map? ?? {},
  );
  final local = Map<String, dynamic>.from(
    collections['_local_student_documents'] as Map? ?? {},
  );
  final history = Map<String, dynamic>.from(
    collections['_windows_sync_conflict_history'] as Map? ?? {},
  );
  collections['_windows_document_outbox'] = queue;
  collections['_local_student_documents'] = local;
  collections['_windows_sync_conflict_history'] = history;
  final cached = collections['documents'];
  var changed = false;
  final latest = <String, Map>{};
  for (final deletion in evidence.values) {
    if (deletion is! Map ||
        deletion['version'] != 1 ||
        deletion['schoolId'] != school ||
        deletion['operationId'] is! String ||
        deletion['snapshot'] is! Map ||
        !{
          'students_directory',
          'teachers_directory',
        }.contains(deletion['collection']))
      continue;
    final key = '${deletion['collection']}/${deletion['documentId']}';
    final prior = latest[key];
    if (prior == null ||
        (deletion['deletedAt'] as num? ?? 0) >=
            (prior['deletedAt'] as num? ?? 0))
      latest[key] = deletion;
  }
  for (final deletion in latest.values) {
    final collection = deletion['collection'], person = deletion['documentId'];
    if (person is! String ||
        person.isEmpty ||
        (collections[collection] as Map?)?[person] != null)
      continue;
    final role = collection == 'students_directory' ? 'student' : 'teacher';
    for (final id in {
      ...queue.keys,
      ...local.keys,
      if (cached is Map) ...cached.keys,
    }) {
      final row = local[id] ?? queue[id] ?? (cached is Map ? cached[id] : null);
      if (row is! Map ||
          row['schoolId'] != school ||
          (row['deleted'] == true &&
              (queue[id] is! Map || queue[id]['deleted'] == true)))
        continue;
      final ownerRole =
          row['ownerRole'] ?? (row['studentId'] != null ? 'student' : null);
      final stableId =
          (deletion['snapshot'] as Map)['mobileStableId'] ?? person;
      final directoryId = row['studentId'];
      if (ownerRole != role ||
          (directoryId != null
              ? directoryId != person
              : row['personId'] != stableId) ||
          (row['personId'] != null && row['personId'] != stableId))
        continue;
      final oldQueue = queue[id];
      if (oldQueue is Map &&
          (oldQueue['schoolId'] != school ||
              oldQueue['studentId'] != row['studentId'] ||
              oldQueue['personId'] != row['personId'] ||
              oldQueue['ownerRole'] != row['ownerRole']))
        continue;
      history.putIfAbsent(
        'owner-delete-$id-${deletion['operationId']}',
        () => {
          'schoolId': school,
          'resolution': 'superseded by explicit owner deletion',
          'parentDeletionOperationId': deletion['operationId'],
          'document': Map<String, dynamic>.from(row),
          if (oldQueue is Map) 'pending': Map<String, dynamic>.from(oldQueue),
        },
      );
      final replacement =
          <String, dynamic>{
              ...Map<String, dynamic>.from(row),
              'documentId': id,
              'deleted': true,
              'syncState': 'Pending',
              'documentRevision':
                  'delete-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}',
              'parentDeletionOperationId': deletion['operationId'],
              'parentCollection': collection,
              'parentPersonId': person,
              'retryCount': 0,
              'retryAtMillis': 0,
              'baseCloudRevision':
                  row['cloudRevision'] ?? row['baseCloudRevision'] ?? '',
              'baseCloudUploadedAt':
                  row['cloudUploadedAt'] ?? row['baseCloudUploadedAt'],
            }
            ..remove('ownerDeleteBaselineVerified')
            ..remove('reviewedRecordRevision')
            ..remove('lastError')
            ..remove('failureCategory');
      queue[id] = replacement;
      local[id] = Map<String, dynamic>.from(replacement);
      changed = true;
    }
  }
  return changed;
}

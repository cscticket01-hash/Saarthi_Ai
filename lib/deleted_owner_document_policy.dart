import 'dart:math';

// Durable owner deletion is authority; absence alone never is.
bool retireDeletedOwnerDocuments(
  Map<String, dynamic> collections,
  String school,
) {
  if (school.isEmpty) return false;
  final evidence = collections['_windows_local_deletions'];
  if (evidence is! Map) return false;
  final queue = collections.putIfAbsent(
    '_windows_document_outbox',
    () => <String, dynamic>{},
  ) as Map;
  final local = collections.putIfAbsent(
    '_local_student_documents',
    () => <String, dynamic>{},
  ) as Map;
  final cached = collections['documents'];
  final history = collections.putIfAbsent(
    '_windows_sync_conflict_history',
    () => <String, dynamic>{},
  ) as Map;
  var changed = false;
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
      final ownerId = row['personId'] ?? row['studentId'];
      if (ownerRole != role || ownerId != person) continue;
      final oldQueue = queue[id];
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
            ..remove('lastError')
            ..remove('failureCategory');
      queue[id] = replacement;
      local[id] = Map<String, dynamic>.from(replacement);
      changed = true;
    }
  }
  return changed;
}

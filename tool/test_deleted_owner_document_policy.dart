import '../lib/deleted_owner_document_policy.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

void main() {
  const school = 'school-a';
  Map<String, dynamic> root({
    String evidenceSchool = school,
    bool restored = false,
    bool proof = true,
  }) => {
    'students_directory': {
      if (restored) 's1': {'name': 'Restored'},
    },
    '_windows_local_deletions': {
      if (proof)
        'delete-s1': {
          'version': 1,
          'schoolId': evidenceSchool,
          'collection': 'students_directory',
          'documentId': 's1',
          'operationId': 'delete-s1',
          'snapshot': {'name': 'Original'},
        },
    },
    '_windows_document_outbox': {
      'card': {
        'schoolId': school,
        'studentId': 's1',
        'personId': 's1',
        'ownerRole': 'student',
        'documentRevision': 'upload-1',
        'syncState': 'conflict',
        'localPath': '/retained/original.pdf',
      },
      'foreign': {
        'schoolId': 'school-b',
        'studentId': 's1',
        'documentRevision': 'foreign',
        'syncState': 'conflict',
      },
      'other-owner': {
        'schoolId': school,
        'studentId': 's2',
        'documentRevision': 'other',
        'syncState': 'Pending',
      },
      'teacher': {
        'schoolId': school,
        'personId': 's1',
        'ownerRole': 'teacher',
        'documentRevision': 'teacher',
        'syncState': 'conflict',
      },
    },
  };
  for (final fixture in [
    root(proof: false),
    root(evidenceSchool: 'school-b'),
    root(restored: true),
  ]) {
    check(
      !retireDeletedOwnerDocuments(fixture, school),
      'Absence, foreign proof or restored parent must not retire',
    );
    check(
      fixture['_windows_document_outbox']['card']['syncState'] == 'conflict',
      'Original conflict retained',
    );
  }
  final fixture = root();
  check(
    retireDeletedOwnerDocuments(fixture, school),
    'Confirmed owner deletion should retire',
  );
  final row = fixture['_windows_document_outbox']['card'];
  check(
    row['deleted'] == true && row['syncState'] == 'Pending',
    'Fresh tombstone queued',
  );
  check(
    row['documentRevision'] != 'upload-1',
    'Deletion must have a new operation identity',
  );
  check(
    row['localPath'] == '/retained/original.pdf',
    'Local original preserved',
  );
  check(
    row['parentDeletionOperationId'] == 'delete-s1',
    'Authority bound to explicit deletion',
  );
  final history =
      fixture['_windows_sync_conflict_history']['owner-delete-card-delete-s1'];
  check(
    history['pending']['documentRevision'] == 'upload-1',
    'Original queued generation archived',
  );
  check(
    fixture['_windows_document_outbox']['foreign']['documentRevision'] ==
        'foreign',
    'Foreign school retained',
  );
  check(
    fixture['_windows_document_outbox']['other-owner']['documentRevision'] ==
        'other',
    'Other student retained',
  );
  check(
    fixture['_windows_document_outbox']['teacher']['documentRevision'] ==
        'teacher',
    'Same-ID teacher retained',
  );
  check(
    !retireDeletedOwnerDocuments(fixture, school),
    'Repeated recovery is idempotent',
  );
  check(
    fixture['_windows_document_outbox']['card']['documentRevision'] ==
        row['documentRevision'],
    'No extra delete operation',
  );
  final stale = root();
  stale['_local_student_documents'] = {
    'card': {...stale['_windows_document_outbox']['card'], 'deleted': true},
  };
  check(
    retireDeletedOwnerDocuments(stale, school),
    'Old local delete with live conflict still requires retirement',
  );
  print(
    'PASS: deletion evidence, foreign-school/owner/role isolation, restored-parent protection, archive/original retention, idempotency, legacy stuck delete',
  );
}

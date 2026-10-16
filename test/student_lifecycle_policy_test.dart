import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/student_lifecycle_policy.dart';

void main() {
  const school = 'school-a',
      id = 'Class 1_Roll_1',
      old = 'p-old',
      fresh = 'p-new';
  test('verified deletion removes only the old incarnation and related payloads, preserving new occupant and school B', () {
    final data = <String, dynamic>{
      'students_directory': {
        id: {'schoolId': school, 'mobileStableId': fresh, 'name': 'New'},
      },
      'fee_payments': {
        'old': {
          'schoolId': school,
          'studentId': id,
          'personId': old,
          'amount': 100,
        },
        'new': {
          'schoolId': school,
          'studentId': id,
          'personId': fresh,
          'amount': 200,
        },
        'foreign': {
          'schoolId': 'school-b',
          'studentId': id,
          'personId': old,
          'amount': 300,
        },
      },
      '_local_student_documents': {
        'doc': {
          'schoolId': school,
          'studentId': id,
          'personId': old,
          'localPath': 'managed.pdf',
        },
      },
      '_windows_firebase_outbox': {
        'old': {
          'collection': 'fee_payments',
          'documentId': 'old',
          'data': {'schoolId': school, 'studentId': id, 'personId': old},
        },
        'new': {
          'collection': 'students_directory',
          'documentId': id,
          'data': {'schoolId': school, 'mobileStableId': fresh},
        },
      },
      '_windows_local_deletions': {
        'delete': {
          'schoolId': school,
          'collection': 'students_directory',
          'documentId': id,
          'snapshot': {
            'mobileStableId': old,
            'name': 'Old',
            'dateOfBirth': 'private',
          },
        },
      },
      '_windows_verified_cloud_records': {
        'old': {
          'schoolId': school,
          'record': {'mobileStableId': old, 'name': 'Old'},
        },
      },
    };
    expect(purgeStudentGeneration(data, school, id, old), {'managed.pdf'});
    expect((data['students_directory'] as Map)[id]['name'], 'New');
    expect(
      (data['fee_payments'] as Map).keys,
      unorderedEquals(['new', 'foreign']),
    );
    expect((data['_windows_firebase_outbox'] as Map).keys, ['new']);
    expect(data['_windows_verified_cloud_records'], isEmpty);
    expect(data['_windows_local_deletions']['delete']['snapshot'], {
      'mobileStableId': old,
    });
  });
  test(
    'a replacement is recognized only by explicit prior deletion generation',
    () {
      final pending = {
        'collection': 'students_directory',
        'data': {'mobileStableId': fresh, 'replacesStudentGeneration': old},
      };
      expect(
        replacesDeletedStudent(pending, {
          '_syncDeleted': true,
          '_syncDeletedOwner': old,
        }),
        true,
      );
      expect(
        replacesDeletedStudent(pending, {
          '_syncDeleted': true,
          '_syncDeletedOwner': 'someone-else',
        }),
        false,
      );
      expect(
        replacesDeletedStudent(
          {
            'collection': 'students_directory',
            'data': {'mobileStableId': fresh},
          },
          {'_syncDeleted': true, '_syncDeletedOwner': old},
        ),
        false,
      );
    },
  );
}

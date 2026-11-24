import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_exam_policy.dart';

void main() {
  group('Exam Center pure validation', () {
    test('only completed exams leave the active list after 15 days', () {
      final completed = DateTime.utc(2026, 11, 24);
      final exam = {'completedAt': completed.millisecondsSinceEpoch};
      expect(WindowsExamPolicy.archived(exam, completed.add(
        const Duration(days: 15) - const Duration(milliseconds: 1),
      )), isFalse);
      final cutoff = completed.add(const Duration(days: 15));
      expect(WindowsExamPolicy.archived(exam, cutoff), isTrue);
      expect(WindowsExamPolicy.archived({}, cutoff), isFalse);
    });
    test('exam group distinguishes academic sessions and immutable group IDs', () {
      final first = <String, dynamic>{
        'schoolId': 'school-a',
        'academicSession': '2026-2027',
        'examName': 'Final Exam',
        'examGroupId': 'group-a',
      };
      expect(
        WindowsExamPolicy.groupKey(first),
        WindowsExamPolicy.groupKey({...first, 'studentClass': 'Class 9'}),
      );
      expect(
        WindowsExamPolicy.groupKey(first),
        isNot(WindowsExamPolicy.groupKey({...first,
          'academicSession': '2027-2028'})),
      );
      expect(
        WindowsExamPolicy.groupKey(first),
        isNot(WindowsExamPolicy.groupKey({...first,
          'schoolId': 'school-b'})),
      );
      expect(
        WindowsExamPolicy.groupKey(first),
        isNot(WindowsExamPolicy.groupKey({...first,
          'examGroupId': 'group-b'})),
      );
      final legacy = {...first}..remove('examGroupId');
      expect(WindowsExamPolicy.groupKey(legacy),
        contains('name:final exam'));
    });

    test('subjects are trimmed and case-insensitive duplicates are refused', () {
      expect(WindowsExamPolicy.subjects([' Maths ', '', 'English']),
        ['Maths', 'English']);
      expect(
        () => WindowsExamPolicy.subjects(['Maths', ' maths ']),
        throwsStateError,
      );
      expect(() => WindowsExamPolicy.subjects(['  ']), throwsStateError);
    });

    test('marks require every expected subject and finite values', () {
      const subjects = ['Maths', 'English'];
      expect(
        WindowsExamPolicy.validateMarks(
          {'Maths': 60, 'English': 32},
          subjects: subjects, fullMarks: 100, passMarks: 33),
        {'Maths': 60, 'English': 32},
      );
      for (final invalid in [double.nan, double.infinity,
          double.negativeInfinity, -1, 101]) {
        expect(
          () => WindowsExamPolicy.validateMarks(
            {'Maths': invalid, 'English': 70},
            subjects: subjects, fullMarks: 100, passMarks: 33),
          throwsStateError,
        );
      }
      expect(() => WindowsExamPolicy.validateMarks({'Maths': 80},
        subjects: subjects, fullMarks: 100, passMarks: 33), throwsStateError);
      expect(() => WindowsExamPolicy.validateMarks(
        {'Maths': 80, 'English': 80, 'Science': 80},
        subjects: subjects, fullMarks: 100, passMarks: 33), throwsStateError);
      expect(() => WindowsExamPolicy.validateMarks(
        {'Maths': 80, 'English': 80},
        subjects: subjects, fullMarks: double.nan, passMarks: 33),
        throwsStateError);
    });

    test('per-subject PASS rule is not replaced by average percentage', () {
      final marks = {'Maths': 100.0, 'English': 20.0};
      expect(WindowsExamPolicy.total(marks), 120);
      expect(WindowsExamPolicy.maximum(2, 100), 200);
      expect(WindowsExamPolicy.decision(marks, 33), 'FAIL');
      expect(WindowsExamPolicy.decision({'Maths': 34, 'English': 33}, 33),
        'PASS');
    });

    test('only eligible active student records count toward cohorts', () {
      expect(WindowsExamPolicy.activeStudent({'name': 'Active'}), isTrue);
      expect(WindowsExamPolicy.activeStudent({'deleted': true}), isFalse);
      expect(WindowsExamPolicy.activeStudent({'_syncDeleted': true}), isFalse);
      expect(WindowsExamPolicy.activeStudent({'active': false}), isFalse);
      expect(WindowsExamPolicy.activeStudent({'status': 'INACTIVE'}), isFalse);
    });
  });
}

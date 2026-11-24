/// Exam Center validation shared by UI and service layer.
/// Pure operations: never read or write school data or render a PDF.
class WindowsExamPolicy {
  static String groupKey(Map<String, dynamic> exam) {
    final school = (exam['schoolId'] ?? '').toString().trim();
    final session = (exam['academicSession'] ?? '').toString().trim();
    final group = (exam['examGroupId'] ?? '').toString().trim();
    final title = (exam['examName'] ?? '').toString().trim().toLowerCase();
    return '$school|$session|${group.isNotEmpty ? 'group:$group' : 'name:$title'}';
  }

  static bool activeStudent(Map<String, dynamic> student) =>
      student['deleted'] != true &&
      student['_syncDeleted'] != true &&
      student['active'] != false &&
      student['status']?.toString().toLowerCase() != 'inactive';

  static double? finiteNumber(dynamic raw) {
    final value = raw is num
        ? raw.toDouble()
        : double.tryParse(raw?.toString().trim() ?? '');
    return value != null && value.isFinite ? value : null;
  }

  static List<String> subjects(Iterable<dynamic> values) {
    final parsed = <String>[];
    final seen = <String>{};
    for (final raw in values) {
      final value = raw.toString().trim();
      if (value.isEmpty) continue;
      if (!seen.add(value.toLowerCase())) {
        throw StateError('Duplicate exam subject: $value');
      }
      parsed.add(value);
    }
    if (parsed.isEmpty) throw StateError('At least one subject is required.');
    return parsed;
  }

  static Map<String, double> validateMarks(
    Map<dynamic, dynamic> input, {
    required List<String> subjects,
    required double fullMarks,
    required double passMarks,
  }) {
    if (!fullMarks.isFinite || fullMarks <= 0 ||
        !passMarks.isFinite || passMarks < 0 || passMarks > fullMarks) {
      throw StateError('Invalid exam maximum/pass marks.');
    }
    final expected = WindowsExamPolicy.subjects(subjects);
    if (input.length != expected.length ||
        input.keys.any((key) => !expected.contains(key))) {
      throw StateError('Marks must match this exam\'s subjects exactly.');
    }
    final marks = <String, double>{};
    for (final subject in expected) {
      final value = finiteNumber(input[subject]);
      if (value == null || value < 0 || value > fullMarks) {
        throw StateError('Invalid marks for $subject.');
      }
      marks[subject] = value;
    }
    return marks;
  }

  static double total(Map<String, double> marks) =>
      marks.values.fold<double>(0, (sum, value) => sum + value);

  static double maximum(int subjectCount, double fullMarks) =>
      subjectCount * fullMarks;

  static String decision(Map<String, double> marks, double passMarks) =>
      marks.values.every((value) => value >= passMarks) ? 'PASS' : 'FAIL';
}

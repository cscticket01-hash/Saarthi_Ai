/// Exam Center validation shared by UI and service layer.
/// Pure operations: never read or write school data or render a PDF.
class WindowsExamPolicy {
  static bool archived(Map<String, dynamic> exam, DateTime now) {
    final completedAt = int.tryParse(exam['completedAt']?.toString() ?? '');
    return completedAt != null && completedAt > 0 &&
        now.millisecondsSinceEpoch - completedAt >=
            const Duration(days: 15).inMilliseconds;
  }

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

  /// Input and paste must be a whole, non-negative mark with at most three digits.
  static bool validMarkEntry(String text, double fullMarks, {bool allowEmpty = false}) {
    if (text.isEmpty) return allowEmpty;
    if (!RegExp(r'^[0-9]{1,3}
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
      if (value == null || value < 0 || value > fullMarks || value > 999 ||
          value != value.roundToDouble()) {
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
).hasMatch(text) || !fullMarks.isFinite) return false;
    final value = int.tryParse(text);
    return value != null && value <= fullMarks;
  }

  /// Existing whole-number records may have been stored as doubles (e.g. 45.0).
  /// Do not silently round historical fractional marks.
  static String markEntryText(dynamic raw) {
    final value = finiteNumber(raw);
    if (value != null && value == value.roundToDouble()) {
      return value.toStringAsFixed(0);
    }
    return raw?.toString() ?? '';
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

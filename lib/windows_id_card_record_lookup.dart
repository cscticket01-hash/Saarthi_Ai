import 'windows_local_firestore.dart';

/// Reuse a verified stored record ID rather than guessing from a display roll.
/// In particular '01', '001' and '1' must resolve to the same student's
/// existing ID without creating a second person or crossing school profiles.
class WindowsIdCardRecordLookup {
  WindowsIdCardRecordLookup._();

  static String normalizeRoll(Object? value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return '';
    if (RegExp(r'^\d+$').hasMatch(raw)) {
      final normalized = raw.replaceFirst(RegExp(r'^0+(?=\d)'), '');
      return normalized.isEmpty ? '0' : normalized;
    }
    return raw.toLowerCase();
  }

  static bool allowed(Map<String, dynamic> data, String school) {
    if (data['_syncDeleted'] == true || data['deleted'] == true) return false;
    for (final key in ['schoolId', 'schoolSyncId']) {
      final bound = data[key]?.toString().trim() ?? '';
      if (bound.isNotEmpty && bound != school) return false;
    }
    return true;
  }

  static Future<({String id, Map<String, dynamic> data})?> find({
    required String schoolClass,
    required String roll,
    String? preferredId,
  }) async {
    final db = FirebaseFirestore.instance;
    final origin = db.activeProfileId;
    final school = db.activeProfileIdentity['schoolSyncId']?.toString() ?? '';
    if (origin.isEmpty || origin == 'unbound' || school.isEmpty) {
      throw StateError('Select a connected school first.');
    }
    void guard() {
      if (db.activeProfileId != origin ||
          db.activeProfileIdentity['schoolSyncId']?.toString() != school) {
        throw StateError('School changed during ID card lookup.');
      }
    }
    final normalized = normalizeRoll(roll);
    if (normalized.isEmpty || schoolClass.trim().isEmpty) return null;
    bool matches(Map<String, dynamic> data) =>
        allowed(data, school) &&
        (data['class'] ?? data['studentClass'])?.toString().trim() ==
            schoolClass &&
        normalizeRoll(data['rollNo']) == normalized;

    final candidates = <String>{
      if (preferredId != null && preferredId.isNotEmpty) preferredId,
      '${schoolClass}_Roll_${roll.trim()}',
      '${schoolClass}_Roll_$normalized',
    };
    final collection = db.collection('students_directory');
    for (final id in candidates) {
      final doc = await collection.doc(id).get();
      guard();
      final data = doc.data();
      if (data != null && matches(data)) return (id: doc.id, data: data);
    }
    final snapshot = await collection.where('class', isEqualTo: schoolClass).get();
    guard();
    final matchesById = <String, Map<String, dynamic>>{};
    for (final doc in snapshot.docs) {
      final data = doc.data();
      if (matches(data)) matchesById[doc.id] = data;
    }
    if (matchesById.isEmpty) return null;
    if (matchesById.length > 1) {
      // A canonical record gets priority. Otherwise do not choose an
      // arbitrary duplicate and potentially issue the wrong person's QR.
      final canonical = '${schoolClass}_Roll_$normalized';
      if (matchesById.containsKey(canonical)) {
        return (id: canonical, data: matchesById[canonical]!);
      }
      throw StateError('Duplicate student records require review before ID card.');
    }
    final id = matchesById.keys.single;
    return (id: id, data: matchesById[id]!);
  }
}

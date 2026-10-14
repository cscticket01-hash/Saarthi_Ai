import 'windows_sync_comparison.dart';
import 'windows_connect/central_school_cloud.dart' show migrationJsonValue;

/// Snapshot comparison only. It never repairs, queues, pulls or writes records.
Map<String, dynamic> compareStudentSyncSnapshot({
  required String school,
  required Map<String, dynamic> local,
  required Map<String, dynamic> cloud,
  required Set<String> pendingIds,
}) {
  if (school.isEmpty || local.length > 10000 || cloud.length > 10000) {
    throw StateError('Student audit exceeds the 10,000-record snapshot limit.');
  }
  Map<String, dynamic> live(Map<String, dynamic> source) {
    final output = <String, dynamic>{};
    for (final entry in source.entries) {
      final row = entry.value;
      if (row is! Map || row['schoolId'] != school) {
        throw StateError(
          'Student snapshot contains a foreign or unbound record.',
        );
      }
      if (row['_syncDeleted'] != true && row['deleted'] != true)
        output[entry.key] = row;
    }
    return output;
  }

  final l = live(local), c = live(cloud);
  final matched = <String>[],
      missing = <String>[],
      differs = <String>[],
      cloudOnly = <String>[];
  for (final id in l.keys) {
    if (!c.containsKey(id))
      missing.add(id);
    else if (syncPayloadHash(migrationJsonValue(l[id]) as Map) == syncPayloadHash(migrationJsonValue(c[id]) as Map))
      matched.add(id);
    else
      differs.add(id);
  }
  for (final id in c.keys) {
    if (!l.containsKey(id)) cloudOnly.add(id);
  }
  return {
    'schoolId': school,
    'localCount': l.length,
    'cloudCount': c.length,
    'matched': matched,
    'missingCloud': missing,
    'different': differs,
    'cloudOnly': cloudOnly,
    'pendingIds': pendingIds.toList()..sort(),
    'verification': 'authenticated metadata snapshot; file bytes and future edits not certified',
  };
}

import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_student_sync_audit.dart';

void main() {
  const school = 'school';
  test('snapshot reports matching, pending, missing, differing and cloud-only IDs without mutations', () {
    final local = {
      'A': {'schoolId': school, 'name': 'Same'},
      'B': {'schoolId': school, 'name': 'Pending'},
      'C': {'schoolId': school, 'name': 'Local'},
      'deleted': {'schoolId': school, '_syncDeleted': true},
    };
    final cloud = {
      'A': {'schoolId': school, 'name': 'Same', '_syncRevision': 'r'},
      'C': {'schoolId': school, 'name': 'Cloud'},
      'D': {'schoolId': school, 'name': 'Remote'},
    };
    final result = compareStudentSyncSnapshot(
      school: school,
      local: local,
      cloud: cloud,
      pendingIds: {'B'},
    );
    expect(result['matched'], ['A']);
    expect(result['missingCloud'], ['B']);
    expect(result['different'], ['C']);
    expect(result['cloudOnly'], ['D']);
    expect(result['pendingIds'], ['B']);
    expect(local['deleted']?['_syncDeleted'], true);
  });
  test(
    'foreign and unbound rows are never counted as verified school data',
    () {
      for (final row in [
        {'schoolId': 'foreign'},
        <String, dynamic>{},
      ])
        expect(
          () => compareStudentSyncSnapshot(
            school: school,
            local: {'A': row},
            cloud: {},
            pendingIds: {},
          ),
          throwsStateError,
        );
    },
  );
}

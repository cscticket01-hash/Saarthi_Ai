import 'package:flutter_test/flutter_test.dart';

import '../lib/school_profile_policy.dart';

void main() {
  test('asset-only profile cannot enter the sync pipeline', () {
    expect(
      () => requireSchoolProfile({'schoolName': '  ', 'logoFileId': 'asset'}),
      throwsA(isA<BlankSchoolProfile>()),
    );
  });
  test('empty cache fields cannot erase cloud identity', () {
    expect(
      mergeSchoolProfileSafely(
        {'schoolName': 'School', 'principalName': 'Admin'},
        {'schoolName': '', 'principalName': null, 'schoolContactNo': '123'},
      ),
      {
        'schoolName': 'School',
        'principalName': 'Admin',
        'schoolContactNo': '123',
      },
    );
  });
}

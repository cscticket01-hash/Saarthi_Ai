import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_other_staff.dart';

void main() {
  test('only three top-level staff tabs are needed', () {
    expect(
      ['Teachers', ...OtherStaffDirectory.roles],
      ['Teachers', 'Office staff', 'Other staff'],
    );
  });

  test('historical Driver, Guard and Support staff remain visible', () {
    for (final role in OtherStaffDirectory.legacyOtherRoles) {
      expect(
        OtherStaffDirectory.categoryFor({'role': role}),
        'Other staff',
      );
    }
    expect(
      OtherStaffDirectory.categoryFor({'role': 'Office staff'}),
      'Office staff',
    );
  });

  test('designation stays manual with a legacy fallback for display', () {
    expect(
      OtherStaffDirectory.suggestedDesignation(
        {'role': 'Driver', 'designation': ''},
      ),
      'Driver',
    );
    expect(
      OtherStaffDirectory.suggestedDesignation(
        {'role': 'Other staff', 'designation': 'Lab Attendant'},
      ),
      'Lab Attendant',
    );
  });
}

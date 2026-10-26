import 'package:flutter_test/flutter_test.dart';
import '../lib/complaint_retention.dart';

void main() {
  test('three calendar months clamp February and include exact deadline', () {
    final row = {
      'status': 'resolved',
      'resolvedAt': DateTime.utc(2026, 11, 30, 12).millisecondsSinceEpoch,
    };
    expect(complaintExpiry(row), DateTime.utc(2027, 2, 28, 12));
    expect(
      complaintExpired(row, DateTime.utc(2027, 2, 28, 11, 59, 59)),
      isFalse,
    );
    expect(complaintExpired(row, DateTime.utc(2027, 2, 28, 12)), isTrue);
    expect(
      complaintExpired({...row, 'status': 'open'}, DateTime.utc(2028)),
      isFalse,
    );
  });
}

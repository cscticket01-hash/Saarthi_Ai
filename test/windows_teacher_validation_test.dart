import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_person_fields.dart';
void main() {
  final today = DateTime(2026, 11, 22);
  String? check({String email = 'a@example.org', String birth = '10/03/1990',
      String joining = '22/11/2026', Map<String, dynamic>? previous}) =>
      validateTeacherOptionalFields(email: email, birthDate: birth,
        joiningDate: joining, previous: previous, today: today);
  test('teacher create and edit validation', () {
    expect(check(), isNull);
    expect(check(email: ''), isNull);
    expect(check(email: 'bad-address'), isNotNull);
    expect(check(birth: '31/02/2000'), isNotNull);
    expect(check(birth: '23/11/2026'), isNotNull);
    expect(check(birth: '1990-03-10'), isNull);
    expect(check(joining: '09/03/1990'), isNotNull);
    expect(check(joining: '31/02/2026'), isNotNull);
    expect(check(email: 'legacy-invalid', previous: {
      'email': 'legacy-invalid', 'dateOfBirth': '10/03/1990',
      'joiningDate': '22/11/2026',
    }), isNull);
  });
  test('legacy formatted mobile numbers compare canonically', () {
    expect(normalizeTeacherPhone('+91 98765 43210'), '9876543210');
    expect(normalizeTeacherPhone('98765-43210'), '9876543210');
  });
}

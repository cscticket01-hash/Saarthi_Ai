import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/mobile/school_session.dart';
import 'package:saarthi_ai/mobile/school_notifications.dart';

void main() {
  Map<String, dynamic> qr() => {
    'app': 'VIDYA_SAARTHI', 'v': 2, 'firebaseProjectId': 'school-one',
    'type': 'student', 'personId': 'p-pupil', 'linkToken': List.filled(48, 'a').join(),
    'googleScriptUrl': 'https://script.google.com/macros/s/SchoolScript/exec',
  };
  test('student and teacher ID links preserve their own school and role', () {
    for (final role in ['student', 'teacher']) {
      final link = SchoolLink.parse(jsonEncode({...qr(), 'type': role}));
      expect(link.projectId, 'school-one');
      expect(link.role, role);
      expect(link.personId, 'p-pupil');
    }
  });
  test('incomplete and redirected school QR URLs are rejected', () {
    for (final change in [
      {'linkToken': ''}, {'type': 'admin'}, {'firebaseProjectId': ''},
      {'googleScriptUrl': 'https://script.google.com.evil.test/macros/s/SchoolScript/exec'},
      {'googleScriptUrl': 'https://user@script.google.com/macros/s/SchoolScript/exec'},
      {'googleScriptUrl': 'https://script.google.com/macros/s/SchoolScript/exec?redirect=other'},
    ]) {
      expect(() => SchoolLink.parse(jsonEncode({...qr(), ...change})), throwsFormatException);
    }
  });
  test('queued notices cannot display after logout or a school switch', () {
    final data = <String, dynamic>{'schoolId': 'school-one', 'type': 'school_notice'};
    expect(SchoolNotifications.belongsToSession(data, 'school-one'), isTrue);
    expect(SchoolNotifications.belongsToSession(data, 'school-two'), isFalse);
    expect(SchoolNotifications.belongsToSession(data, null), isFalse);
    expect(SchoolNotifications.belongsToSession({'schoolId': 'school-one', 'type': 'other'}, 'school-one'), isFalse);
  });
}

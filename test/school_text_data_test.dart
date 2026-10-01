import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/school_text_data.dart';
import 'package:saarthi_ai/school_backend_transport.dart';

void main() {
  test('administrator proof cannot follow a redirect to another host', () {
    for (final url in [
      'https://script.google.com/macros/s/School/exec',
      'https://script.googleusercontent.com/macros/echo?user_content_key=test',
    ]) {
      expect(() => requireSchoolBackendUri(Uri.parse(url)), returnsNormally);
    }
    for (final url in [
      'https://school.example.test/steal',
      'https://script.google.com.evil.test/steal',
      'http://script.google.com/macros/s/School/exec',
      'https://user@script.google.com/macros/s/School/exec',
    ]) {
      expect(() => requireSchoolBackendUri(Uri.parse(url)), throwsStateError);
    }
  });
  test('Google snapshot media is removed before school Firestore sync', () {
    final input = <String, dynamic>{
      'name': 'Student', 'rollNo': '01', 'mobileLinkToken': 'secure-qr-token',
      'paid': 0, 'isOpen': false, 'date': '2026-10-01',
      for (final key in schoolMediaFields) key: 'Google/local media',
      'subjects': [{'name': 'Math', 'marks': 45, 'reportCardUrl': 'private-file'}],
      'branding': {'schoolName': 'Own school', 'logoFileId': 'google-id'},
    };
    final result = schoolTextData(input);
    expect(result['name'], 'Student');
    expect(result['mobileLinkToken'], 'secure-qr-token');
    expect(result['paid'], 0);
    expect(result['isOpen'], false);
    expect(result['date'], '2026-10-01');
    expect(result['subjects'], [{'name': 'Math', 'marks': 45}]);
    expect(result['branding'], {'schoolName': 'Own school'});
    for (final key in schoolMediaFields) {
      expect(result.containsKey(key), false);
      expect(input[key], 'Google/local media');
    }
    expect((input['subjects'] as List).first['reportCardUrl'], 'private-file');
  });
}

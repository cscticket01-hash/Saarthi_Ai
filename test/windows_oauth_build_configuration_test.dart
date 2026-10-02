import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/windows_connect/google_authorization.dart';

void main() {
  test('Windows preview has the configured public Desktop OAuth client', () {
    if (!const bool.fromEnvironment('SAARTHI_VERIFY_OAUTH_BUILD')) return;
    expect(GoogleAuthorization.configured, isTrue);
    expect(GoogleAuthorization.clientId,
        matches(r'^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$'));
  });
}

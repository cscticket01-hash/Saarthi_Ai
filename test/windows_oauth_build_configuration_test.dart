import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/windows_connect/google_authorization.dart';
import 'package:saarthi_ai/windows_connect/central_school_cloud.dart';

void main() {
  test('Windows preview has the configured HTTPS central school API', () {
    if (!const bool.fromEnvironment('SAARTHI_VERIFY_OAUTH_BUILD')) return;
    expect(CentralSchoolCloud.configured, isTrue);
    expect(CentralSchoolCloud.validEndpoint(CentralSchoolCloud.apiUrl), isTrue);
    expect(Uri.parse(CentralSchoolCloud.apiUrl).path, isNotEmpty);
  });
  test('Windows preview has the configured public Desktop OAuth client', () {
    if (!const bool.fromEnvironment('SAARTHI_VERIFY_OAUTH_BUILD')) return;
    expect(GoogleAuthorization.configured, equals(!GoogleAuthorization.brokerRequired ||
        GoogleAuthorization.validBrokerUrl(GoogleAuthorization.brokerUrl)));
    if (GoogleAuthorization.brokerUrl.isNotEmpty) {
      expect(GoogleAuthorization.validBrokerUrl(GoogleAuthorization.brokerUrl), isTrue);
    }
    expect(GoogleAuthorization.clientId,
        matches(r'^[A-Za-z0-9_-]+\.apps\.googleusercontent\.com$'));
  });
}

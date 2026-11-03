import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../../lib/platform/platform_config.dart';
import '../../lib/windows_connect/central_school_cloud.dart';
import '../../lib/testing/isolated_admin_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-db8afb01a3be46a983c8284714d06e5d';
  const endpoint = 'https://saarthi-sync-v2-test.onrender.com/school-cloud';
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  Future<Map<String, dynamic>> login({String tenant = school,
      bool allowed = true, int status = 200, List<String>? actions}) {
    return authenticateIsolatedAdminFixture('test@example.invalid', 'secret',
      endpoint: endpoint, client: MockClient((request) async {
        if (request.url.host == 'identitytoolkit.googleapis.com') {
          return http.Response(jsonEncode({'idToken': 'test-token',
            'refreshToken': 'test-refresh', 'localId': 'test-user'}), 200);
        }
        final body = jsonDecode(request.body) as Map;
        actions?.add(body['action'] as String);
        expect(request.headers.keys.any((key) => key.toLowerCase()
          .startsWith('x-vidya-device-')), false);
        return http.Response(jsonEncode(status == 200 ? {
          'success': true, 'schoolId': tenant, 'uid': 'test-user',
          'projectId': platformProjectId, 'allowed': allowed,
          'storageReady': true,
          'scriptUrl': 'https://script.google.com/macros/s/TESTfixture12345/exec',
        } : {'success': false, 'code': 'DEVICE_PROOF_REQUIRED'}), status);
      }));
  }
  test('fixture authenticates without enrolling a disposable PC', () async {
    final actions = <String>[];
    expect((await login(actions: actions))['schoolId'], school);
    expect(actions, ['managed/session']);
    expect((await CentralSchoolCloud.saved())['schoolId'], school);
  });
  test('foreign tenant and expired entitlement cannot save a fixture', () async {
    await expectLater(login(tenant: 'vs-${'0' * 32}'), throwsStateError);
    await expectLater(login(allowed: false), throwsStateError);
    expect(await CentralSchoolCloud.saved(), isEmpty);
  });
  test('enforced device rejection remains a failure', () async {
    await expectLater(login(status: 401), throwsA(isA<CentralCloudException>()));
    expect(await CentralSchoolCloud.saved(), isEmpty);
  });
  test('production endpoint is rejected before authentication', () async {
    await expectLater(authenticateIsolatedAdminFixture('x', 'y',
      endpoint: 'https://production.example/school-cloud'), throwsStateError);
  });
}

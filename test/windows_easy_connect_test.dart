import 'package:crypto/crypto.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saarthi_ai/windows_connect/google_authorization.dart';
import 'package:saarthi_ai/windows_connect/school_provisioner.dart';
import 'package:saarthi_ai/windows_connect/school_backend_probe.dart';
import 'package:saarthi_ai/windows_connect/easy_connect_screen.dart';

// Use the base real HttpClient implementation for loopback only; all Google
// endpoints use MockClient. A null override would retain the binding global.
class LoopbackHttpOverrides extends HttpOverrides {}

class MemoryCheckpoint implements SetupCheckpoint {
  MemoryCheckpoint([Map<String, dynamic>? initial]) : value = initial ?? {};
  Map<String, dynamic> value;
  @override
  Future<Map<String, dynamic>> read() async => Map.of(value);
  @override
  Future<void> write(Map<String, dynamic> data) async { value = Map.of(data); }
}
const school = 'vs-school-test123';
const account = GoogleSetupAccount('google-sub-1', 'school@gmail.com', 'private-token');
Map<String, dynamic> checkpoint() => {
  'accountSub': account.subject, 'email': account.email, 'projectId': school,
  'nonce': 'test123', 'projectNumber': '123456', 'location': 'asia-south1',
};
http.Response json(Object value, [int status = 200]) => http.Response(jsonEncode(value), status);
SchoolProvisioner provisioner(MemoryCheckpoint storage, http.Client client) => SchoolProvisioner(
  api: GoogleSetupApi(account.accessToken, client: client), account: account,
  checkpoint: storage, progress: (_) {}, bundle: {'rules': 'school-only-rules', 'files': []});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Cancelling an in-flight Google request remains a clean cancellation', () async {
    late GoogleSetupApi api;
    api = GoogleSetupApi('private-token', client: MockClient((request) async {
      api.close();
      throw http.ClientException('transport closed');
    }));
    await expectLater(api.request('GET', 'https://firebase.googleapis.com/v1beta1/projects'),
        throwsA(isA<SetupCancelled>()));
  });
  test('PKCE matches RFC 7636 S256 vector', () {
    expect(GoogleAuthorization.challenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
  });
  test('OAuth callback rejects missing, duplicate and conflicting state/code', () {
    expect(GoogleAuthorization.validCallback(Uri.parse('/oauth2/callback?state=abc&code=ok'), 'abc'), isTrue);
    for (final query in ['state=wrong&code=ok', 'state=abc&state=abc&code=ok',
      'state=abc&code=one&code=two', 'state=abc&code=', 'state=abc&code=ok&error=denied', 'code=ok']) {
      expect(GoogleAuthorization.validCallback(Uri.parse('/oauth2/callback?$query'), 'abc'), isFalse);
    }
    expect(GoogleAuthorization.validCallback(Uri.parse('/other?state=abc&code=ok'), 'abc'), isFalse);
  });
  test('OAuth browser failure cleans listener and is retryable', () async {
    final auth = GoogleAuthorization(oauthClientId: 'test.apps.googleusercontent.com',
      openBrowser: (_) async => throw StateError('browser unavailable'));
    await expectLater(auth.authorize(script: true), throwsStateError);
    await expectLater(auth.authorize(script: true), throwsStateError);
    auth.close();
  });
  test('OAuth cancellation completes cleanly', () async {
    late GoogleAuthorization auth;
    auth = GoogleAuthorization(oauthClientId: 'test.apps.googleusercontent.com',
      openBrowser: (_) async { auth.cancel(); });
    await expectLater(auth.authorize(script: false), throwsA(isA<SetupCancelled>()));
    auth.close();
  });
  test('OAuth exchanges PKCE and accepts only verified account with granted scopes', () async {
    late String verifierChallenge;
    final client = MockClient((r) async {
      if (r.url.host == 'oauth2.googleapis.com') {
        final form = Uri.splitQueryString(r.body);
        expect(GoogleAuthorization.challenge(form['code_verifier']!), verifierChallenge);
        expect(form['code'], 'approved-code');
        expect(form.containsKey('client_secret'), isFalse);
        expect(Uri.parse(form['redirect_uri']!).host, '127.0.0.1');
        return json({'access_token': 'access-only', 'scope': 'openid email https://www.googleapis.com/auth/cloud-platform'});
      }
      expect(r.headers['Authorization'], 'Bearer access-only');
      return json({'sub': 'school-owner', 'email': 'school@gmail.com', 'email_verified': true});
    });
    final auth = GoogleAuthorization(client: client, oauthClientId: 'test.apps.googleusercontent.com',
      openBrowser: (uri) async {
        verifierChallenge = uri.queryParameters['code_challenge']!;
        expect(uri.queryParameters['code_challenge_method'], 'S256');
        expect(uri.queryParameters['access_type'], 'online');
        final callback = Uri.parse(uri.queryParameters['redirect_uri']!).replace(queryParameters: {
          'state': uri.queryParameters['state']!, 'code': 'approved-code'});
        final browser = HttpClient();
        try { final response = await (await browser.getUrl(callback)).close(); await response.drain<void>(); }
        finally { browser.close(); }
      });
    // Widget binding overrides HttpClient with a fake 400 response. This
    // integration uses only the real loopback listener; Google calls are mocked.
    final result = await HttpOverrides.runWithHttpOverrides(
      () => auth.authorize(script: false), LoopbackHttpOverrides());
    expect(result.subject, 'school-owner');
    expect(result.email, 'school@gmail.com');
    auth.close();
  });
  Future<GoogleSetupAccount> signInResponse(http.Response token, {http.Response? user, String broker = ''}) async {
    final auth = GoogleAuthorization(oauthClientId: 'test.apps.googleusercontent.com',
      oauthBrokerUrl: broker, client: MockClient((request) async {
        expect(request.followRedirects, isFalse);
        if (request.url.path == '/healthz') {
          expect(request.method, 'GET');
          return json({'service': 'saarthi-oauth-exchange',
            'clientIdFingerprint': sha256.convert(utf8.encode('test.apps.googleusercontent.com')).toString()});
        }
        if (request.url.host != 'openidconnect.googleapis.com') {
          if (broker.isNotEmpty) {
            expect(request.url.toString(), broker);
            final fields = jsonDecode(request.body) as Map;
            expect(fields.keys.toSet(), {'code', 'code_verifier', 'redirect_uri'});
            expect(fields['code'], 'approved-code');
            expect((fields['code_verifier'] as String).length, greaterThanOrEqualTo(43));
          }
          return token;
        }
        return user!;
      }), openBrowser: (uri) async {
        final callback = Uri.parse(uri.queryParameters['redirect_uri']!).replace(queryParameters: {
          'state': uri.queryParameters['state']!, 'code': 'approved-code'});
        final browser = HttpClient();
        try {
          final response = await (await browser.getUrl(callback)).close();
          await response.drain<void>();
        } finally { browser.close(); }
      });
    try {
      return await HttpOverrides.runWithHttpOverrides(() => auth.authorize(script: false), LoopbackHttpOverrides());
    } finally { auth.close(); }
  }

  test('Broker callback exchange preserves PKCE and verifies school identity', () async {
    final result = await signInResponse(json({'access_token': 'access-only',
      'scope': 'openid email https://www.googleapis.com/auth/cloud-platform'}),
      broker: 'https://oauth.example.test/oauth/token',
      user: json({'sub': 'school-owner', 'email': 'school@gmail.com', 'email_verified': true}));
    expect(result.subject, 'school-owner');
    expect(result.accessToken, 'access-only');
  });
  test('Unavailable or mismatched broker never opens Google or exchanges a code', () async {
    for (final response in [http.Response('unavailable', 503),
        json({'service': 'saarthi-oauth-exchange', 'clientIdFingerprint': 'wrong'})]) {
      var opened = false;
      var requests = 0;
      final auth = GoogleAuthorization(oauthClientId: 'test.apps.googleusercontent.com',
        oauthBrokerUrl: 'https://oauth.example.test/oauth/token',
        client: MockClient((request) async {
          requests++;
          expect(request.url.path, '/healthz');
          expect(request.method, 'GET');
          return response;
        }), openBrowser: (_) async { opened = true; });
      try {
        await expectLater(HttpOverrides.runWithHttpOverrides(
          () => auth.authorize(script: false), LoopbackHttpOverrides()), throwsStateError);
        expect(opened, isFalse);
        expect(requests, 1);
      } finally { auth.close(); }
    }
  });
  test('Broker URLs reject insecure transports, credentials and query/fragment leaks', () {
    expect(GoogleAuthorization.validBrokerUrl('https://oauth.example.test/oauth/token'), isTrue);
    for (final url in ['http://oauth.example.test/oauth/token',
      'https://user:secret@oauth.example.test/oauth/token',
      'https://oauth.example.test/oauth/token?code=secret',
      'https://oauth.example.test/oauth/token#secret',
      'https://oauth.example.test/other', 'https://oauth.example.test:444/oauth/token']) {
      expect(GoogleAuthorization.validBrokerUrl(url), isFalse);
    }
  });
  test('Required missing broker fails before opening browser', () async {
    var opened = false;
    final auth = GoogleAuthorization(oauthClientId: 'test.apps.googleusercontent.com',
      requiresBroker: true, openBrowser: (_) async { opened = true; });
    await expectLater(auth.authorize(script: false), throwsStateError);
    expect(opened, isFalse);
    auth.close();
  });
  test('Missing secret and expired codes give actionable sanitized token errors', () {
    final missing = GoogleAuthorization.tokenError(json({'error': 'invalid_request',
      'error_description': 'client_secret is missing. private-token'}, 400));
    expect(missing.toString(), contains('secure OAuth token service'));
    expect(missing.toString(), isNot(contains('private-token')));
    final expired = GoogleAuthorization.tokenError(json({'error': 'invalid_grant',
      'error_description': 'private-token'}, 400));
    expect(expired.toString(), contains('fresh sign-in'));
    expect(expired.toString(), isNot(contains('private-token')));
  });
  test('Broker failure never falls back to a secretless or redirected exchange', () async {
    await expectLater(signInResponse(http.Response('', 302, headers: {'location': 'https://evil.test'}),
      broker: 'https://oauth.example.test/oauth/token'), throwsStateError);
  });
  test('OAuth refuses credential redirects, malformed responses and missing scopes', () async {
    for (final response in [
      http.Response('', 302, headers: {'location': 'https://evil.test'}),
      http.Response('private-token-malformed-json', 200),
      json({'access_token': 'private-token', 'scope': 'openid email'}),
    ]) {
      await expectLater(signInResponse(response), throwsA(isA<StateError>()
        .having((e) => e.toString(), 'sanitized', isNot(contains('private-token')))));
    }
  });

  test('OAuth refuses an unverified school account and user-info redirects', () async {
    final token = json({'access_token': 'private-token',
      'scope': 'openid email https://www.googleapis.com/auth/cloud-platform'});
    for (final user in [
      json({'sub': 'school-owner', 'email': 'school@gmail.com', 'email_verified': false}),
      http.Response('', 302, headers: {'location': 'https://evil.test'}),
    ]) {
      await expectLater(signInResponse(token, user: user), throwsStateError);
    }
  });

  test('Expired and malformed API responses request reconnect without leaking bodies', () async {
    for (final response in [http.Response('private-body', 401), http.Response('private-body', 200)]) {
      final api = GoogleSetupApi('secret', client: MockClient((_) async => response));
      await expectLater(api.request('GET', 'https://firebase.googleapis.com/v1beta1/projects/x'),
        throwsA(predicate((e) => !e.toString().contains('private-body'))));
      api.close();
    }
  });

  test('Google API tokens never follow redirects or reach untrusted hosts', () async {
    var calls = 0;
    final api = GoogleSetupApi('secret', client: MockClient((r) async {
      calls++;
      expect(r.followRedirects, isFalse);
      return http.Response('private-error-body', 302, headers: {'location': 'https://evil.test'});
    }));
    await expectLater(api.request('GET', 'https://evil.test'), throwsStateError);
    expect(calls, 0);
    await expectLater(api.request('GET', 'https://firebase.googleapis.com/v1beta1/projects/x'),
      throwsA(isA<SetupApiError>().having((e) => e.toString(), 'sanitized', isNot(contains('private-error-body')))));
    expect(calls, 1);
    api.close();
    await expectLater(api.request('GET', 'https://firebase.googleapis.com/v1beta1/projects/x'), throwsA(isA<SetupCancelled>()));
  });
  test('Checkpoint cannot resume under another Google account', () async {
    final storage = MemoryCheckpoint({...checkpoint(), 'accountSub': 'another-owner'});
    final setup = provisioner(storage, MockClient((_) async => fail('No cloud request allowed')));
    await expectLater(setup.begin(schoolName: '', location: ''), throwsStateError);
  });
  test('Existing unmarked project is never modified', () async {
    final setup = provisioner(MemoryCheckpoint(checkpoint()), MockClient((r) async {
      expect(r.method, 'GET');
      return json({'lifecycleState': 'ACTIVE', 'labels': {'vs-setup': 'another-school'}});
    }));
    await setup.begin(schoolName: '', location: '');
    await expectLater(setup.ensureProject(), throwsStateError);
  });
  Map<String, dynamic> activeSchool() => {'projectId': school,
    'projectNumber': '123456', 'lifecycleState': 'ACTIVE', 'labels': {'vs-setup': 'test123'}};
  Map<String, dynamic> uncreated() => checkpoint()..remove('projectNumber');
  test('New project is discovered then created without a forbidden pre-creation GET', () async {
    final storage = MemoryCheckpoint(uncreated());
    final calls = <String>[];
    final setup = provisioner(storage, MockClient((r) async {
      calls.add('${r.method} ${r.url.path}');
      if (r.method == 'GET' && r.url.path == '/v1/projects') {
        expect(r.url.queryParameters['filter'], 'id:$school');
        return json({});
      }
      if (r.method == 'POST') {
        expect(jsonDecode(r.body)['projectId'], school);
        expect(jsonDecode(r.body)['labels'], {'vs-setup': 'test123'});
        expect(jsonDecode(r.body).containsKey('parent'), isFalse);
        return json({'name': 'operations/create-test', 'done': true, 'response': activeSchool()});
      }
      fail('Pre-creation GET must not occur: ${r.url}');
    }));
    await setup.begin(schoolName: '', location: '');
    expect((await setup.ensureProject())['projectNumber'], '123456');
    expect(calls, ['GET /v1/projects', 'POST /v1/projects']);
    expect(storage.value['projectCreateOperation'], isNull);
    expect(storage.value['projectNumber'], '123456');
  });
  test('Project discovery preserves exact filter across pages and reuses marked project', () async {
    final setup = provisioner(MemoryCheckpoint(uncreated()), MockClient((r) async {
      expect(r.method, 'GET');
      expect(r.url.path, '/v1/projects');
      expect(r.url.queryParameters['filter'], 'id:$school');
      if (!r.url.queryParameters.containsKey('pageToken')) return json({'nextPageToken': 'page2'});
      return json({'projects': [activeSchool()]});
    }));
    await setup.begin(schoolName: '', location: '');
    expect((await setup.ensureProject())['projectId'], school);
  });
  test('Discovery cannot adopt a different school marker or a deleted project', () async {
    for (final cloud in [{...activeSchool(), 'labels': {'vs-setup': 'another'}},
      {...activeSchool(), 'lifecycleState': 'DELETE_REQUESTED'}]) {
      final setup = provisioner(MemoryCheckpoint(uncreated()), MockClient((r) async {
        expect(r.method, 'GET');
        return json({'projects': [cloud]});
      }));
      await setup.begin(schoolName: '', location: '');
      await expectLater(setup.ensureProject(), throwsStateError);
    }
  });
  test('Saved project creation operation resumes without duplicate POST', () async {
    final storage = MemoryCheckpoint({...uncreated(), 'projectCreateOperation': 'operations/create-test'});
    final setup = provisioner(storage, MockClient((r) async {
      expect(r.method, 'GET');
      expect(r.url.path, '/v1/operations/create-test');
      return json({'done': true, 'response': activeSchool()});
    }));
    await setup.begin(schoolName: '', location: '');
    expect((await setup.ensureProject())['projectId'], school);
    expect(storage.value['projectCreateOperation'], isNull);
  });
  test('Interrupted creation saves operation and next attempt resumes it', () async {
    final storage = MemoryCheckpoint(uncreated());
    final setup = provisioner(storage, MockClient((r) async {
      if (r.method == 'POST') return json({'name': 'operations/create-test'});
      if (r.url.path == '/v1/projects') return json({});
      throw http.ClientException('disconnected');
    }));
    await setup.begin(schoolName: '', location: '');
    await expectLater(setup.ensureProject(), throwsA(isA<http.ClientException>()));
    expect(storage.value['projectCreateOperation'], 'operations/create-test');
  });
  test('Known school project losing access never creates another project', () async {
    final setup = provisioner(MemoryCheckpoint(checkpoint()), MockClient((r) async {
      expect(r.method, 'GET');
      expect(r.url.path, '/v1/projects/$school');
      return json({}, 403);
    }));
    await setup.begin(schoolName: '', location: '');
    await expectLater(setup.ensureProject(), throwsA(isA<SetupApiError>()));
  });
  test('Project ID collision never modifies another school', () async {
    final setup = provisioner(MemoryCheckpoint(uncreated()), MockClient((r) async {
      if (r.url.path == '/v1/projects' && r.method == 'GET') return json({});
      if (r.method == 'POST') return json({}, 409);
      expect(r.method, 'GET');
      return json({...activeSchool(), 'labels': {'vs-setup': 'another'}});
    }));
    await setup.begin(schoolName: '', location: '');
    await expectLater(setup.ensureProject(), throwsStateError);
  });
  test('Disabled API and missing scope errors remain distinct and never expose raw fields', () async {
    for (final reason in ['SERVICE_DISABLED', 'ACCESS_TOKEN_SCOPE_INSUFFICIENT', 'IAM_PERMISSION_DENIED']) {
      final api = GoogleSetupApi('private-token', client: MockClient((r) async => json({'error': {
        'message': 'private-token private-password', 'details': [{
          '@type': 'type.googleapis.com/google.rpc.ErrorInfo', 'domain': 'googleapis.com', 'reason': reason,
          'metadata': {'consumer': 'projects/123456', 'permission': 'resourcemanager.projects.create',
            'activationUrl': 'https://evil.test/private-token'}}]}}, 403)));
      await expectLater(api.request('POST', 'https://cloudresourcemanager.googleapis.com/v1/projects'),
        throwsA(isA<SetupApiError>().having((e) => e.reason, 'reason', reason)
          .having((e) => e.toString(), 'sanitized', allOf(isNot(contains('private-token')),
            isNot(contains('private-password')), isNot(contains('evil.test'))))));
      api.close();
    }
  });
  test('Discovery API disabled does not fall through to project creation', () async {
    var calls = 0;
    final setup = provisioner(MemoryCheckpoint(uncreated()), MockClient((r) async {
      calls++;
      expect(r.method, 'GET');
      return json({'error': {'details': [{'@type': 'type.googleapis.com/google.rpc.ErrorInfo',
        'domain': 'googleapis.com', 'reason': 'SERVICE_DISABLED'}]}}, 403);
    }));
    await setup.begin(schoolName: '', location: '');
    await expectLater(setup.ensureProject(), throwsA(isA<SetupApiError>().having((e) => e.reason, 'reason', 'SERVICE_DISABLED')));
    expect(calls, 1);
  });
  test('Terminal operation quota failure clears operation for safe same-ID retry', () async {
    final storage = MemoryCheckpoint(uncreated());
    final setup = provisioner(storage, MockClient((r) async {
      if (r.method == 'GET') return json({});
      return json({'name': 'operations/create-test', 'done': true,
        'error': {'code': 8, 'message': 'private-body'}});
    }));
    await setup.begin(schoolName: '', location: '');
    await expectLater(setup.ensureProject(), throwsA(isA<SetupOperationError>()
      .having((e) => e.status, 'quota', 429).having((e) => e.toString(), 'safe', isNot(contains('private-body')))));
    expect(storage.value['projectCreateOperation'], isNull);
    expect(storage.value['projectId'], school);
  });

  test('Authentication initialization asks for Google approval, never enables billing', () async {
    final calls = <String>[];
    final setup = provisioner(MemoryCheckpoint({...checkpoint(), 'servicesReady': true, 'rulesReady': true}),
      MockClient((r) async {
        calls.add('${r.method} ${r.url}');
        if (r.url.host == 'cloudresourcemanager.googleapis.com') {
          return json({'lifecycleState': 'ACTIVE', 'labels': {'vs-setup': 'test123'}, 'projectNumber': '123456'});
        }
        if (r.url.host == 'firestore.googleapis.com') return json({'name': 'default'});
        if (r.url.host == 'identitytoolkit.googleapis.com') return json({}, 404);
        fail('Unexpected request ${r.url}');
      }));
    await setup.begin(schoolName: '', location: '');
    await expectLater(setup.firebase(), throwsA(isA<SetupActionRequired>()
      .having((e) => e.url.path, 'Firebase console', contains('/authentication'))));
    expect(calls.every((c) => c.startsWith('GET ')), isTrue);
    expect(calls.join(), isNot(contains('initializeAuth')));
    expect(calls.join(), isNot(contains('billing')));
  });
  test('Firebase setup creates private school resources and reuses a paginated registered app', () async {
    final storage = MemoryCheckpoint(checkpoint());
    final calls = <String>[];
    final setup = provisioner(storage, MockClient((r) async {
      calls.add('${r.method} ${r.url}');
      if (r.url.path.endsWith(':testIamPermissions')) return json({'permissions': SchoolProvisioner.firebasePermissions});
      if (r.url.host == 'cloudresourcemanager.googleapis.com') return json({
        'lifecycleState': 'ACTIVE', 'labels': {'vs-setup': 'test123'}, 'projectNumber': '123456'});
      if (r.url.host == 'serviceusage.googleapis.com') {
        expect(jsonDecode(r.body)['serviceIds'], contains('firebaserules.googleapis.com'));
        return json({'done': true});
      }
      if (r.url.host == 'firestore.googleapis.com') {
        if (r.method == 'GET') return json({}, 404);
        final body = jsonDecode(r.body);
        expect(body['deleteProtectionState'], 'DELETE_PROTECTION_ENABLED');
        expect(body['locationId'], 'asia-south1');
        return json({'done': true});
      }
      if (r.url.host == 'firebaserules.googleapis.com') {
        if (r.method == 'GET') return json({}, 404);
        final body = jsonDecode(r.body);
        if (r.url.path.endsWith('/rulesets')) {
          expect(body['source']['files'].single['content'], 'school-only-rules');
          return json({'name': 'projects/$school/rulesets/private'});
        }
        expect(body['rulesetName'], 'projects/$school/rulesets/private');
        return json({});
      }
      if (r.url.host == 'identitytoolkit.googleapis.com') {
        if (r.method == 'PATCH') expect(r.url.queryParameters['updateMask'], 'signIn.email');
        return json({});
      }
      if (r.url.path.endsWith(':addFirebase')) return json({'name': 'operations/firebase-test', 'done': true, 'response': {'projectId': school}});
      if (r.url.path.endsWith('/webApps')) {
        expect(r.method, 'GET');
        if (!r.url.queryParameters.containsKey('pageToken')) return json({'nextPageToken': 'second'});
        return json({'apps': [{'displayName': 'Vidya Saarthi test123', 'appId': 'existing-app'}]});
      }
      if (r.url.path.endsWith('/config')) return json({'projectId': school, 'apiKey': 'public-key'});
      if (r.url.path.endsWith('/$school')) return json({}, 404);
      fail('Unexpected request ${r.method} ${r.url}');
    }));
    await setup.begin(schoolName: '', location: '');
    expect((await setup.firebase())['projectId'], school);
    expect(storage.value['rulesReady'], isTrue);
    expect(storage.value['webAppId'], 'existing-app');
    expect(calls.join(), isNot(contains('billing')));
  });

  SchoolProvisioner firebaseOnly(MemoryCheckpoint storage, http.Client client,
      {Future<void> Function(Duration)? delay}) => SchoolProvisioner(api: GoogleSetupApi(account.accessToken, client: client),
    account: account, checkpoint: storage, progress: (_) {}, bundle: {}, delay: delay ?? (_) async {});
  test('Firebase permission preflight verifies exactly the four official permissions', () async {
    final setup = firebaseOnly(MemoryCheckpoint(checkpoint()), MockClient((r) async {
      expect(r.method, 'POST');
      expect(r.url.path, '/v1/projects/$school:testIamPermissions');
      expect(jsonDecode(r.body)['permissions'], SchoolProvisioner.firebasePermissions);
      return json({'permissions': SchoolProvisioner.firebasePermissions});
    }));
    await setup.begin(schoolName: '', location: '');
    await setup.verifyFirebasePermissions();
  });
  test('Owner permission propagation is retried without setting any IAM policy', () async {
    var calls = 0;
    final pauses = <int>[];
    final setup = firebaseOnly(MemoryCheckpoint(checkpoint()), MockClient((r) async {
      expect(r.url.path.endsWith(':testIamPermissions'), isTrue);
      calls++;
      return json({'permissions': calls == 3 ? SchoolProvisioner.firebasePermissions : ['resourcemanager.projects.get']});
    }), delay: (duration) async { pauses.add(duration.inSeconds); });
    await setup.begin(schoolName: '', location: '');
    await setup.verifyFirebasePermissions();
    expect(calls, 3); expect(pauses, [2, 4]);
  });
  test('Missing Firebase IAM permissions block service enablement and activation', () async {
    var calls = 0;
    final setup = firebaseOnly(MemoryCheckpoint(checkpoint()), MockClient((r) async {
      calls++;
      if (r.method == 'GET') return json(activeSchool());
      expect(r.url.path.endsWith(':testIamPermissions'), isTrue);
      return json({'permissions': ['resourcemanager.projects.get']});
    }));
    await setup.begin(schoolName: '', location: '');
    await expectLater(setup.firebase(), throwsA(isA<StateError>().having((e) => e.message.toString(),
      'missing permission', contains('firebase.projects.update'))));
    expect(calls, 5);
  });
  test('Explicit Firebase terms failures are classified without copying error body', () async {
    final error = SetupApiError.fromGoogle(403, 'firebase.googleapis.com', {
      'error': {'message': 'Firebase Terms of Service must be accepted. private-token', 'details': []}}, operation: 'addFirebase');
    expect(error.reason, 'FIREBASE_TERMS_REQUIRED');
    expect(error.toString(), contains('no API'));
    expect(error.toString(), isNot(contains('private-token')));
    expect(SetupApiError.fromGoogle(403, 'firebase.googleapis.com',
      {'error': {'message': 'The caller does not have permission'}}).reason, isEmpty);
  });
  test('Generic activation denial after IAM preflight does not falsely confirm missing terms', () async {
    final storage = MemoryCheckpoint(checkpoint());
    final setup = firebaseOnly(storage, MockClient((r) async {
      if (r.url.path.endsWith(':testIamPermissions')) return json({'permissions': SchoolProvisioner.firebasePermissions});
      if (r.method == 'GET') return json({}, 404);
      expect(r.url.path.endsWith(':addFirebase'), isTrue);
      return json({'error': {'message': 'private-token caller does not have permission'}}, 403);
    }));
    await setup.begin(schoolName: '', location: '');
    await setup.verifyFirebasePermissions();
    await expectLater(setup.activateFirebase(), throwsA(isA<FirebaseActivationDenied>()
      .having((e) => e.toString(), 'confirmed permissions', contains('four required'))
      .having((e) => e.toString(), 'uncertain terms', contains('may be blocking'))
      .having((e) => e.toString(), 'private', isNot(contains('private-token')))));
    expect(storage.value['projectId'], school);
    expect(storage.value['firebaseAddOperation'], isNull);
  });
  test('Transient Firebase permission denial retries only the same marked project', () async {
    var posts = 0;
    final pauses = <int>[];
    final setup = firebaseOnly(MemoryCheckpoint(checkpoint()), MockClient((r) async {
      if (r.method == 'GET') return json({}, 404);
      expect(r.url.path, '/v1beta1/projects/$school:addFirebase');
      posts++;
      return posts == 1 ? json({}, 403) : json({'name': 'operations/firebase-test',
        'done': true, 'response': {'projectId': school}});
    }), delay: (duration) async { pauses.add(duration.inSeconds); });
    await setup.begin(schoolName: '', location: '');
    await setup.activateFirebase();
    expect(posts, 2); expect(pauses, [2]);
  });
  test('Confirmed Firebase terms denial is never replayed or accepted automatically', () async {
    var posts = 0;
    final setup = firebaseOnly(MemoryCheckpoint(checkpoint()), MockClient((r) async {
      if (r.method == 'GET') return json({}, 404);
      posts++;
      return json({'error': {'message': 'Firebase Terms of Service not accepted private-token'}}, 403);
    }), delay: (_) async { fail('Terms rejection must not be retried'); });
    await setup.begin(schoolName: '', location: '');
    await expectLater(setup.activateFirebase(), throwsA(isA<FirebaseActivationDenied>()
      .having((e) => e.error.reason, 'confirmed terms', 'FIREBASE_TERMS_REQUIRED')));
    expect(posts, 1);
  });
  test('Disabled API and missing scopes are not misreported as Firebase terms', () async {
    for (final reason in ['SERVICE_DISABLED', 'ACCESS_TOKEN_SCOPE_INSUFFICIENT']) {
      final setup = firebaseOnly(MemoryCheckpoint(checkpoint()), MockClient((r) async {
        if (r.method == 'GET') return json({}, 404);
        return json({'error': {'details': [{'@type': 'type.googleapis.com/google.rpc.ErrorInfo',
          'domain': 'googleapis.com', 'reason': reason}]}}, 403);
      }));
      await setup.begin(schoolName: '', location: '');
      await expectLater(setup.activateFirebase(), throwsA(isA<SetupApiError>().having((e) => e.reason, 'reason', reason)));
    }
  });
  test('Firebase operation is saved before interrupted polling, preventing duplicate activation', () async {
    final storage = MemoryCheckpoint(checkpoint());
    final setup = firebaseOnly(storage, MockClient((r) async {
      if (r.url.path.endsWith(':addFirebase')) return json({'name': 'operations/add-firebase'});
      if (r.url.path.contains('/operations/')) throw http.ClientException('disconnected');
      return json({}, 404);
    }));
    await setup.begin(schoolName: '', location: '');
    await expectLater(setup.activateFirebase(), throwsA(isA<http.ClientException>()));
    expect(storage.value['firebaseAddOperation'], 'operations/add-firebase');
    final resumed = firebaseOnly(storage, MockClient((r) async {
      expect(r.method, 'GET');
      if (r.url.path.contains('/operations/')) return json({'done': true, 'response': {'projectId': school}});
      return json({}, 404);
    }));
    await resumed.begin(schoolName: '', location: '');
    await resumed.activateFirebase();
    expect(storage.value['firebaseAddOperation'], isNull);
  });
  test('Deleted completed Firebase operation recovers by checking the existing school', () async {
    final storage = MemoryCheckpoint({...checkpoint(), 'firebaseAddOperation': 'operations/add-firebase'});
    var reads = 0;
    final setup = firebaseOnly(storage, MockClient((r) async {
      expect(r.method, 'GET');
      if (r.url.path.contains('/operations/')) return json({}, 404);
      reads++;
      return reads == 1 ? json({}, 404) : json({'projectId': school});
    }));
    await setup.begin(schoolName: '', location: '');
    await setup.activateFirebase();
    expect(storage.value['firebaseAddOperation'], isNull);
  });
  test('Firebase registration and activation errors have different operation labels', () async {
    for (final entry in {'/v1beta1/projects/$school:addFirebase': 'addFirebase',
      '/v1beta1/projects/$school/webApps': 'registerWebApp'}.entries) {
      final api = GoogleSetupApi('secret', client: MockClient((r) async => json({}, 403)));
      await expectLater(api.request('POST', 'https://firebase.googleapis.com${entry.key}'),
        throwsA(isA<SetupApiError>().having((e) => e.operation, 'exact operation', entry.value)));
      api.close();
    }
  });

  test('Quota diagnostics retain structured identifiers without private bodies', () {
    final error = SetupApiError.fromGoogle(429, 'cloudresourcemanager.googleapis.com', {
      'error': {'message': 'private-token-body', 'details': [{
        '@type': 'type.googleapis.com/google.rpc.ErrorInfo',
        'domain': 'cloudresourcemanager.googleapis.com', 'reason': 'QUOTA_EXCEEDED',
        'metadata': {'consumer': 'projects/123',
          'quota_metric': 'cloudresourcemanager.googleapis.com/projects_count',
          'quota_limit': 'ProjectsCount', 'quota_limit_value': '10'}}]}}, operation: 'createProject');
    expect(error.toString(), contains('createProject'));
    expect(error.toString(), contains('projects_count'));
    expect(error.toString(), contains('consumer=projects/123'));
    expect(error.toString(), contains('limit value=10'));
    expect(error.toString(), contains('waiting alone will not'));
    expect(error.toString(), isNot(contains('private-token-body')));
  });
  test('Unknown quota is not incorrectly classified as project count', () {
    final error = SetupApiError.fromGoogle(429, 'firebase.googleapis.com', {'error': {
      'details': [{'@type': 'type.googleapis.com/google.rpc.ErrorInfo', 'domain': 'attacker.example',
        'reason': 'QUOTA_EXCEEDED', 'metadata': {'quota_metric': 'private-token'}}]}});
    expect(error.toString(), contains('Exact quota identifier was not supplied'));
    expect(error.toString(), isNot(contains('capacity is exhausted')));
    expect(error.toString(), isNot(contains('private-token')));
  });
  test('Terminal operation retains quota and original activation operation', () async {
    final api = GoogleSetupApi('secret');
    await expectLater(api.waitOperation('firebase.googleapis.com', {'done': true, 'error': {
      'code': 8, 'details': [{'@type': 'type.googleapis.com/google.rpc.ErrorInfo',
        'domain': 'googleapis.com', 'reason': 'RATE_LIMIT_EXCEEDED',
        'metadata': {'quota_limit': 'RequestsPerMinute'}}]}}, operationLabel: 'addFirebase'),
      throwsA(isA<SetupOperationError>().having((e) => e.operation, 'operation', 'addFirebase')
        .having((e) => e.quotaLimit, 'limit', 'RequestsPerMinute')
        .having((e) => e.toString(), 'rate guidance', contains('API rate limit'))));
    api.close();
  });

  test('Apps Script permission failure is resumable without duplicate project', () async {
    final storage = MemoryCheckpoint({...checkpoint(), 'firebaseConnected': true});
    final setup = provisioner(storage, MockClient((r) async {
      if (r.method == 'GET') return json({'lifecycleState': 'ACTIVE', 'labels': {'vs-setup': 'test123'}, 'projectNumber': '123456'});
      return json({}, 403);
    }));
    await setup.begin(schoolName: '', location: '');
    await expectLater(setup.prepareScript(), throwsA(isA<SetupActionRequired>()));
    expect(storage.value['scriptCreatePending'], isNull);
  });
  test('Uncertain script creation is not duplicated on retry', () async {
    final setup = provisioner(MemoryCheckpoint({...checkpoint(), 'firebaseConnected': true, 'scriptCreatePending': true}),
      MockClient((r) async {
        expect(r.method, 'GET');
        return json({'lifecycleState': 'ACTIVE', 'labels': {'vs-setup': 'test123'}, 'projectNumber': '123456'});
      }));
    await setup.begin(schoolName: '', location: '');
    await expectLater(setup.prepareScript(), throwsA(isA<SetupActionRequired>()));
  });
  test('Resume discovers owner-approved manual script deployment without creating another', () async {
    final storage = MemoryCheckpoint({...checkpoint(), 'scriptId': 'script-1'});
    final setup = provisioner(storage, MockClient((r) async {
      expect(r.method, 'GET');
      return json({'deployments': [{'deploymentConfig': {'description': 'School manually approved'},
        'entryPoints': [{'entryPointType': 'WEB_APP', 'webApp': {
          'url': 'https://script.google.com/macros/s/deployment/exec',
          'entryPointConfig': {'executeAs': 'USER_DEPLOYING', 'access': 'ANYONE_ANONYMOUS'}}}]}]});
    }));
    await setup.begin(schoolName: '', location: '');
    expect(await setup.deployScript(), 'https://script.google.com/macros/s/deployment/exec');
    expect(storage.value['scriptUrl'], contains('/exec'));
  });
  test('Deployment discovery follows all pages without creating duplicate resources', () async {
    final setup = provisioner(MemoryCheckpoint({...checkpoint(), 'scriptId': 'script-1'}),
      MockClient((r) async {
        expect(r.method, 'GET');
        if (!r.url.queryParameters.containsKey('pageToken')) return json({'nextPageToken': 'page-two'});
        expect(r.url.queryParameters['pageToken'], 'page-two');
        return json({'deployments': [{'entryPoints': [{'entryPointType': 'WEB_APP', 'webApp': {
          'url': 'https://script.google.com/macros/s/deployment/exec',
          'entryPointConfig': {'executeAs': 'USER_DEPLOYING', 'access': 'ANYONE_ANONYMOUS'}}}]}]});
      }));
    await setup.begin(schoolName: '', location: '');
    expect(await setup.deployScript(), contains('/exec'));
  });

  test('Repeated pagination stops rather than creating duplicate deployments', () async {
    final setup = provisioner(MemoryCheckpoint({...checkpoint(), 'scriptId': 'script-1'}),
      MockClient((r) async {
        expect(r.method, 'GET');
        return json({'nextPageToken': 'same-page'});
      }));
    await setup.begin(schoolName: '', location: '');
    await expectLater(setup.deployScript(), throwsStateError);
  });

  test('Deployment retry reuses saved script version', () async {
    final setup = provisioner(MemoryCheckpoint({...checkpoint(), 'scriptId': 'script-1', 'scriptVersion': 8}),
      MockClient((r) async {
        expect(r.url.path, isNot(endsWith('/versions')));
        if (r.method == 'GET') return json({});
        expect(jsonDecode(r.body)['versionNumber'], 8);
        return json({'entryPoints': [{'entryPointType': 'WEB_APP', 'webApp': {
          'url': 'https://script.google.com/macros/s/deployment/exec',
          'entryPointConfig': {'executeAs': 'USER_DEPLOYING', 'access': 'ANYONE_ANONYMOUS'}}}]});
      }));
    await setup.begin(schoolName: '', location: '');
    expect(await setup.deployScript(), contains('/exec'));
  });

  test('Admin resume preserves existing claims only for the exact generated identity', () async {
    final setup = provisioner(MemoryCheckpoint({...checkpoint(),
      'firebaseConfig': {'projectId': school, 'apiKey': 'public-key'},
      'adminUid': 'generated-admin', 'adminPassword': 'generated-password'}), MockClient((r) async {
        if (r.url.host == 'cloudresourcemanager.googleapis.com') return json({
          'lifecycleState': 'ACTIVE', 'labels': {'vs-setup': 'test123'}, 'projectNumber': '123456'});
        if (r.url.path.endsWith(':lookup')) return json({'users': [{
          'localId': 'generated-admin', 'email': account.email,
          'customAttributes': jsonEncode({'schoolFeature': true})}]});
        expect(r.url.path, endsWith(':update'));
        final claims = jsonDecode(jsonDecode(r.body)['customAttributes']);
        expect(claims, {'schoolFeature': true, 'admin': true});
        return json({});
      }));
    await setup.begin(schoolName: '', location: '');
    expect(await setup.adminPassword(), 'generated-password');
  });

  test('Admin creation cannot elevate a foreign or disabled identity', () async {
    for (final user in [
      {'localId': 'foreign-admin', 'email': account.email},
      {'localId': 'generated-admin', 'email': 'another@gmail.com'},
      {'localId': 'generated-admin', 'email': account.email, 'disabled': true},
    ]) {
      final setup = provisioner(MemoryCheckpoint({...checkpoint(),
        'firebaseConfig': {'projectId': school, 'apiKey': 'public-key'}, 'adminUid': 'generated-admin'}),
        MockClient((r) async {
          if (r.url.host == 'cloudresourcemanager.googleapis.com') return json({
            'lifecycleState': 'ACTIVE', 'labels': {'vs-setup': 'test123'}, 'projectNumber': '123456'});
          expect(r.url.path, endsWith(':lookup'));
          return json({'users': [user]});
        }));
      await setup.begin(schoolName: '', location: '');
      await expectLater(setup.adminPassword(), throwsStateError);
    }
  });

  test('Unexpected newly created admin UID never receives an admin claim', () async {
    final setup = provisioner(MemoryCheckpoint({...checkpoint(),
      'firebaseConfig': {'projectId': school, 'apiKey': 'public-key'}}), MockClient((r) async {
        if (r.url.host == 'cloudresourcemanager.googleapis.com') return json({
          'lifecycleState': 'ACTIVE', 'labels': {'vs-setup': 'test123'}, 'projectNumber': '123456'});
        if (r.url.path.endsWith(':lookup')) return json({});
        expect(r.url.path, endsWith(':signUp'));
        return json({'localId': 'foreign-identity'});
      }));
    await setup.begin(schoolName: '', location: '');
    await expectLater(setup.adminPassword(), throwsStateError);
  });

  test('Unsaved backend identity and health verified through safe Google redirects', () async {
    var calls = 0;
    await verifySchoolBackend(Uri.parse('https://script.google.com/macros/s/school/exec'), school,
      client: MockClient((r) async {
        calls++;
        expect(r.headers.containsKey('Authorization'), isFalse);
        expect(r.followRedirects, isFalse);
        if (r.method == 'POST') return http.Response('', 302,
          headers: {'location': 'https://script.googleusercontent.com/macros/echo?test=1'});
        if (r.url.host == 'script.googleusercontent.com') return json({'success': true, 'projectId': school, 'windowsAdminProtection': true});
        return json({'success': true, 'working': true, 'rootFolderAccessible': true});
      }));
    expect(calls, 3);
  });
  test('Wrong school, unsafe redirects and false health cannot connect', () async {
    final uri = Uri.parse('https://script.google.com/macros/s/school/exec');
    for (final bad in [json({'success': true, 'projectId': 'other-school', 'windowsAdminProtection': true}),
      http.Response('', 302, headers: {'location': 'https://evil.test/'})]) {
      await expectLater(verifySchoolBackend(uri, school, client: MockClient((_) async => bad)), throwsStateError);
    }
    await expectLater(verifySchoolBackend(uri, school, client: MockClient((r) async => r.method == 'POST'
      ? json({'success': true, 'projectId': school, 'windowsAdminProtection': true})
      : json({'success': true, 'working': false, 'rootFolderAccessible': false}))), throwsStateError);
  });
  testWidgets('Unconfigured preview explains developer prerequisite and disables sign-in', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: EasySchoolConnectScreen()));
    expect(find.textContaining('Developer setup is pending'), findsOneWidget);
    final signIn = tester.widget<FilledButton>(find.byKey(const ValueKey('school-google-sign-in')));
    expect(signIn.onPressed, isNull);
    expect(find.textContaining('No billing account'), findsOneWidget);
    expect(find.text('Google account: Not verified'), findsOneWidget);
    expect(find.text('Firebase: Not verified'), findsOneWidget);
    expect(find.text('Firestore: Not verified'), findsOneWidget);
  });
  testWidgets('Drive preview never claims storage is ready before verification', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: EasySchoolConnectScreen(googleDrive: true)));
    expect(find.text('Google Drive: Not verified'), findsOneWidget);
    expect(find.text('School storage: Not verified'), findsOneWidget);
    expect(find.text('School storage: Ready'), findsNothing);
    expect(tester.takeException(), isNull);
  });

}

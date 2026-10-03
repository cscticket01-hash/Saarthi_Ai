import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

String secureSetupToken([int bytes = 32]) => base64Url
    .encode(List<int>.generate(bytes, (_) => Random.secure().nextInt(256)))
    .replaceAll('=', '');

class GoogleSetupAccount {
  const GoogleSetupAccount(this.subject, this.email, this.accessToken);
  final String subject, email, accessToken;
}

class SetupCancelled implements Exception {
  @override
  String toString() => 'Connection cancelled. Existing school data is unchanged.';
}

class GoogleAuthorization {
  GoogleAuthorization({http.Client? client, this.openBrowser = openGooglePage,
      this.oauthClientId = clientId, this.oauthBrokerUrl = brokerUrl,
      this.requiresBroker = brokerRequired})
      : client = client ?? http.Client();
  final http.Client client;
  final String oauthClientId, oauthBrokerUrl;
  final bool requiresBroker;
  bool _cancelled = false;
  final Future<void> Function(Uri) openBrowser;
  static const clientId = String.fromEnvironment('SAARTHI_GOOGLE_DESKTOP_CLIENT_ID');
  // Installed public client: PKCE, never embed an OAuth secret.
  static const brokerUrl = String.fromEnvironment('SAARTHI_GOOGLE_OAUTH_BROKER_URL');
  static const brokerRequired = bool.fromEnvironment('SAARTHI_GOOGLE_REQUIRES_BROKER');
  static bool validBrokerUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty &&
        uri.userInfo.isEmpty && uri.path == '/oauth/token' &&
        !uri.hasQuery && !uri.hasFragment && (!uri.hasPort || uri.port == 443);
  }
  static bool get configured => clientId.endsWith('.apps.googleusercontent.com') &&
      (!brokerRequired || validBrokerUrl(brokerUrl));
  static String get configurationIssue => brokerRequired && !validBrokerUrl(brokerUrl)
      ? 'Google requires a secure server-side token exchange for this Desktop client. The developer must configure the OAuth token service before testing connection. No client secret is needed from the school.'
      : 'Developer setup is pending for Google Connect in this build. Existing connections remain available.';

  HttpServer? _server;
  Completer<String>? _pending;

  static String challenge(String verifier) =>
      base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');

  static bool validCallback(Uri uri, String state) =>
      uri.path == '/oauth2/callback' &&
      uri.queryParametersAll['state']?.length == 1 &&
      uri.queryParameters['state'] == state &&
      ((uri.queryParametersAll['code']?.length == 1 &&
          (uri.queryParameters['code']?.isNotEmpty ?? false) && !uri.queryParameters.containsKey('error')) ||
          (uri.queryParametersAll['error']?.length == 1 && !uri.queryParameters.containsKey('code')));

  Future<GoogleSetupAccount> authorize({required bool script}) async {
    if (!oauthClientId.endsWith('.apps.googleusercontent.com')) throw StateError('Google Connect is not enabled in this build. Ask the developer to configure the Google Desktop OAuth client.');
    if ((requiresBroker || oauthBrokerUrl.isNotEmpty) && !validBrokerUrl(oauthBrokerUrl)) {
      throw StateError('The secure Google OAuth token service is not configured. Contact the developer; do not enter a client secret in the app.');
    }
    if (_pending != null) throw StateError('Google sign-in is already open.');
    _cancelled = false;
    final scopes = <String>['openid', 'email', 'https://www.googleapis.com/auth/cloud-platform',
      if (script) ...['https://www.googleapis.com/auth/script.projects',
        'https://www.googleapis.com/auth/script.deployments']];
    final verifier = secureSetupToken(48), state = secureSetupToken();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    final pending = Completer<String>();
    _pending = pending;
    final redirect = 'http://127.0.0.1:${server.port}/oauth2/callback';
    final subscription = server.listen((request) async {
      request.response.headers.set('Cache-Control', 'no-store');
      request.response.headers.set('Content-Security-Policy', "default-src 'none'");
      if (request.method != 'GET' || !validCallback(request.uri, state)) {
        request.response.statusCode = 400;
        request.response.write('Invalid sign-in response. Return to the app.');
      } else if (!pending.isCompleted) {
        if (request.uri.queryParameters.containsKey('error')) {
          pending.completeError(SetupCancelled());
          request.response.write('Permission was not granted. You can return to the app.');
        } else {
          pending.complete(request.uri.queryParameters['code']!);
          request.response.write('Google sign-in received. Return to Vidya Saarthi.');
        }
      }
      await request.response.close();
    });
    try {
      // Attach the error handler before opening the browser, including Cancel.
      final codeFuture = pending.future.timeout(const Duration(minutes: 5));
      // Observe early cancellation/browser failures before awaiting the code.
      unawaited(codeFuture.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
      await openBrowser(Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': oauthClientId, 'redirect_uri': redirect, 'response_type': 'code',
        'scope': scopes.join(' '), 'state': state,
        'code_challenge': challenge(verifier), 'code_challenge_method': 'S256',
        'access_type': 'online', 'prompt': 'select_account consent',
      }));
      final code = await codeFuture;
      if (_cancelled) throw SetupCancelled();
      final fields = {'code': code, 'code_verifier': verifier, 'redirect_uri': redirect};
      final request = oauthBrokerUrl.isEmpty
          ? (http.Request('POST', Uri.https('oauth2.googleapis.com', '/token'))
            ..bodyFields = {'client_id': oauthClientId, 'grant_type': 'authorization_code', ...fields})
          : (http.Request('POST', Uri.parse(oauthBrokerUrl))
            ..headers['Content-Type'] = 'application/json'
            ..body = jsonEncode(fields));
      final tokenResponse = await _send(request);
      if (_cancelled) throw SetupCancelled();
      if (tokenResponse.statusCode != 200) throw tokenError(tokenResponse);
      final token = _decode(tokenResponse.body);
      final granted = (token['scope'] as String? ?? '').split(' ').toSet();
      // Google may return the canonical userinfo.email scope instead of email.
      final needed = scopes.where((s) => s != 'email' && s != 'openid');
      if (!needed.every(granted.contains)) throw StateError('Required permissions were not granted. No school setup was started.');
      final access = token['access_token']?.toString() ?? '';
      if (access.isEmpty) throw StateError('Google access token missing.');
      final user = await _send(http.Request('GET', Uri.https('openidconnect.googleapis.com', '/v1/userinfo'))
        ..headers['Authorization'] = 'Bearer $access');
      if (user.statusCode != 200) throw StateError('Google account could not be verified.');
      final info = _decode(user.body);
      if (info['email_verified'] != true || info['sub'] is! String || info['email'] is! String) {
        throw StateError('A verified school Google account is required.');
      }
      if (_cancelled) throw SetupCancelled();
      return GoogleSetupAccount(info['sub'], info['email'], access);
    } finally {
      if (!pending.isCompleted) pending.completeError(SetupCancelled());
      _pending = null;
      _server = null;
      await subscription.cancel();
      await server.close(force: true);
    }
  }

  Future<http.Response> _send(http.Request request) async {
    request.followRedirects = false;
    final response = await http.Response.fromStream(await client.send(request)
        .timeout(const Duration(seconds: 30))).timeout(const Duration(seconds: 30));
    if (_cancelled) throw SetupCancelled();
    return response;
  }

  static StateError tokenError(http.Response response) {
    var error = '';
    var missingSecret = false;
    try {
      final data = jsonDecode(response.body);
      if (data is Map) {
        error = data['error'] is String ? data['error'] : '';
        final description = data['error_description'];
        missingSecret = error == 'invalid_request' && description is String &&
            RegExp(r'client_secret.*missing', caseSensitive: false).hasMatch(description);
      }
    } catch (_) {}
    if (missingSecret || error == 'server_configuration_error' || error == 'invalid_client') {
      return StateError('Google requires a correctly configured secure OAuth token service for this client. Contact the developer; reconnecting alone will not fix this. No school setup was started.');
    }
    if (error == 'invalid_grant') {
      return StateError('Google sign-in code expired, was already used or could not be validated. Start a fresh sign-in with the same school account.');
    }
    if (response.statusCode == 429 || error == 'rate_limited') {
      return StateError('Google connection is busy. Wait a moment and start a fresh sign-in.');
    }
    return StateError('Google token exchange failed (HTTP ${response.statusCode}). Start a fresh sign-in; if it repeats, contact the developer.');
  }

  static Map<String, dynamic> _decode(String body) {
    try {
      final value = jsonDecode(body);
      if (value is Map) return Map<String, dynamic>.from(value);
    } catch (_) {}
    // Do not include raw OAuth responses, codes or tokens in UI exceptions.
    throw StateError('Google returned an invalid sign-in response. Please reconnect.');
  }

  void cancel() {
    _cancelled = true;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) pending.completeError(SetupCancelled());
    _server?.close(force: true);
  }

  void close() { cancel(); client.close(); }
}

Future<void> openGooglePage(Uri uri) async {
  if (uri.scheme != 'https' || !{'accounts.google.com', 'console.firebase.google.com',
    'console.cloud.google.com', 'script.google.com'}.contains(uri.host) || uri.userInfo.isNotEmpty) {
    throw StateError('Untrusted setup page blocked.');
  }
  if (!Platform.isWindows) throw StateError('This connection wizard is for Windows.');
  // Argument array, no cmd.exe or shell interpolation of URLs.
  final result = await Process.run('rundll32.exe', ['url.dll,FileProtocolHandler', uri.toString()]);
  if (result.exitCode != 0) throw StateError('Could not open the browser.');
}

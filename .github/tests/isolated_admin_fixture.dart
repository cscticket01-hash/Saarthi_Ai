// TEST fixture authentication is separate from admission of a physical school PC.
// Hosted runners are disposable; admitting each run consumes the school's five
// durable PC slots. This uses the same authenticated fixture API as the Node
// setup scripts. Device enforcement, when enabled, still rejects this request.
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../../lib/platform/platform_config.dart';
import '../../lib/windows_connect/central_school_cloud.dart';
import '../../lib/windows_secure_storage.dart';

Future<Map<String, dynamic>> authenticateIsolatedAdminFixture(
    String email, String password, {required String endpoint,
    http.Client? client}) async {
  const school = 'vs-db8afb01a3be46a983c8284714d06e5d';
  if (endpoint != 'https://saarthi-sync-v2-test.onrender.com/school-cloud') {
    throw StateError('Only the isolated TEST fixture endpoint is permitted');
  }
  CentralSchoolCloud.clearFirebaseToken();
  final cloud = CentralSchoolCloud(endpoint: endpoint, client: client);
  try {
    final auth = await cloud.send('POST', Uri.https(
        'identitytoolkit.googleapis.com', '/v1/accounts:signInWithPassword',
        {'key': platformApiKey}), body: {
      'email': email.trim(), 'password': password, 'returnSecureToken': true,
    });
    if (auth['idToken'] is! String || auth['refreshToken'] is! String ||
        auth['localId'] is! String) throw StateError('TEST fixture login failed');
    final session = await cloud.api({'action': 'managed/session',
      'schoolId': school}, token: auth['idToken']);
    final config = managedSessionConfiguration(session, school, auth['localId']);
    if (session['allowed'] != true || session['storageReady'] != true) {
      throw StateError('TEST fixture entitlement and signed storage required');
    }
    await const WindowsSecureStorage().write(key: CentralSchoolCloud.key,
      value: jsonEncode({'managed': true, 'endpoint': endpoint,
        'projectId': platformProjectId, 'schoolId': school,
        'uid': auth['localId'], 'email': auth['email'] ?? email.trim(),
        'firebaseRefreshToken': auth['refreshToken'], 'folderId': 'managed',
        ...config, 'verifiedAccess': session}));
    return session;
  } finally { cloud.close(); }
}

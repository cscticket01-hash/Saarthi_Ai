import 'dart:convert';
import 'package:http/http.dart' as http;
import '../school_backend_transport.dart';

/// Probe an unsaved connection without privileged Google OAuth tokens, Firebase
/// credentials or the local/offline fallback used by normal school operations.
Future<void> verifySchoolBackend(Uri uri, String project, {http.Client? client}) async {
  requireSchoolBackendUri(uri);
  requireSchoolProjectId(project);
  if (uri.host != 'script.google.com' || !RegExp(r'^/macros/s/[^/]+/exec$').hasMatch(uri.path)) {
    throw StateError('A deployed school Apps Script web app is required.');
  }
  final transport = client ?? http.Client();
  try {
    Future<Map<String, dynamic>> read(String action, {bool post = false}) async {
      var target = post ? uri : uri.replace(queryParameters: {'action': action});
      var method = post ? 'POST' : 'GET';
      for (var hops = 0; hops < 5; hops++) {
        requireSchoolBackendUri(target);
        final request = http.Request(method, target)..followRedirects = false;
        request.headers['Accept'] = 'application/json';
        if (method == 'POST') {
          request.headers['Content-Type'] = 'text/plain;charset=utf-8';
          request.body = jsonEncode({'action': action});
        }
        final response = await http.Response.fromStream(await transport.send(request)
          .timeout(const Duration(seconds: 25))).timeout(const Duration(seconds: 25));
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers['location'];
          if (location == null) throw StateError('School redirect address missing.');
          target = target.resolve(location);
          requireSchoolBackendUri(target);
          if ({301, 302, 303}.contains(response.statusCode)) method = 'GET';
          continue;
        }
        if (response.statusCode != 200) throw StateError('School backend is not ready.');
        final data = jsonDecode(response.body);
        if (data is! Map || data['success'] != true) throw StateError('School verification failed.');
        return Map<String, dynamic>.from(data);
      }
      throw StateError('Too many school backend redirects.');
    }
    final identity = await read('mobile_project_info', post: true);
    if (identity['projectId'] != project || identity['windowsAdminProtection'] != true) {
      throw StateError('School identity or administrator protection mismatch.');
    }
    final health = await read('health_check');
    if (health['working'] != true || health['rootFolderAccessible'] != true) {
      throw StateError('School Drive storage is not ready.');
    }
  } finally {
    if (client == null) transport.close();
  }
}

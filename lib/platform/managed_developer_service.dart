import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class DeveloperRequestException implements Exception {
  const DeveloperRequestException(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

class ManagedDeveloperService {
  static http.Client? _transport;
  static String? _uid;
  static const endpoint = String.fromEnvironment('SAARTHI_SCHOOL_CLOUD_URL');

  static Future<Map<String, dynamic>> login(
    String action,
    Map<String, dynamic> body,
  ) => _post('login/$action', body, timeout: const Duration(seconds: 30));

  static Future<Map<String, dynamic>> call(
    String action,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 180),
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Developer login required');
    final token = await user.getIdToken();
    return _post(action, body, token: token, uid: user.uid, timeout: timeout);
  }

  static Future<Map<String, dynamic>> _post(
    String action,
    Map<String, dynamic> body, {
    String? token,
    String? uid,
    required Duration timeout,
  }) async {
    if (endpoint.isEmpty) {
      throw StateError(
        'Managed account server is not configured in this build',
      );
    }
    if (_transport == null || _uid != uid) {
      _transport?.close();
      _transport = http.Client();
      _uid = uid;
    }
    final response = await _transport!
        .post(
          Uri.parse(endpoint),
          headers: {
            'Content-Type': 'application/json',
            if (token != null) 'Authorization': 'Bearer $token',
          },
          body: jsonEncode({...body, 'action': 'developer/managed/$action'}),
        )
        .timeout(timeout);
    final result = jsonDecode(response.body);
    if (response.statusCode != 200 ||
        result is! Map ||
        result['success'] != true) {
      throw DeveloperRequestException(
        response.statusCode,
        result is Map
            ? result['message']?.toString() ?? 'Developer operation failed'
            : 'Invalid server response',
      );
    }
    return Map<String, dynamic>.from(result);
  }

  static Future<void> signOut() async {
    try {
      await call('session/end', {}, timeout: const Duration(seconds: 5));
    } catch (_) {
      // Local sign-out remains available when the broker is offline.
    } finally {
      await FirebaseAuth.instance.signOut();
    }
  }
}

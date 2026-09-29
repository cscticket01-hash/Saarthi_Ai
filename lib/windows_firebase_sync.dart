import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'windows_local_settings.dart';

class WindowsFirebaseRemoteStatus {
  const WindowsFirebaseRemoteStatus({
    required this.configSaved,
    required this.authenticated,
    required this.projectId,
    required this.email,
  });

  final bool configSaved;
  final bool authenticated;
  final String projectId;
  final String email;
}

class WindowsFirebaseConnectResult {
  const WindowsFirebaseConnectResult({
    required this.projectId,
    required this.email,
  });

  final String projectId;
  final String email;
}

class WindowsFirebaseRemote {
  WindowsFirebaseRemote._();

  static const FlutterSecureStorage _secure =
      FlutterSecureStorage();

  static const String _emailKey =
      'vidya_saarthi_firebase_email_v1';

  static const String _refreshTokenKey =
      'vidya_saarthi_firebase_refresh_token_v1';

  static const String _projectIdKey =
      'vidya_saarthi_firebase_project_id_v1';

  static Future<WindowsFirebaseRemoteStatus> status() async {
    final local =
        await WindowsExternalConnections.load();

    final link =
        local['firebaseLink']
            ?.toString()
            .trim() ??
        '';

    final email =
        (await _secure.read(key: _emailKey))
                ?.trim() ??
            '';

    final refreshToken =
        (await _secure.read(
              key: _refreshTokenKey,
            ))
                ?.trim() ??
            '';

    final projectId =
        (await _secure.read(key: _projectIdKey))
                ?.trim() ??
            '';

    return WindowsFirebaseRemoteStatus(
      configSaved: link.isNotEmpty,
      authenticated:
          link.isNotEmpty &&
          email.isNotEmpty &&
          refreshToken.isNotEmpty &&
          projectId.isNotEmpty,
      projectId: projectId,
      email: email,
    );
  }

  static Future<WindowsFirebaseConnectResult>
      connectAndVerify({
    required String firebaseLink,
    required String email,
    required String password,
  }) async {
    final cleanLink = firebaseLink.trim();
    final cleanEmail = email.trim();

    if (cleanEmail.isEmpty) {
      throw StateError(
        'Firebase Admin Email daalein.',
      );
    }

    if (password.isEmpty) {
      throw StateError(
        'Firebase Password daalein.',
      );
    }

    final config =
        WindowsExternalConnections
            .decodeFirebaseLink(cleanLink);

    final apiKey =
        config['apiKey']?.toString().trim() ??
        '';

    final projectId =
        config['projectId']
                ?.toString()
                .trim() ??
            '';

    if (apiKey.isEmpty || projectId.isEmpty) {
      throw StateError(
        'Firebase config incomplete hai.',
      );
    }

    final auth = await _signIn(
      apiKey: apiKey,
      email: cleanEmail,
      password: password,
    );

    final idToken =
        auth['idToken']?.toString() ?? '';

    final refreshToken =
        auth['refreshToken']?.toString() ??
        '';

    final verifiedEmail =
        auth['email']?.toString().trim() ??
        cleanEmail;

    if (idToken.isEmpty ||
        refreshToken.isEmpty) {
      throw StateError(
        'Firebase login token nahi mila.',
      );
    }

    await _verifyFirestore(
      projectId: projectId,
      idToken: idToken,
    );

    // Save only AFTER Auth + Firestore verification succeed.
    await WindowsExternalConnections.save(
      firebaseLink: cleanLink,
    );

    await _secure.write(
      key: _emailKey,
      value: verifiedEmail,
    );

    await _secure.write(
      key: _refreshTokenKey,
      value: refreshToken,
    );

    await _secure.write(
      key: _projectIdKey,
      value: projectId,
    );

    return WindowsFirebaseConnectResult(
      projectId: projectId,
      email: verifiedEmail,
    );
  }

  static Future<WindowsFirebaseConnectResult>
      testSavedConnection() async {
    final local =
        await WindowsExternalConnections.load();

    final link =
        local['firebaseLink']
            ?.toString()
            .trim() ??
        '';

    if (link.isEmpty) {
      throw StateError(
        'Firebase link saved nahi hai.',
      );
    }

    final config =
        WindowsExternalConnections
            .decodeFirebaseLink(link);

    final apiKey =
        config['apiKey']?.toString().trim() ??
        '';

    final projectId =
        config['projectId']
                ?.toString()
                .trim() ??
            '';

    final savedProjectId =
        (await _secure.read(
              key: _projectIdKey,
            ))
                ?.trim() ??
            '';

    final email =
        (await _secure.read(key: _emailKey))
                ?.trim() ??
            '';

    final refreshToken =
        (await _secure.read(
              key: _refreshTokenKey,
            ))
                ?.trim() ??
            '';

    if (refreshToken.isEmpty ||
        email.isEmpty) {
      throw StateError(
        'Firebase authentication saved nahi hai. '
        'Connect & Verify dobara karein.',
      );
    }

    if (savedProjectId.isNotEmpty &&
        savedProjectId != projectId) {
      throw StateError(
        'Saved Firebase authentication dusre project ka hai. '
        'Connect & Verify dobara karein.',
      );
    }

    final refreshed =
        await _refreshIdToken(
      apiKey: apiKey,
      refreshToken: refreshToken,
    );

    final idToken =
        refreshed['id_token']?.toString() ??
        '';

    final newRefreshToken =
        refreshed['refresh_token']
                ?.toString()
                .trim() ??
            refreshToken;

    if (idToken.isEmpty) {
      throw StateError(
        'Firebase session refresh nahi hua.',
      );
    }

    await _verifyFirestore(
      projectId: projectId,
      idToken: idToken,
    );

    await _secure.write(
      key: _refreshTokenKey,
      value: newRefreshToken,
    );

    await _secure.write(
      key: _projectIdKey,
      value: projectId,
    );

    return WindowsFirebaseConnectResult(
      projectId: projectId,
      email: email,
    );
  }

  static Future<String> freshIdToken() async {
    final local =
        await WindowsExternalConnections.load();

    final link =
        local['firebaseLink']
            ?.toString()
            .trim() ??
        '';

    if (link.isEmpty) {
      throw StateError(
        'Firebase connected nahi hai.',
      );
    }

    final config =
        WindowsExternalConnections
            .decodeFirebaseLink(link);

    final apiKey =
        config['apiKey']?.toString().trim() ??
        '';

    final refreshToken =
        (await _secure.read(
              key: _refreshTokenKey,
            ))
                ?.trim() ??
            '';

    if (refreshToken.isEmpty) {
      throw StateError(
        'Firebase session saved nahi hai.',
      );
    }

    final refreshed =
        await _refreshIdToken(
      apiKey: apiKey,
      refreshToken: refreshToken,
    );

    final idToken =
        refreshed['id_token']?.toString() ??
        '';

    final newRefreshToken =
        refreshed['refresh_token']
                ?.toString()
                .trim() ??
            refreshToken;

    if (idToken.isEmpty) {
      throw StateError(
        'Firebase session refresh nahi hua.',
      );
    }

    await _secure.write(
      key: _refreshTokenKey,
      value: newRefreshToken,
    );

    return idToken;
  }

  static Future<void> disconnect() async {
    await _secure.delete(key: _emailKey);
    await _secure.delete(
      key: _refreshTokenKey,
    );
    await _secure.delete(key: _projectIdKey);

    await WindowsExternalConnections.save(
      firebaseLink: '',
    );
  }

  static Future<Map<String, dynamic>> _signIn({
    required String apiKey,
    required String email,
    required String password,
  }) async {
    final uri = Uri.parse(
      'https://identitytoolkit.googleapis.com/'
      'v1/accounts:signInWithPassword'
      '?key=${Uri.encodeQueryComponent(apiKey)}',
    );

    final response = await _postJson(
      uri,
      <String, dynamic>{
        'email': email,
        'password': password,
        'returnSecureToken': true,
      },
    );

    if (response.statusCode < 200 ||
        response.statusCode >= 300) {
      throw StateError(
        _firebaseErrorMessage(
          response.body,
          fallback:
              'Firebase Admin login failed.',
        ),
      );
    }

    final decoded =
        jsonDecode(response.body);

    if (decoded is! Map) {
      throw StateError(
        'Firebase login response invalid hai.',
      );
    }

    return Map<String, dynamic>.from(
      decoded,
    );
  }

  static Future<Map<String, dynamic>>
      _refreshIdToken({
    required String apiKey,
    required String refreshToken,
  }) async {
    final uri = Uri.parse(
      'https://securetoken.googleapis.com/'
      'v1/token'
      '?key=${Uri.encodeQueryComponent(apiKey)}',
    );

    final client = HttpClient();

    try {
      final request =
          await client.postUrl(uri);

      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/x-www-form-urlencoded',
      );

      final body =
          'grant_type=refresh_token'
          '&refresh_token=${Uri.encodeQueryComponent(refreshToken)}';

      request.write(body);

      final response =
          await request.close();

      final responseBody =
          await utf8.decoder
              .bind(response)
              .join();

      if (response.statusCode < 200 ||
          response.statusCode >= 300) {
        throw StateError(
          _firebaseErrorMessage(
            responseBody,
            fallback:
                'Firebase session refresh failed.',
          ),
        );
      }

      final decoded =
          jsonDecode(responseBody);

      if (decoded is! Map) {
        throw StateError(
          'Firebase token response invalid hai.',
        );
      }

      return Map<String, dynamic>.from(
        decoded,
      );
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _verifyFirestore({
    required String projectId,
    required String idToken,
  }) async {
    final uri = Uri.parse(
      'https://firestore.googleapis.com/v1/'
      'projects/${Uri.encodeComponent(projectId)}/'
      'databases/(default)/documents:runQuery',
    );

    final response = await _postJson(
      uri,
      <String, dynamic>{
        'structuredQuery': <String, dynamic>{
          'from': <Map<String, dynamic>>[
            <String, dynamic>{
              'collectionId': 'school_config',
            },
          ],
          'limit': 1,
        },
      },
      bearerToken: idToken,
    );

    if (response.statusCode < 200 ||
        response.statusCode >= 300) {
      throw StateError(
        _firebaseErrorMessage(
          response.body,
          fallback:
              'Firestore access verify nahi hua.',
        ),
      );
    }
  }

  static Future<_SimpleHttpResponse> _postJson(
    Uri uri,
    Map<String, dynamic> data, {
    String? bearerToken,
  }) async {
    final client = HttpClient();

    try {
      final request =
          await client.postUrl(uri);

      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );

      if (bearerToken != null &&
          bearerToken.isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $bearerToken',
        );
      }

      request.write(
        jsonEncode(data),
      );

      final response =
          await request.close();

      final body =
          await utf8.decoder
              .bind(response)
              .join();

      return _SimpleHttpResponse(
        statusCode: response.statusCode,
        body: body,
      );
    } on SocketException {
      throw StateError(
        'Internet connection nahi mil raha.',
      );
    } finally {
      client.close(force: true);
    }
  }

  static String _firebaseErrorMessage(
    String body, {
    required String fallback,
  }) {
    try {
      final decoded = jsonDecode(body);

      if (decoded is Map) {
        final error = decoded['error'];

        if (error is Map) {
          final message =
              error['message']
                      ?.toString()
                      .trim() ??
                  '';

          if (message.isNotEmpty) {
            switch (message) {
              case 'INVALID_LOGIN_CREDENTIALS':
              case 'INVALID_PASSWORD':
              case 'EMAIL_NOT_FOUND':
                return 'Firebase Admin Email ya Password galat hai.';

              case 'USER_DISABLED':
                return 'Firebase Admin account disabled hai.';

              case 'API_KEY_INVALID':
                return 'Firebase API key invalid hai.';

              default:
                if (message.contains(
                  'PERMISSION_DENIED',
                )) {
                  return 'Firebase login hua, lekin Firestore permission denied hai.';
                }

                return message;
            }
          }

          final status =
              error['status']
                      ?.toString()
                      .trim() ??
                  '';

          if (status.isNotEmpty) {
            if (status ==
                'PERMISSION_DENIED') {
              return 'Firebase login hua, lekin Firestore permission denied hai.';
            }

            return status;
          }
        }
      }
    } catch (_) {}

    return fallback;
  }
}

class _SimpleHttpResponse {
  const _SimpleHttpResponse({
    required this.statusCode,
    required this.body,
  });

  final int statusCode;
  final String body;
}

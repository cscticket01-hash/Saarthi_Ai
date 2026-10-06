import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'windows_secure_storage.dart';

import 'windows_local_settings.dart';
import 'windows_local_firestore.dart';
import 'school_text_data.dart';
import 'school_backend_transport.dart';
import 'platform/platform_config.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_connect/managed_record_media.dart';

class WindowsFirebaseRemoteStatus {
  const WindowsFirebaseRemoteStatus({
    required this.configSaved,
    required this.authenticated,
    required this.projectId,
    required this.email,
    this.schoolId = '',
  });

  final bool configSaved;
  final bool authenticated;
  final String projectId;
  final String email;
  final String schoolId;
  String get schoolIdentity => schoolId.isNotEmpty ? schoolId : projectId;
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

  static FutureOr<void> Function()? onConnectionChanged;

  static Future<void> _notifyConnectionChanged() async {
    final callback = onConnectionChanged;
    if (callback == null) return;
    await callback();
  }

  static const WindowsSecureStorage _secure = WindowsSecureStorage();

  static const String _emailKey = 'vidya_saarthi_firebase_email_v1';

  static const String _refreshTokenKey =
      'vidya_saarthi_firebase_refresh_token_v1';

  static const String _projectIdKey = 'vidya_saarthi_firebase_project_id_v1';

  static Future<WindowsFirebaseRemoteStatus> status() async {
    final central = await CentralSchoolCloud.saved();
    if (central.isNotEmpty)
      return WindowsFirebaseRemoteStatus(
        configSaved: true,
        authenticated: true,
        projectId: platformProjectId,
        email: central['email'],
        schoolId: central['schoolId'],
      );
    final local = await WindowsExternalConnections.load();

    final link = local['firebaseLink']?.toString().trim() ?? '';

    final email = (await _secure.read(key: _emailKey))?.trim() ?? '';

    final refreshToken =
        (await _secure.read(key: _refreshTokenKey))?.trim() ?? '';

    final projectId = (await _secure.read(key: _projectIdKey))?.trim() ?? '';

    return WindowsFirebaseRemoteStatus(
      configSaved: link.isNotEmpty,
      authenticated:
          link.isNotEmpty &&
          email.isNotEmpty &&
          refreshToken.isNotEmpty &&
          projectId.isNotEmpty &&
          projectId != platformProjectId,
      projectId: projectId,
      email: email,
    );
  }

  static Future<WindowsFirebaseConnectResult> connectAndVerify({
    required String firebaseLink,
    required String email,
    required String password,
  }) async {
    final cleanLink = firebaseLink.trim();
    final cleanEmail = email.trim();

    if (cleanEmail.isEmpty) {
      throw StateError('Firebase Admin Email daalein.');
    }

    if (password.isEmpty) {
      throw StateError('Firebase Password daalein.');
    }

    final config = WindowsExternalConnections.decodeFirebaseLink(cleanLink);

    final apiKey = config['apiKey']?.toString().trim() ?? '';

    final projectId = config['projectId']?.toString().trim() ?? '';

    requireSchoolProjectId(projectId);

    if (apiKey.isEmpty || projectId.isEmpty) {
      throw StateError('Firebase config incomplete hai.');
    }

    final auth = await _signIn(
      apiKey: apiKey,
      email: cleanEmail,
      password: password,
    );

    final idToken = auth['idToken']?.toString() ?? '';

    final refreshToken = auth['refreshToken']?.toString() ?? '';

    final verifiedEmail = auth['email']?.toString().trim() ?? cleanEmail;

    if (idToken.isEmpty || refreshToken.isEmpty) {
      throw StateError('Firebase login token nahi mila.');
    }

    await _verifyFirestore(projectId: projectId, idToken: idToken);

    // Save only AFTER Auth + Firestore verification succeed.
    await WindowsExternalConnections.save(firebaseLink: cleanLink);

    await _secure.write(key: _emailKey, value: verifiedEmail);

    await _secure.write(key: _refreshTokenKey, value: refreshToken);

    await _secure.write(key: _projectIdKey, value: projectId);

    await _notifyConnectionChanged();

    return WindowsFirebaseConnectResult(
      projectId: projectId,
      email: verifiedEmail,
    );
  }

  static Future<WindowsFirebaseConnectResult> testSavedConnection() async {
    final central = await CentralSchoolCloud.saved();
    if (central.isNotEmpty) {
      await CentralSchoolCloud.firebaseToken();
      return WindowsFirebaseConnectResult(
        projectId: platformProjectId,
        email: central['email'],
      );
    }
    final local = await WindowsExternalConnections.load();

    final link = local['firebaseLink']?.toString().trim() ?? '';

    if (link.isEmpty) {
      throw StateError('Firebase link saved nahi hai.');
    }

    final config = WindowsExternalConnections.decodeFirebaseLink(link);

    final apiKey = config['apiKey']?.toString().trim() ?? '';

    final projectId = config['projectId']?.toString().trim() ?? '';

    requireSchoolProjectId(projectId);

    final savedProjectId =
        (await _secure.read(key: _projectIdKey))?.trim() ?? '';

    final email = (await _secure.read(key: _emailKey))?.trim() ?? '';

    final refreshToken =
        (await _secure.read(key: _refreshTokenKey))?.trim() ?? '';

    if (refreshToken.isEmpty || email.isEmpty) {
      throw StateError(
        'Firebase authentication saved nahi hai. '
        'Connect & Verify dobara karein.',
      );
    }

    if (savedProjectId.isNotEmpty && savedProjectId != projectId) {
      throw StateError(
        'Saved Firebase authentication dusre project ka hai. '
        'Connect & Verify dobara karein.',
      );
    }

    final refreshed = await _refreshIdToken(
      apiKey: apiKey,
      refreshToken: refreshToken,
    );

    final idToken = refreshed['id_token']?.toString() ?? '';

    final newRefreshToken =
        refreshed['refresh_token']?.toString().trim() ?? refreshToken;

    if (idToken.isEmpty) {
      throw StateError('Firebase session refresh nahi hua.');
    }

    await _verifyFirestore(projectId: projectId, idToken: idToken);

    await _secure.write(key: _refreshTokenKey, value: newRefreshToken);

    await _secure.write(key: _projectIdKey, value: projectId);

    return WindowsFirebaseConnectResult(projectId: projectId, email: email);
  }

  static Future<String> freshIdToken() async {
    if ((await CentralSchoolCloud.saved()).isNotEmpty)
      return CentralSchoolCloud.firebaseToken();
    final local = await WindowsExternalConnections.load();

    final link = local['firebaseLink']?.toString().trim() ?? '';

    if (link.isEmpty) {
      throw StateError('Firebase connected nahi hai.');
    }

    final config = WindowsExternalConnections.decodeFirebaseLink(link);

    requireSchoolProjectId(config['projectId']?.toString().trim() ?? '');

    final apiKey = config['apiKey']?.toString().trim() ?? '';

    final refreshToken =
        (await _secure.read(key: _refreshTokenKey))?.trim() ?? '';

    if (refreshToken.isEmpty) {
      throw StateError('Firebase session saved nahi hai.');
    }

    final refreshed = await _refreshIdToken(
      apiKey: apiKey,
      refreshToken: refreshToken,
    );

    final idToken = refreshed['id_token']?.toString() ?? '';

    final newRefreshToken =
        refreshed['refresh_token']?.toString().trim() ?? refreshToken;

    if (idToken.isEmpty) {
      throw StateError('Firebase session refresh nahi hua.');
    }

    await _secure.write(key: _refreshTokenKey, value: newRefreshToken);

    return idToken;
  }

  static Future<void> disconnect() async {
    if ((await CentralSchoolCloud.saved()).isNotEmpty) {
      await _secure.delete(key: CentralSchoolCloud.key);
      await _notifyConnectionChanged();
      return;
    }
    await _secure.delete(key: _emailKey);
    await _secure.delete(key: _refreshTokenKey);
    await _secure.delete(key: _projectIdKey);

    await WindowsExternalConnections.save(firebaseLink: '');

    await _notifyConnectionChanged();
  }

  static Future<Map<String, dynamic>> _managedRecords(
    String token,
    Map<String, dynamic> body, {
    String? expectedSchoolId,
  }) async {
    final school =
        FirebaseFirestore.instance.activeProfileIdentity['schoolId']
            ?.toString() ??
        '';
    final saved = await CentralSchoolCloud.saved();
    if (!validSchoolId(school) ||
        saved['schoolId'] != school ||
        expectedSchoolId != null && school != expectedSchoolId)
      throw StateError('School changed during sync.');
    final cloud = CentralSchoolCloud(
      endpoint: saved['endpoint'],
      expectedSchoolId: school,
    );
    try {
      return await cloud.api({
        'action': 'managed/records',
        ...body,
        'schoolId': school,
      }, token: token);
    } finally {
      cloud.close();
    }
  }

  static Future<Map<String, Map<String, dynamic>>> readCollection({
    required String projectId,
    required String idToken,
    required String collection,
  }) async {
    if ((await CentralSchoolCloud.saved())['managed'] == true) {
      final result = await _managedRecords(idToken, {
        'operation': 'read',
        'collection': collection,
      });
      return (result['records'] as Map).map(
        (k, v) => MapEntry(
          k.toString(),
          Map<String, dynamic>.from(_restoreManagedValue(v) as Map),
        ),
      );
    }
    final remoteCollection = await _remoteCollection(projectId, collection);
    final output = <String, Map<String, dynamic>>{};

    String? pageToken;

    do {
      final query = <String, String>{
        'pageSize': '500',
        if (pageToken != null && pageToken!.isNotEmpty) 'pageToken': pageToken!,
      };

      final uri = Uri.https(
        'firestore.googleapis.com',
        '/v1/projects/'
            '${Uri.encodeComponent(projectId)}/'
            'databases/(default)/documents/'
            '$remoteCollection',
        query,
      );

      final response = await _request('GET', uri, bearerToken: idToken);

      if (response.statusCode == 404) {
        return output;
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          _firebaseErrorMessage(
            response.body,
            fallback: 'Firestore collection read failed: $collection',
          ),
        );
      }

      if (response.body.trim().isEmpty) {
        break;
      }

      final decoded = jsonDecode(response.body);

      if (decoded is! Map) {
        throw StateError('Firestore collection response invalid hai.');
      }

      final documents = decoded['documents'];

      if (documents is List) {
        for (final raw in documents) {
          if (raw is! Map) continue;

          final document = Map<String, dynamic>.from(raw);

          final name = document['name']?.toString() ?? '';

          if (name.isEmpty) continue;

          final id = Uri.decodeComponent(name.split('/').last);

          final fields = document['fields'];

          output[id] = fields is Map
              ? _decodeFirestoreFields(Map<String, dynamic>.from(fields))
              : <String, dynamic>{};
        }
      }

      pageToken = decoded['nextPageToken']?.toString().trim();

      if (pageToken != null && pageToken!.isEmpty) {
        pageToken = null;
      }
    } while (pageToken != null);

    return output;
  }

  static Future<void> writeDocument({
    required String projectId,
    required String idToken,
    required String collection,
    required String documentId,
    required Map<String, dynamic> data,
    String? expectedRevision,
    num? expectedUploadedAt,
  }) async {
    final origin = FirebaseFirestore.instance.activeProfileId;
    final school =
        FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']
            ?.toString() ??
        '';
    void unchanged() {
      if (FirebaseFirestore.instance.activeProfileId != origin ||
          FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'] !=
              school)
        throw StateError('School changed during sync.');
    }

    final saved = await CentralSchoolCloud.saved();
    unchanged();
    if (saved['managed'] == true) {
      if (saved['schoolId'] != school)
        throw StateError('School identity mismatch.');
      final safe = await prepareManagedRecord(data, school, (action, body) {
        unchanged();
        return ManagedSchoolSession.callForSchool(school, action, body);
      });
      unchanged();
      await _managedRecords(idToken, {
        'operation': 'write',
        'collection': collection,
        'id': documentId,
        'data': migrationJsonValue(safe),
        if (expectedRevision != null) 'expectedRevision': expectedRevision,
        if (expectedUploadedAt != null)
          'expectedUploadedAt': expectedUploadedAt,
      }, expectedSchoolId: school);
      if (collection == 'school_config' &&
          documentId == 'school_profile_cache' &&
          (data['schoolName']?.toString().length ?? 0) >= 2 &&
          (data['principalName']?.toString().length ?? 0) >= 2) {
        unchanged();
        await ManagedSchoolSession.callForSchool(school, 'managed/profile', {
          'operation': 'initialize',
          'schoolName': data['schoolName'],
          'principalName': data['principalName'],
        });
      }
      return;
    }
    final remoteCollection = await _remoteCollection(projectId, collection);
    if (documentId.isEmpty ||
        documentId.contains('/') ||
        documentId == '.' ||
        documentId == '..')
      throw StateError('Invalid school document ID.');
    final documentName =
        'projects/$projectId/'
        'databases/(default)/documents/'
        '$remoteCollection/$documentId';

    final uri = Uri.parse(
      'https://firestore.googleapis.com/v1/'
      'projects/${Uri.encodeComponent(projectId)}/'
      'databases/(default)/documents:commit',
    );

    final response = await _postJson(uri, <String, dynamic>{
      'writes': <Map<String, dynamic>>[
        <String, dynamic>{
          'update': <String, dynamic>{
            'name': documentName,
            'fields': _encodeFirestoreFields(
              projectId == platformProjectId
                  ? centralSchoolData(
                      data,
                      (await CentralSchoolCloud.saved())['schoolId'],
                    )
                  : schoolTextData(data),
            ),
          },
        },
      ],
    }, bearerToken: idToken);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        _firebaseErrorMessage(
          response.body,
          fallback:
              'Firestore document sync failed: '
              '$collection/$documentId',
        ),
      );
    }
  }

  static Future<void> deleteDocument({
    required String projectId,
    required String idToken,
    required String collection,
    required String documentId,
    String? expectedRevision,
    num? expectedUploadedAt,
  }) async {
    if ((await CentralSchoolCloud.saved())['managed'] == true) {
      await _managedRecords(idToken, {
        'operation': 'delete',
        'collection': collection,
        'id': documentId,
        if (expectedRevision != null) 'expectedRevision': expectedRevision,
        if (expectedUploadedAt != null)
          'expectedUploadedAt': expectedUploadedAt,
      });
      return;
    }
    final remoteCollection = await _remoteCollection(projectId, collection);
    if (documentId.isEmpty ||
        documentId.contains('/') ||
        documentId == '.' ||
        documentId == '..')
      throw StateError('Invalid school document ID.');
    final documentName =
        'projects/$projectId/'
        'databases/(default)/documents/'
        '$remoteCollection/$documentId';

    final uri = Uri.parse(
      'https://firestore.googleapis.com/v1/'
      'projects/${Uri.encodeComponent(projectId)}/'
      'databases/(default)/documents:commit',
    );

    final response = await _postJson(uri, <String, dynamic>{
      'writes': <Map<String, dynamic>>[
        <String, dynamic>{'delete': documentName},
      ],
    }, bearerToken: idToken);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        _firebaseErrorMessage(
          response.body,
          fallback:
              'Firestore delete sync failed: '
              '$collection/$documentId',
        ),
      );
    }
  }

  static dynamic _restoreManagedValue(dynamic value) {
    if (value is List) return value.map(_restoreManagedValue).toList();
    if (value is Map) {
      if (value.length == 1 && value['__vsTimestamp'] is String)
        return Timestamp.fromDate(DateTime.parse(value['__vsTimestamp']));
      return value.map(
        (k, v) => MapEntry(k.toString(), _restoreManagedValue(v)),
      );
    }
    return value;
  }

  static Future<String> _remoteCollection(
    String projectId,
    String collection,
  ) async {
    if (projectId == platformProjectId) {
      final central = await CentralSchoolCloud.saved();
      if (central.isEmpty)
        throw StateError('Verified school cloud connection is required.');
      return tenantCollectionPath(central['schoolId'], collection);
    }
    requireSchoolProjectId(projectId);
    if (!RegExp(r'^[a-z][a-z0-9_]{0,79}$').hasMatch(collection))
      throw StateError('Invalid school collection.');
    return collection;
  }

  static Map<String, dynamic> _encodeFirestoreFields(
    Map<String, dynamic> data,
  ) {
    final output = <String, dynamic>{};

    for (final entry in data.entries) {
      output[entry.key] = _encodeFirestoreValue(entry.value);
    }

    return output;
  }

  static Map<String, dynamic> _decodeFirestoreFields(
    Map<String, dynamic> fields,
  ) {
    final output = <String, dynamic>{};

    for (final entry in fields.entries) {
      if (entry.value is Map) {
        output[entry.key] = _decodeFirestoreValue(
          Map<String, dynamic>.from(entry.value as Map),
        );
      }
    }

    return output;
  }

  static Map<String, dynamic> _encodeFirestoreValue(dynamic value) {
    if (value == null) {
      return <String, dynamic>{'nullValue': null};
    }

    if (value is bool) {
      return <String, dynamic>{'booleanValue': value};
    }

    if (value is int) {
      return <String, dynamic>{'integerValue': value.toString()};
    }

    if (value is double) {
      return <String, dynamic>{'doubleValue': value};
    }

    if (value is num) {
      return <String, dynamic>{'doubleValue': value.toDouble()};
    }

    if (value is Timestamp) {
      return <String, dynamic>{
        'timestampValue': value.toDate().toUtc().toIso8601String(),
      };
    }

    if (value is DateTime) {
      return <String, dynamic>{
        'timestampValue': value.toUtc().toIso8601String(),
      };
    }

    if (value is String) {
      return <String, dynamic>{'stringValue': value};
    }

    if (value is Iterable) {
      return <String, dynamic>{
        'arrayValue': <String, dynamic>{
          'values': value.map(_encodeFirestoreValue).toList(),
        },
      };
    }

    if (value is Map) {
      final map = Map<String, dynamic>.from(value);

      return <String, dynamic>{
        'mapValue': <String, dynamic>{'fields': _encodeFirestoreFields(map)},
      };
    }

    return <String, dynamic>{'stringValue': value.toString()};
  }

  static dynamic _decodeFirestoreValue(Map<String, dynamic> value) {
    if (value.containsKey('nullValue')) {
      return null;
    }

    if (value.containsKey('booleanValue')) {
      return value['booleanValue'] == true;
    }

    if (value.containsKey('integerValue')) {
      final raw = value['integerValue']?.toString() ?? '';
      return int.tryParse(raw) ?? 0;
    }

    if (value.containsKey('doubleValue')) {
      final raw = value['doubleValue'];
      if (raw is num) return raw.toDouble();
      return double.tryParse(raw?.toString() ?? '') ?? 0.0;
    }

    if (value.containsKey('timestampValue')) {
      final raw = value['timestampValue']?.toString() ?? '';
      final parsed = DateTime.tryParse(raw);
      return parsed == null ? raw : Timestamp.fromDate(parsed);
    }

    if (value.containsKey('stringValue')) {
      return value['stringValue']?.toString() ?? '';
    }

    if (value.containsKey('bytesValue')) {
      return value['bytesValue']?.toString() ?? '';
    }

    if (value.containsKey('referenceValue')) {
      return value['referenceValue']?.toString() ?? '';
    }

    if (value.containsKey('geoPointValue')) {
      final raw = value['geoPointValue'];
      return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    }

    if (value.containsKey('arrayValue')) {
      final raw = value['arrayValue'];

      if (raw is Map) {
        final values = raw['values'];

        if (values is List) {
          return values
              .whereType<Map>()
              .map(
                (item) =>
                    _decodeFirestoreValue(Map<String, dynamic>.from(item)),
              )
              .toList();
        }
      }

      return <dynamic>[];
    }

    if (value.containsKey('mapValue')) {
      final raw = value['mapValue'];

      if (raw is Map && raw['fields'] is Map) {
        return _decodeFirestoreFields(
          Map<String, dynamic>.from(raw['fields'] as Map),
        );
      }

      return <String, dynamic>{};
    }

    return null;
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

    final response = await _postJson(uri, <String, dynamic>{
      'email': email,
      'password': password,
      'returnSecureToken': true,
    });

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        _firebaseErrorMessage(
          response.body,
          fallback: 'Firebase Admin login failed.',
        ),
      );
    }

    final decoded = jsonDecode(response.body);

    if (decoded is! Map) {
      throw StateError('Firebase login response invalid hai.');
    }

    return Map<String, dynamic>.from(decoded);
  }

  static Future<Map<String, dynamic>> _refreshIdToken({
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
      final request = await client.postUrl(uri);

      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/x-www-form-urlencoded',
      );

      final body =
          'grant_type=refresh_token'
          '&refresh_token=${Uri.encodeQueryComponent(refreshToken)}';

      request.write(body);

      final response = await request.close();

      final responseBody = await utf8.decoder.bind(response).join();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          _firebaseErrorMessage(
            responseBody,
            fallback: 'Firebase session refresh failed.',
          ),
        );
      }

      final decoded = jsonDecode(responseBody);

      if (decoded is! Map) {
        throw StateError('Firebase token response invalid hai.');
      }

      return Map<String, dynamic>.from(decoded);
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _verifyFirestore({
    required String projectId,
    required String idToken,
  }) async {
    requireSchoolProjectId(projectId);
    final uri = Uri.parse(
      'https://firestore.googleapis.com/v1/'
      'projects/${Uri.encodeComponent(projectId)}/'
      'databases/(default)/documents:runQuery',
    );

    final response = await _postJson(uri, <String, dynamic>{
      'structuredQuery': <String, dynamic>{
        'from': <Map<String, dynamic>>[
          <String, dynamic>{'collectionId': 'school_config'},
        ],
        'limit': 1,
      },
    }, bearerToken: idToken);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        _firebaseErrorMessage(
          response.body,
          fallback: 'Firestore access verify nahi hua.',
        ),
      );
    }
  }

  static Future<_SimpleHttpResponse> _request(
    String method,
    Uri uri, {
    String? bearerToken,
    Map<String, String>? headers,
    String? body,
  }) async {
    final client = HttpClient();

    try {
      final request = await client.openUrl(method, uri);

      if (bearerToken != null && bearerToken.isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $bearerToken',
        );
      }

      if (headers != null) {
        for (final entry in headers.entries) {
          request.headers.set(entry.key, entry.value);
        }
      }

      if (body != null) {
        request.write(body);
      }

      final response = await request.close();

      final responseBody = await utf8.decoder.bind(response).join();

      return _SimpleHttpResponse(
        statusCode: response.statusCode,
        body: responseBody,
      );
    } on SocketException {
      throw StateError('Internet connection nahi mil raha.');
    } finally {
      client.close(force: true);
    }
  }

  static Future<_SimpleHttpResponse> _postJson(
    Uri uri,
    Map<String, dynamic> data, {
    String? bearerToken,
  }) async {
    final client = HttpClient();

    try {
      final request = await client.postUrl(uri);

      request.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );

      if (bearerToken != null && bearerToken.isNotEmpty) {
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer $bearerToken',
        );
      }

      request.write(jsonEncode(data));

      final response = await request.close();

      final body = await utf8.decoder.bind(response).join();

      return _SimpleHttpResponse(statusCode: response.statusCode, body: body);
    } on SocketException {
      throw StateError('Internet connection nahi mil raha.');
    } finally {
      client.close(force: true);
    }
  }

  static String _firebaseErrorMessage(String body, {required String fallback}) {
    try {
      final decoded = jsonDecode(body);

      if (decoded is Map) {
        final error = decoded['error'];

        if (error is Map) {
          final message = error['message']?.toString().trim() ?? '';

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
                if (message.contains('PERMISSION_DENIED')) {
                  return 'Firebase login hua, lekin Firestore permission denied hai.';
                }

                return message;
            }
          }

          final status = error['status']?.toString().trim() ?? '';

          if (status.isNotEmpty) {
            if (status == 'PERMISSION_DENIED') {
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
  const _SimpleHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

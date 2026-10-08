import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import '../windows_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../school_backend_transport.dart';
import 'google_authorization.dart';

class SetupActionRequired implements Exception {
  const SetupActionRequired(this.message, this.url);
  final String message;
  final Uri url;
  @override
  String toString() => message;
}

class SetupApiError implements Exception {
  const SetupApiError(this.status, this.service, {this.reason = '',
    this.consumerProject = '', this.permission = '', this.method = '', this.operation = '',
    this.quotaMetric = '', this.quotaLimit = '', this.quotaLimitValue = ''});
  final int status;
  final String service, reason, consumerProject, permission, method, operation, quotaMetric, quotaLimit, quotaLimitValue;
  static const reasons = {'SERVICE_DISABLED', 'ACCESS_TOKEN_SCOPE_INSUFFICIENT',
    'IAM_PERMISSION_DENIED', 'PERMISSION_DENIED', 'RESOURCE_EXHAUSTED',
    'QUOTA_EXCEEDED', 'RATE_LIMIT_EXCEEDED', 'BILLING_DISABLED', 'FIREBASE_TERMS_REQUIRED'};
  factory SetupApiError.fromGoogle(int status, String service, Object? body, {String method = '', String operation = ''}) {
    var reason = '', consumer = '', permission = '', metric = '', limit = '', limitValue = '';
    try {
      final value = body is String ? jsonDecode(body) : body;
      final error = value is Map ? value['error'] : null;
      // Classify explicit terms failures without returning Google's raw text.
      final message = error is Map ? error['message'] : null;
      if (service == 'firebase.googleapis.com' && message is String && message.length <= 4096 &&
          RegExp(r'(?:firebase.{0,30}(?:terms|tos).{0,80}(?:not.{0,20}accept|must.{0,20}accept|required)|(?:accept|agree).{0,40}firebase.{0,40}(?:terms|tos))', caseSensitive: false).hasMatch(message)) {
        reason = 'FIREBASE_TERMS_REQUIRED';
      }
      for (final detail in error is Map && error['details'] is List ? error['details'] : []) {
        if (detail is! Map || detail['@type'] != 'type.googleapis.com/google.rpc.ErrorInfo' ||
            !{'googleapis.com', ...GoogleSetupApi.hosts}.contains(detail['domain'])) continue;
        if (reason.isEmpty && reasons.contains(detail['reason'])) reason = detail['reason'];
        final metadata = detail['metadata'];
        if (metadata is Map) {
          // Only structured, bounded quota identifiers are retained. Raw error
          // messages and QuotaFailure descriptions may contain private data.
          final candidateMetric = metadata['quota_metric'];
          if (candidateMetric is String && candidateMetric.length <= 180 &&
              RegExp(r'^[a-z]+[a-z0-9]*\.googleapis\.com/[a-zA-Z0-9_./-]+$').hasMatch(candidateMetric) &&
              GoogleSetupApi.hosts.contains(candidateMetric.split('/').first)) metric = candidateMetric;
          final candidateLimit = metadata['quota_limit'];
          if (candidateLimit is String && RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]{0,99}$').hasMatch(candidateLimit)) limit = candidateLimit;
          final candidateValue = metadata['quota_limit_value'];
          if (candidateValue is String && RegExp(r'^[0-9]{1,20}$').hasMatch(candidateValue)) limitValue = candidateValue;
          final project = metadata['consumer'];
          if (project is String && RegExp(r'^projects/[0-9]{1,30}$').hasMatch(project)) consumer = project;
          final candidate = metadata['permission'];
          if (candidate is String && {'resourcemanager.projects.get',
            'resourcemanager.projects.create', 'serviceusage.services.enable', 'serviceusage.services.get',
            'firebase.projects.update', 'firebase.clients.create'}.contains(candidate)) permission = candidate;
        }
      }
    } catch (_) {}
    return SetupApiError(status, service, reason: reason, consumerProject: consumer,
      quotaMetric: metric, quotaLimit: limit, quotaLimitValue: limitValue,
      permission: permission, method: {'GET', 'POST', 'PATCH', 'PUT'}.contains(method) ? method : '',
      operation: {'addFirebase', 'registerWebApp', 'enableServices', 'verifyPermissions', 'createProject', 'createFirestore', 'pollOperation'}.contains(operation) ? operation : '');
  }
  @override
  String toString() {
    if (status == 401) return 'Google permission expired. Sign in again to continue.';
    if (reason == 'FIREBASE_TERMS_REQUIRED') return 'Google requires this school Google account to accept Firebase Terms of Service once. Google offers no API to accept these terms. Automatic activation cannot continue until the account has accepted them; the saved school project is retained.';
    if (reason == 'SERVICE_DISABLED') {
      return 'Google API $service is disabled${consumerProject.isEmpty ? '' : ' in $consumerProject'}. The owner of that Google project must enable this API, then retry. If this is the developer OAuth project, contact the developer; creating a school Firebase project manually is not required.';
    }
    if (reason == 'ACCESS_TOKEN_SCOPE_INSUFFICIENT') return 'Google did not grant all required cloud permissions. Reconnect with the same school account and allow the requested permissions.';
    if ({'RESOURCE_EXHAUSTED', 'QUOTA_EXCEEDED', 'RATE_LIMIT_EXCEEDED'}.contains(reason) || status == 429) {
      final details = ['$service / ${operation.isEmpty ? method : operation}', 'HTTP $status',
        if (reason.isNotEmpty) reason, if (consumerProject.isNotEmpty) 'consumer=$consumerProject',
        if (quotaMetric.isNotEmpty) 'metric=$quotaMetric', if (quotaLimit.isNotEmpty) 'limit=$quotaLimit',
        if (quotaLimitValue.isNotEmpty) 'limit value=$quotaLimitValue'].join('; ');
      final guidance = quotaMetric == 'cloudresourcemanager.googleapis.com/projects_count'
        ? 'Google project-count capacity is exhausted; waiting alone will not increase this limit.'
        : reason == 'RATE_LIMIT_EXCEEDED'
          ? 'Google reports an API rate limit; wait before retrying.'
          : 'Google did not identify a project-count limit; this may be an API or resource quota.';
      return 'Google quota exhausted: $details. $guidance ${quotaMetric.isEmpty && quotaLimit.isEmpty ? 'Exact quota identifier was not supplied by Google. ' : ''}Retry the same saved school setup; do not create or delete school projects to bypass the limit.';
    }
    if (reason == 'BILLING_DISABLED') return 'Google requires billing for this operation. Automatic setup stopped; no paid plan or billing account was enabled.';
    if (status == 403) return 'Google denied ${operation.isEmpty ? method : operation} access to $service${permission.isEmpty ? '' : ' ($permission)'}. Check this school project’s permissions and account/service restrictions, then retry. Existing school data is unchanged.';
    return '$service could not finish (HTTP $status). Check account permissions, service availability and project quota, then retry.';
  }
}

class SetupOperationError extends SetupApiError {
  SetupOperationError(SetupApiError error) : super(error.status, error.service,
    reason: error.reason, consumerProject: error.consumerProject,
    permission: error.permission, method: error.method, operation: error.operation,
    quotaMetric: error.quotaMetric, quotaLimit: error.quotaLimit, quotaLimitValue: error.quotaLimitValue);
}

class FirebaseActivationDenied implements Exception {
  const FirebaseActivationDenied(this.error);
  final SetupApiError error;
  @override
  String toString() => error.reason == 'FIREBASE_TERMS_REQUIRED' ? error.toString()
    : 'Google denied Firebase activation (addFirebase) although the four required project IAM permissions were verified. Firebase Terms acceptance or another Firebase account/policy restriction may be blocking this account. Terms acceptance cannot be performed through Google OAuth or REST APIs. The same school project is saved; no new project, IAM change or billing upgrade was made.';
}

Future<void> schoolSetupDelay(Duration duration) => Future<void>.delayed(duration);

class GoogleSetupApi {
  GoogleSetupApi(this.token, {http.Client? client}) : client = client ?? http.Client();
  final String token;
  final http.Client client;
  static const hosts = {'cloudresourcemanager.googleapis.com', 'firebase.googleapis.com',
    'serviceusage.googleapis.com', 'firestore.googleapis.com', 'firebaserules.googleapis.com',
    'identitytoolkit.googleapis.com', 'script.googleapis.com'};
  bool cancelled = false;
  void check() { if (cancelled) throw SetupCancelled(); }
  Future<Map<String, dynamic>?> request(String method, String url,
      {Map<String, dynamic>? body, bool allowMissing = false}) async {
    check();
    final uri = Uri.parse(url);
    if (uri.scheme != 'https' || !hosts.contains(uri.host) || uri.userInfo.isNotEmpty) {
      throw StateError('Untrusted Google API endpoint blocked.');
    }
    final request = http.Request(method, uri)..followRedirects = false;
    request.headers.addAll({'Authorization': 'Bearer $token', 'Content-Type': 'application/json'});
    if (body != null) request.body = jsonEncode(body);
    late http.Response response;
    try {
      response = await http.Response.fromStream(await client.send(request)
        .timeout(const Duration(seconds: 45))).timeout(const Duration(seconds: 45));
    } catch (_) {
      // Closing an in-flight client can fail before a response arrives.
      // Treat that as cancellation so the wizard offers a fresh login on retry.
      check();
      rethrow;
    }
    check();
    if (allowMissing && response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Never put Google error bodies, OAuth credentials or password requests in UI/logs.
      throw SetupApiError.fromGoogle(response.statusCode, uri.host, response.body, method: method, operation:
        uri.host == 'firebase.googleapis.com' && uri.path.endsWith(':addFirebase') ? 'addFirebase'
        : uri.host == 'firebase.googleapis.com' && method == 'POST' && uri.path.endsWith('/webApps') ? 'registerWebApp'
        : uri.path.endsWith(':batchEnable') ? 'enableServices'
        : uri.path.endsWith(':testIamPermissions') ? 'verifyPermissions'
        : uri.host == 'cloudresourcemanager.googleapis.com' && method == 'POST' && uri.path.endsWith('/projects') ? 'createProject'
        : uri.host == 'firestore.googleapis.com' && method == 'POST' && uri.path.endsWith('/databases') ? 'createFirestore'
        : uri.path.contains('/operations/') ? 'pollOperation' : '');
    }
    if (response.body.trim().isEmpty) return {};
    try {
      final data = jsonDecode(response.body);
      if (data is Map) return Map<String, dynamic>.from(data);
    } catch (_) {}
    throw StateError('Unexpected Google setup response. Please retry.');
  }
  Future<Map<String, dynamic>> waitOperation(String host, Map<String, dynamic> operation, {String operationLabel = 'pollOperation'}) async {
    var op = operation;
    for (var attempt = 0; attempt < 90; attempt++) {
      check();
      if (op['done'] == true) {
        if (op['error'] != null) {
          final error = op['error'];
          final code = error is Map ? error['code'] : null;
          final status = {3: 400, 5: 404, 6: 409, 7: 403, 8: 429, 16: 401}[code] ?? 500;
          throw SetupOperationError(SetupApiError.fromGoogle(status, host, {'error': error}, operation: operationLabel));
        }
        return Map<String, dynamic>.from(op['response'] as Map? ?? {});
      }
      final name = op['name']?.toString() ?? '';
      if (!RegExp(r'^[a-zA-Z0-9_./():-]+$').hasMatch(name) || name.contains('..') || name.contains('://')) {
        throw StateError('Invalid Google operation identifier.');
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      op = (await request('GET', 'https://$host/$name'))!;
    }
    throw TimeoutException('Google setup is still processing. Use Continue to resume.');
  }
  void close() { cancelled = true; client.close(); }
}

abstract class SetupCheckpoint {
  Future<Map<String, dynamic>> read();
  Future<void> write(Map<String, dynamic> value);
}
class SecureSetupCheckpoint implements SetupCheckpoint {
  static const key = 'vidya_saarthi_windows_easy_connect_v1';
  final WindowsSecureStorage storage = const WindowsSecureStorage();
  @override
  Future<Map<String, dynamic>> read() async {
    final raw = await storage.read(key: key);
    if (raw == null) return {};
    final value = jsonDecode(raw);
    if (value is! Map) throw StateError('Saved setup is invalid. Contact the developer; existing connections were not changed.');
    return Map<String, dynamic>.from(value);
  }
  @override
  Future<void> write(Map<String, dynamic> value) => storage.write(key: key, value: jsonEncode(value));
}

class SchoolProvisioner {
  SchoolProvisioner({required this.api, required this.account, required this.checkpoint,
    required this.progress, required this.bundle, this.delay = schoolSetupDelay});
  final Future<void> Function(Duration) delay;
  final GoogleSetupApi api;
  final GoogleSetupAccount account;
  final SetupCheckpoint checkpoint;
  final void Function(String) progress;
  final Map<String, dynamic> bundle;
  Map<String, dynamic> data = {};
  String get project => data['projectId'] as String;
  String get number => data['projectNumber'].toString();
  Future<void> save() async { api.check(); await checkpoint.write(data); }

  Future<void> begin({required String schoolName, required String location}) async {
    data = await checkpoint.read();
    if (data.isNotEmpty) {
      if (data['accountSub'] != account.subject) throw StateError('Use the same school Google account that started this setup. No resources were changed.');
      requireSchoolProjectId(project);
      return;
    }
    if (!{'asia-south1', 'asia-south2'}.contains(location)) throw StateError('Select a supported India database location.');
    if (schoolName.trim().length < 2) throw StateError('School name is required.');
    final nonce = secureSetupToken(12).toLowerCase().replaceAll(RegExp('[^a-z0-9]'), 'a');
    data = {'accountSub': account.subject, 'email': account.email, 'schoolName': schoolName.trim(),
      'location': location, 'nonce': nonce, 'projectId': 'vs-school-$nonce'};
    await save();
  }

  Future<Map<String, dynamic>> ensureProject() async {
    if (!const bool.fromEnvironment('SAARTHI_LEGACY_PROVISIONING_TEST_ONLY')) throw StateError('Per-school project provisioning is disabled.');
    requireSchoolProjectId(project);
    const host = 'cloudresourcemanager.googleapis.com';
    final url = 'https://$host/v1/projects/$project';
    Map<String, dynamic>? cloud;
    if (data['projectNumber'] != null) {
      // Previously verified ownership: never turn lost access into a new project.
      cloud = await api.request('GET', url);
    } else if (data['projectCreateOperation'] == null) {
      // A get of a not-yet-created project can deny access instead of returning
      // 404. Search only the caller's accessible projects before creation.
      final matches = await _pages(Uri.https(host, '/v1/projects',
        {'filter': 'id:$project'}).toString(), 'projects');
      final exact = matches.where((p) => p['projectId'] == project).toList();
      if (exact.length > 1) throw StateError('Google returned conflicting school projects. Setup stopped.');
      if (exact.isNotEmpty) cloud = exact.single;
      if (cloud == null) {
        progress('Creating your school’s Google project');
        // Keep the same ID on retries. Google rejects duplicate IDs, and only
        // this checkpoint's ownership marker may ever be adopted.
        try {
          final op = (await api.request('POST', 'https://$host/v1/projects', body: {
            'projectId': project, 'name': 'Vidya Saarthi School', 'labels': {'vs-setup': data['nonce']},
          }))!;
          final name = op['name'];
          if (name is! String || !RegExp(r'^operations/[a-zA-Z0-9_./():-]+$').hasMatch(name) || name.contains('..')) {
            throw StateError('Google did not return a valid project creation operation. Retry the same school setup.');
          }
          data['projectCreateOperation'] = name;
          await save();
          cloud = await _waitProjectOperation({...op, 'name': 'v1/$name'});
        } on SetupApiError catch (e) {
          if (e.status != 409) rethrow;
          // A previous interrupted request or a collision may already occupy
          // this ID. Read it and validate the marker; never replace/relabel it.
          cloud = await api.request('GET', url);
        }
      }
    }
    if (cloud == null) {
      final name = data['projectCreateOperation'];
      if (name is! String || !RegExp(r'^operations/[a-zA-Z0-9_./():-]+$').hasMatch(name) || name.contains('..')) {
        throw StateError('Saved Google operation is invalid. Existing projects were not changed.');
      }
      cloud = await _waitProjectOperation({'name': 'v1/$name'});
    }
    // Some operations omit the resource in their response. Read it only after
    // creation has completed, never poll a nonexistent project for permission.
    if (cloud['projectId'] == null) cloud = await api.request('GET', url);
    if (cloud == null || (cloud['projectId'] != null && cloud['projectId'] != project) ||
        cloud['labels']?['vs-setup'] != data['nonce'] || cloud['lifecycleState'] != 'ACTIVE' ||
        !RegExp(r'^[0-9]+$').hasMatch(cloud['projectNumber']?.toString() ?? '')) {
      throw StateError('School project ownership marker is missing or creation is still pending. Retry with the same school Google account.');
    }
    data['projectNumber'] = cloud['projectNumber'].toString();
    data.remove('projectCreateOperation');
    await save();
    return cloud;
  }

  Future<Map<String, dynamic>> _waitProjectOperation(Map<String, dynamic> op) async {
    try {
      return await api.waitOperation('cloudresourcemanager.googleapis.com', op, operationLabel: 'createProject');
    } on SetupOperationError {
      // A terminal operation error is safe to retry with the SAME project ID.
      // Timeouts, cancellation and temporary polling permission errors retain it.
      data.remove('projectCreateOperation');
      await save();
      rethrow;
    } on SetupApiError catch (error) {
      if (error.status != 404) rethrow;
      // Google deletes old operation records. Recover by ownership-checked read.
      data.remove('projectCreateOperation');
      await save();
      return (await api.request('GET',
        'https://cloudresourcemanager.googleapis.com/v1/projects/$project',
        allowMissing: true)) ?? {};
    }
  }

  Future<Map<String, dynamic>> firebase() async {
    if (!const bool.fromEnvironment('SAARTHI_LEGACY_PROVISIONING_TEST_ONLY')) throw StateError('Per-school Firebase provisioning is disabled. Use Connect School Cloud. Existing school projects were retained.');
    await ensureProject();
    if (data['servicesReady'] != true) {
      await verifyFirebasePermissions();
      if (data['firebaseServicesEnabled'] != true) {
        progress('Enabling school Firebase services');
        final op = await api.request('POST', 'https://serviceusage.googleapis.com/v1/projects/$number/services:batchEnable', body: {
          'serviceIds': ['firebase.googleapis.com', 'firestore.googleapis.com', 'firebaserules.googleapis.com',
            'identitytoolkit.googleapis.com', 'fcm.googleapis.com'],
        });
        await api.waitOperation('serviceusage.googleapis.com', {...op!, if (op['name'] != null) 'name': 'v1/${op['name']}'}, operationLabel: 'enableServices');
        data['firebaseServicesEnabled'] = true;
        await save();
      }
      await activateFirebase();
      data['servicesReady'] = true;
      await save();
    }
    progress('Preparing private school database');
    final dbUrl = 'https://firestore.googleapis.com/v1/projects/$project/databases/(default)';
    if (await api.request('GET', dbUrl, allowMissing: true) == null) {
      final op = await api.request('POST', 'https://firestore.googleapis.com/v1/projects/$project/databases?databaseId=(default)', body: {
        'locationId': data['location'], 'type': 'FIRESTORE_NATIVE', 'deleteProtectionState': 'DELETE_PROTECTION_ENABLED',
      });
      await api.waitOperation('firestore.googleapis.com', {...op!, 'name': 'v1/${op['name']}'}, operationLabel: 'createFirestore');
    }
    if (data['rulesReady'] != true) {
      progress('Applying school-only access rules');
      final releaseUrl = 'https://firebaserules.googleapis.com/v1/projects/$project/releases/cloud.firestore';
      final release = await api.request('GET', releaseUrl, allowMissing: true);
      if (release != null && release['rulesetName'] != data['rulesetName']) {
        throw StateError('This project already has different database rules. Automatic replacement is blocked.');
      }
      if (data['rulesetName'] == null) {
        final rules = await api.request('POST', 'https://firebaserules.googleapis.com/v1/projects/$project/rulesets', body: {
          'source': {'files': [{'name': 'firestore.rules', 'content': bundle['rules']}]},
        });
        data['rulesetName'] = rules!['name']; await save();
      }
      if (release == null) await api.request('POST', 'https://firebaserules.googleapis.com/v1/projects/$project/releases', body: {
        'name': 'projects/$project/releases/cloud.firestore', 'rulesetName': data['rulesetName'],
      });
      data['rulesReady'] = true; await save();
    }
    final authUrl = 'https://identitytoolkit.googleapis.com/v2/projects/$project/config';
    if (await api.request('GET', authUrl, allowMissing: true) == null) {
      // initializeAuth is billing-only. Never upgrade a free school or attach billing.
      throw SetupActionRequired('Google needs one initial approval: open Firebase Authentication, click Get started, then return here and Continue.',
        Uri.parse('https://console.firebase.google.com/project/$project/authentication'));
    }
    await api.request('PATCH', '$authUrl?updateMask=signIn.email', body: {
      'signIn': {'email': {'enabled': true, 'passwordRequired': true}},
    });
    if (data['webAppId'] == null) {
      progress('Registering the school connection');
      final apps = (await _pages('https://firebase.googleapis.com/v1beta1/projects/$project/webApps', 'apps'))
          .where((a) => a['displayName'] == 'Vidya Saarthi ${data['nonce']}');
      if (apps.isNotEmpty) {
        data['webAppId'] = apps.first['appId'];
      } else {
        final op = await api.request('POST', 'https://firebase.googleapis.com/v1beta1/projects/$project/webApps', body: {'displayName': 'Vidya Saarthi ${data['nonce']}'});
        final app = await api.waitOperation('firebase.googleapis.com', {...op!, 'name': 'v1beta1/${op['name']}'}, operationLabel: 'registerWebApp');
        data['webAppId'] = app['appId'];
      }
      await save();
    }
    final config = await api.request('GET', 'https://firebase.googleapis.com/v1beta1/projects/$project/webApps/${Uri.encodeComponent(data['webAppId'])}/config');
    if (config!['projectId'] != project) throw StateError('School Firebase configuration mismatch.');
    data['firebaseConfig'] = config; await save();
    return config;
  }

  static const firebasePermissions = ['firebase.projects.update', 'resourcemanager.projects.get',
    'serviceusage.services.enable', 'serviceusage.services.get'];

  Future<void> verifyFirebasePermissions() async {
    progress('Checking school Firebase activation permissions');
    var missing = <String>[];
    for (var attempt = 0; attempt < 4; attempt++) {
      final result = (await api.request('POST',
        'https://cloudresourcemanager.googleapis.com/v1/projects/$project:testIamPermissions',
        body: {'permissions': firebasePermissions}))!;
      final granted = (result['permissions'] as List? ?? []).toSet();
      missing = firebasePermissions.where((permission) => !granted.contains(permission)).toList();
      if (missing.isEmpty) return;
      // New owner permissions can take time to propagate. Never self-grant IAM.
      if (attempt < 3) {
        progress('Waiting for school project permissions to become available');
        await delay(Duration(seconds: 2 << attempt));
        api.check();
      }
    }
    throw StateError('Firebase activation is blocked because this school account is missing: ${missing.join(', ')}. Newly created project permissions may still be propagating; retry the same setup. No IAM roles, school data or billing settings were changed.');
  }

  Future<void> activateFirebase() async {
    if (!const bool.fromEnvironment('SAARTHI_LEGACY_PROVISIONING_TEST_ONLY')) throw StateError('Per-school Firebase activation is disabled.');
    final url = 'https://firebase.googleapis.com/v1beta1/projects/$project';
    var existing = await api.request('GET', url, allowMissing: true);
    if (existing != null) {
      data.remove('firebaseAddOperation');
      await save();
      return;
    }
    progress('Activating Firebase for your school');
    Map<String, dynamic> operation;
    final saved = data['firebaseAddOperation'];
    if (saved != null) {
      if (saved is! String || !RegExp(r'^operations/[a-zA-Z0-9_./():-]+$').hasMatch(saved) || saved.contains('..')) {
        throw StateError('Saved Firebase activation operation is invalid. Existing resources were not changed.');
      }
      operation = {'name': 'v1beta1/$saved'};
    } else {
      operation = {};
      for (var attempt = 0; attempt < 4; attempt++) {
        try {
          operation = (await api.request('POST', '$url:addFirebase', body: {}))!;
          break;
        } on SetupApiError catch (error) {
          if (error.status != 403 || !{'', 'PERMISSION_DENIED', 'IAM_PERMISSION_DENIED', 'FIREBASE_TERMS_REQUIRED'}.contains(error.reason)) rethrow;
          if (error.reason == 'FIREBASE_TERMS_REQUIRED' || attempt == 3) throw FirebaseActivationDenied(error);
          // Firebase permission caches can lag behind project IAM. Retry only
          // rejected activation on this marked school, never a different project.
          progress('Waiting for Firebase activation permission to propagate');
          await delay(Duration(seconds: 2 << attempt));
          api.check();
          existing = await api.request('GET', url, allowMissing: true);
          if (existing != null) return;
        }
      }
      final name = operation['name'];
      if (name is! String || !RegExp(r'^operations/[a-zA-Z0-9_./():-]+$').hasMatch(name) || name.contains('..')) {
        throw StateError('Google did not return a valid Firebase activation operation. Retry the same saved school project.');
      }
      data['firebaseAddOperation'] = name;
      await save();
      operation = {...operation, 'name': 'v1beta1/$name'};
    }
    try {
      final activated = await api.waitOperation('firebase.googleapis.com', operation, operationLabel: 'addFirebase');
      if (activated['projectId'] != null && activated['projectId'] != project) {
        throw StateError('Firebase activation returned a different school project. Automatic connection stopped.');
      }
    } on SetupOperationError catch (error) {
      data.remove('firebaseAddOperation');
      await save();
      if (error.status == 403 && {'', 'PERMISSION_DENIED', 'IAM_PERMISSION_DENIED', 'FIREBASE_TERMS_REQUIRED'}.contains(error.reason)) throw FirebaseActivationDenied(error);
      rethrow;
    } on SetupApiError catch (error) {
      if (error.status != 404) rethrow;
      // Firebase automatically deletes completed operation records. Recover by
      // checking the existing school, without sending another activation POST.
      existing = await api.request('GET', url, allowMissing: true);
      if (existing == null) {
        data.remove('firebaseAddOperation');
        await save();
        throw StateError('Firebase activation status is not available yet. Retry the same saved school project.');
      }
    }
    data.remove('firebaseAddOperation');
    await save();
  }

  Future<List<Map<String, dynamic>>> _pages(String url, String field) async {
    final values = <Map<String, dynamic>>[];
    final seen = <String>{};
    String? page;
    do {
      final base = Uri.parse(url);
      final target = base.replace(queryParameters: {
        ...base.queryParameters,
        if (page != null) 'pageToken': page,
      });
      final response = (await api.request('GET', target.toString()))!;
      values.addAll((response[field] as List? ?? []).map((e) => Map<String, dynamic>.from(e)));
      page = response['nextPageToken']?.toString();
      if (page != null && page.isNotEmpty && !seen.add(page)) {
        throw StateError('Google returned a repeated page. Retry without creating duplicate resources.');
      }
    } while (page != null && page.isNotEmpty);
    return values;
  }

  Future<String> adminPassword() async {
    await ensureProject();
    if (data['firebaseConfig']?['projectId'] != project) {
      throw StateError('School administrator configuration mismatch.');
    }
    // Random, per-school device credential. Google password is never requested.
    data['adminPassword'] ??= secureSetupToken(36);
    data['adminUid'] ??= 'vs-${data['nonce']}';
    await save();
    final password = data['adminPassword'] as String;
    final key = Uri.encodeQueryComponent(data['firebaseConfig']['apiKey']);
    final userUrl = 'https://identitytoolkit.googleapis.com/v1/projects/$project/accounts';
    final lookup = await api.request('POST', '$userUrl:lookup', body: {'localId': [data['adminUid']]});
    final users = lookup!['users'] as List? ?? [];
    if (users.isEmpty) {
      final created = await api.request('POST', 'https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$key', body: {
        'targetProjectId': project, 'localId': data['adminUid'], 'email': account.email,
        'emailVerified': true, 'password': password, 'displayName': 'School administrator',
      });
      if (created?['localId'] != data['adminUid']) {
        throw StateError('Google returned a different administrator identity. Setup stopped.');
      }
    } else if (users.length != 1 || users.single['localId'] != data['adminUid'] ||
        users.single['email'] != account.email || users.single['disabled'] == true) {
      throw StateError('School administrator identity changed. Automatic overwrite blocked.');
    }
    final claims = users.isEmpty ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(users.single['customAttributes']?.toString() ?? '{}'));
    await api.request('POST', '$userUrl:update', body: {
      'localId': data['adminUid'], 'customAttributes': jsonEncode({...claims, 'admin': true})});
    return password;
  }

  Future<void> firebaseConnected() async {
    data['firebaseConnected'] = true;
    // Keep the per-school generated password only in encrypted storage for
    // interrupted sign-in recovery. App reset clears this checkpoint too.
    await save();
  }

  Future<Uri> prepareScript() async {
    await ensureProject();
    if (data['firebaseConnected'] != true) throw StateError('Connect Firebase first so Google Drive is paired with the same school.');
    progress('Preparing your school’s Google Drive backend');
    if (data['scriptId'] == null) {
      if (data['scriptCreatePending'] == true) throw SetupActionRequired(
        'Google may have created the script before the connection stopped. Ask the developer to recover this setup; a duplicate script will not be created.',
        Uri.parse('https://script.google.com/home'));
      data['scriptCreatePending'] = true; await save();
      try {
        final created = await api.request('POST', 'https://script.googleapis.com/v1/projects', body: {'title': 'Vidya Saarthi ${data['nonce']}'});
        data['scriptId'] = created!['scriptId']; data.remove('scriptCreatePending'); await save();
      } on SetupApiError catch (e) {
        if (e.status == 403) {
          data.remove('scriptCreatePending'); await save();
          throw SetupActionRequired('Allow Google Apps Script API access in Google settings, then return and Continue. If access is already enabled, ask the developer to check OAuth/API configuration.',
            Uri.parse('https://script.google.com/home/usersettings'));
        }
        rethrow;
      }
    }
    final id = Uri.encodeComponent(data['scriptId']);
    if (data['scriptUploaded'] != true) {
      final files = (bundle['files'] as List).map((f) => Map<String, dynamic>.from(f)).toList();
      files.add({'name': 'SaarthiEasySetup', 'type': 'SERVER_JS', 'source':
        'function VS_easyConnectSetup() {\n'
        '  VS_setupSchool(${jsonEncode(project)}, ${jsonEncode(data['firebaseConfig']['apiKey'])});\n'
        '  VS_prepareSchoolStorage({startEmpty:true});\n'
        '  return {projectId:VS_project(),ready:true};\n}\n'});
      await api.request('PUT', 'https://script.googleapis.com/v1/projects/$id/content', body: {'files': files});
      data['scriptUploaded'] = true; await save();
    }
    return Uri.parse('https://script.google.com/home/projects/$id/edit');
  }

  Future<String> deployScript() async {
    final id = Uri.encodeComponent(data['scriptId']);
    progress('Finding the school web connection');
    final deployments = await _pages('https://script.googleapis.com/v1/projects/$id/deployments', 'deployments');
    // This script was created by this checkpoint; accept an explicitly approved
    // manual deployment too, without creating duplicate deployments on retries.
    final existing = deployments.where((d) =>
      (d['entryPoints'] as List? ?? []).any((e) => e['entryPointType'] == 'WEB_APP' &&
        e['webApp']?['entryPointConfig']?['executeAs'] == 'USER_DEPLOYING' &&
        e['webApp']?['entryPointConfig']?['access'] == 'ANYONE_ANONYMOUS'));
    Map<String, dynamic> deployed;
    if (existing.isNotEmpty) {
      deployed = Map<String, dynamic>.from(existing.first);
    } else {
      if (data['scriptVersion'] == null) {
        final version = await api.request('POST', 'https://script.googleapis.com/v1/projects/$id/versions', body: {'description': 'School-owned setup'});
        data['scriptVersion'] = version!['versionNumber'];
        await save();
      }
      deployed = (await api.request('POST', 'https://script.googleapis.com/v1/projects/$id/deployments', body: {
        'versionNumber': data['scriptVersion'], 'manifestFileName': 'appsscript', 'description': 'Vidya Saarthi ${data['nonce']}',
      }))!;
    }
    for (final entry in deployed['entryPoints'] as List? ?? []) {
      if (entry['entryPointType'] == 'WEB_APP' &&
          entry['webApp']?['entryPointConfig']?['executeAs'] == 'USER_DEPLOYING' &&
          entry['webApp']?['entryPointConfig']?['access'] == 'ANYONE_ANONYMOUS') {
        final url = entry['webApp']?['url']?.toString() ?? '';
        requireSchoolBackendUri(Uri.parse(url));
        if (!url.endsWith('/exec')) continue;
        data['scriptUrl'] = url; await save();
        return url;
      }
    }
    throw SetupActionRequired('Google has not returned a web-app address. Open the script, authorize VS_easyConnectSetup, then deploy it as a Web app (execute as you, access Anyone) and return to Continue. The app will find the address automatically.',
      Uri.parse('https://script.google.com/home/projects/$id/edit'));
  }
}

Future<Map<String, dynamic>> loadSetupBundle() async => Map<String, dynamic>.from(
  jsonDecode(await rootBundle.loadString('assets/school_setup_bundle.json')));

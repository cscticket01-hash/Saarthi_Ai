import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
  const SetupApiError(this.status, this.service);
  final int status;
  final String service;
  @override
  String toString() => status == 401
      ? 'Google permission expired. Sign in again to continue.'
      : '$service could not finish (HTTP $status). Check account permissions, service availability and project quota, then retry.';
}

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
      throw SetupApiError(response.statusCode, uri.host);
    }
    if (response.body.trim().isEmpty) return {};
    try {
      final data = jsonDecode(response.body);
      if (data is Map) return Map<String, dynamic>.from(data);
    } catch (_) {}
    throw StateError('Unexpected Google setup response. Please retry.');
  }
  Future<Map<String, dynamic>> waitOperation(String host, Map<String, dynamic> operation) async {
    var op = operation;
    for (var attempt = 0; attempt < 90; attempt++) {
      check();
      if (op['done'] == true) {
        if (op['error'] != null) throw StateError('Google could not complete this setup step. Check project quota/permissions and retry.');
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
  final FlutterSecureStorage storage = const FlutterSecureStorage();
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
    required this.progress, required this.bundle});
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
    requireSchoolProjectId(project);
    final url = 'https://cloudresourcemanager.googleapis.com/v1/projects/$project';
    var cloud = await api.request('GET', url, allowMissing: true);
    if (cloud == null) {
      progress('Creating your school’s Google project');
      await api.request('POST', 'https://cloudresourcemanager.googleapis.com/v1/projects', body: {
        'projectId': project, 'name': 'Vidya Saarthi School', 'labels': {'vs-setup': data['nonce']},
      });
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(seconds: 2));
        cloud = await api.request('GET', url, allowMissing: true);
        if (cloud?['lifecycleState'] == 'ACTIVE') break;
      }
    }
    // Never adopt or rewrite a pre-existing project on a name collision.
    if (cloud == null || cloud['labels']?['vs-setup'] != data['nonce'] || cloud['lifecycleState'] != 'ACTIVE') {
      throw StateError('School project ownership marker is missing or creation is still pending. Retry after checking the school Google account.');
    }
    data['projectNumber'] = cloud['projectNumber'].toString();
    await save();
    return cloud;
  }

  Future<Map<String, dynamic>> firebase() async {
    await ensureProject();
    if (data['servicesReady'] != true) {
      progress('Enabling school Firebase services');
      final op = await api.request('POST', 'https://serviceusage.googleapis.com/v1/projects/$number/services:batchEnable', body: {
        'serviceIds': ['firebase.googleapis.com', 'firestore.googleapis.com', 'firebaserules.googleapis.com',
          'identitytoolkit.googleapis.com', 'fcm.googleapis.com'],
      });
      await api.waitOperation('serviceusage.googleapis.com', {...op!, if (op['name'] != null) 'name': 'v1/${op['name']}'});
      final existing = await api.request('GET', 'https://firebase.googleapis.com/v1beta1/projects/$project', allowMissing: true);
      if (existing == null) {
        final add = await api.request('POST', 'https://firebase.googleapis.com/v1beta1/projects/$project:addFirebase', body: {});
        await api.waitOperation('firebase.googleapis.com', {...add!, 'name': 'v1beta1/${add['name']}'});
      }
      data['servicesReady'] = true;
      await save();
    }
    progress('Preparing private school database');
    final dbUrl = 'https://firestore.googleapis.com/v1/projects/$project/databases/(default)';
    if (await api.request('GET', dbUrl, allowMissing: true) == null) {
      final op = await api.request('POST', 'https://firestore.googleapis.com/v1/projects/$project/databases?databaseId=(default)', body: {
        'locationId': data['location'], 'type': 'FIRESTORE_NATIVE', 'deleteProtectionState': 'DELETE_PROTECTION_ENABLED',
      });
      await api.waitOperation('firestore.googleapis.com', {...op!, 'name': 'v1/${op['name']}'});
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
        final app = await api.waitOperation('firebase.googleapis.com', {...op!, 'name': 'v1beta1/${op['name']}'});
        data['webAppId'] = app['appId'];
      }
      await save();
    }
    final config = await api.request('GET', 'https://firebase.googleapis.com/v1beta1/projects/$project/webApps/${Uri.encodeComponent(data['webAppId'])}/config');
    if (config!['projectId'] != project) throw StateError('School Firebase configuration mismatch.');
    data['firebaseConfig'] = config; await save();
    return config;
  }

  Future<List<Map<String, dynamic>>> _pages(String url, String field) async {
    final values = <Map<String, dynamic>>[];
    final seen = <String>{};
    String? page;
    do {
      final target = Uri.parse(url).replace(queryParameters: {
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

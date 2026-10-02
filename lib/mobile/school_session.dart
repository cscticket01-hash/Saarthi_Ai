import 'dart:convert';
import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../platform/github_updates.dart';
import '../school_backend_transport.dart';

class SchoolLink {
  const SchoolLink(
      {required this.projectId,
      required this.scriptUrl,
      required this.role,
      required this.personId,
      required this.linkToken,
      required this.rawQr});
  final String projectId, scriptUrl, role, personId, linkToken, rawQr;
  static SchoolLink parse(String raw) {
    final d = jsonDecode(raw);
    if (d is! Map || d['app'] != 'VIDYA_SAARTHI' || (d['v'] as num? ?? 0) < 2)
      throw const FormatException(
          'Scan a current Vidya Saarthi student or teacher ID card.');
    Map config = {};
    try {
      final rawConfig = d['firebaseLink']?.toString() ?? '{}';
      final uri = Uri.tryParse(rawConfig);
      if (uri?.scheme == 'vidyasaarthi' && uri?.host == 'firebase') {
        config = jsonDecode(utf8.decode(base64Url
            .decode(base64Url.normalize(uri!.queryParameters['config']!))));
      } else {
        config = jsonDecode(rawConfig);
      }
    } catch (_) {
      final text = d['firebaseLink']?.toString() ?? '';
      final start = text.indexOf('{'), end = text.lastIndexOf('}');
      if (start >= 0 && end > start)
        config = jsonDecode(text.substring(start, end + 1));
    }
    final project =
        (d['firebaseProjectId'] ?? config['projectId'] ?? '').toString();
    final role = d['type']?.toString() ?? '';
    final token = d['linkToken']?.toString() ?? '';
    final person = d['personId']?.toString() ?? '';
    final url = Uri.tryParse(d['googleScriptUrl']?.toString() ?? '');
    if (!RegExp(r'^[a-z][a-z0-9-]{4,61}[a-z0-9]$').hasMatch(project) ||
        !{'student', 'teacher'}.contains(role) ||
        token.length < 20 ||
        person.isEmpty ||
        url == null ||
        url.scheme != 'https' ||
        url.host != 'script.google.com' ||
        url.userInfo.isNotEmpty ||
        !RegExp(r'^/macros/s/[A-Za-z0-9_-]+/exec$').hasMatch(url.path) ||
        url.hasQuery ||
        url.hasFragment)
      throw const FormatException(
          'This QR has incomplete or invalid school connections. Ask the school to regenerate it.');
    return SchoolLink(
        projectId: project,
        scriptUrl: url.toString(),
        role: role,
        personId: person,
        linkToken: token,
        rawQr: raw);
  }
}

class SchoolSession {
  SchoolSession._();
  static final instance = SchoolSession._();
  static const _secure = FlutterSecureStorage();
  SchoolLink? link;
  String schoolToken = '', deviceId = '';
  Map<String,dynamic>? messaging;
  Map<String, dynamic> person = {};
  String schoolName = '';
  static const version =
      String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0');
  bool get loggedIn => link != null && schoolToken.isNotEmpty;
  Future<void> restore() async {
    deviceId = await _secure.read(key: 'vs_mobile_device') ??
        base64UrlEncode(List.generate(32, (_) => Random.secure().nextInt(256)));
    await _secure.write(key: 'vs_mobile_device', value: deviceId);
    final raw = await _secure.read(key: 'vs_mobile_session');
    if (raw == null) return;
    try {
      final d = jsonDecode(raw);
      if ((d['expiresAt'] as num) <= DateTime.now().millisecondsSinceEpoch) {
        await clear();
        return;
      }
      link = SchoolLink.parse(d['qr']);
      schoolToken = d['schoolToken'];
      messaging = d['messaging'] is Map ? Map<String,dynamic>.from(d['messaging']) : null;
      person = Map<String, dynamic>.from(d['person'] ?? {});
      schoolName = d['schoolName'] ?? link!.projectId;
    } catch (_) {
      await clear();
    }
  }

  Future<Map<String, dynamic>> schoolCall(
      String action, Map<String, dynamic> body) async {
    if (link == null) throw StateError('Scan your school ID first.');
    final r = await http
        .post(Uri.parse(link!.scriptUrl),
            headers: {'Content-Type': 'text/plain;charset=utf-8'},
            body: jsonEncode({
              'action': action,
              'projectId': link!.projectId,
              'sessionToken': schoolToken,
              ...body
            }))
        .timeout(const Duration(seconds: 30));
    // Google Apps Script redirects POST responses to a one-time content URL.
    final response = r.isRedirect && r.headers['location'] != null
        ? await _redirect(r.headers['location']!)
        : r;
    final d = jsonDecode(response.body);
    if (d is! Map || d['success'] != true)
      throw StateError(d is Map
          ? d['message']?.toString() ?? 'School service unavailable'
          : 'School service unavailable');
    if (d['projectId'] != link!.projectId)
      throw StateError('School identity mismatch. Login blocked.');
    return Map<String, dynamic>.from(d);
  }

  Future<http.Response> _redirect(String location) async {
    final uri=Uri.parse(location);requireSchoolBackendUri(uri);
    return http.get(uri).timeout(const Duration(seconds:20));
  }

  Future<Map<String, dynamic>> platformCall(
      String action, Map<String, dynamic> body) async {
    if(action=='updates/latest') return latestAndroidUpdate();
    if(action=='mobile/heartbeat') return schoolCall('mobile_heartbeat',{'version':version});
    if(action=='complaint/create') return schoolCall('mobile_complaint',body);
    throw ArgumentError('Unknown mobile action');
  }

  Future<void> login(SchoolLink newLink,
      {String studentClass = '',
      String roll = '',
      String dob = '',
      String fcmToken = ''}) async {
    await clear();
    link = newLink;
    final login = await schoolCall('mobile_login', {
      'role': newLink.role,
      'personId': newLink.personId,
      'linkToken': newLink.linkToken,
      'studentClass': studentClass,
      'rollNo': roll,
      'dob': dob
    });
    schoolToken = login['sessionToken'].toString();
    person = Map<String, dynamic>.from(login['person'] ?? {});
    schoolName=login['schoolName']?.toString() ?? newLink.projectId;
    messaging=login['messaging'] is Map ? Map<String,dynamic>.from(login['messaging']) : null;
    if(messaging!=null && messaging!['projectId']!=newLink.projectId) {
      await clear();throw StateError('School messaging project mismatch');
    }
    await _secure.write(
        key: 'vs_mobile_session',
        value: jsonEncode({
          'qr': newLink.rawQr,
          'schoolToken': schoolToken,
          'messaging': messaging,
          'person': person,
          'schoolName': schoolName,
          'expiresAt': login['expiresAt']
        }));
  }

  Future<void> logout() async {
    if (loggedIn) {
      try {
        await schoolCall('mobile_logout', {});
      } catch (_) {}
    }
    await clear();
  }

  Future<void> clear() async {
    link = null;
    schoolToken = '';
    messaging = null;
    person = {};
    schoolName = '';
    await _secure.delete(key: 'vs_mobile_session');
  }
}

import '../qr_authentication_engine.dart';

import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../platform/github_updates.dart';
import '../school_qr_link.dart';
export '../school_qr_link.dart';
import '../school_backend_transport.dart';

/// An authoritative denial must never be mistaken for a transient outage.
class SchoolAccessDenied extends StateError {
  SchoolAccessDenied(super.message);
}

class SchoolSession {
  SchoolSession({http.Client? client, this.cacheDirectory})
    : _client = client ?? http.Client();
  final http.Client _client;
  final Future<Directory> Function()? cacheDirectory;
  Map<String, dynamic> dashboard = {};
  Map<String, dynamic> _pdfCache = {};
  Map<String, Uint8List> _pdfMemory = {};
  Future<Map<String, dynamic>>? _refresh;
  Future<void> _storageTail = Future<void>.value();
  int _expiresAt = 0;
  int _policyExpiresAt = 0;
  bool get cachedAccessAllowed =>
      loggedIn &&
      DateTime.now().millisecondsSinceEpoch < _expiresAt &&
      (_policyExpiresAt == 0 ||
          DateTime.now().millisecondsSinceEpoch < _policyExpiresAt);
  int _generation = 0;
  static final instance = SchoolSession();
  static const _secure = FlutterSecureStorage();
  SchoolLink? link;
  String schoolToken = '', deviceId = '';
  Map<String, dynamic>? messaging;
  Map<String, dynamic> person = {};
  String schoolName = '';
  static const version = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.0.0',
  );
  bool get loggedIn => link != null && schoolToken.isNotEmpty;
  Future<void> restore() async {
    deviceId =
        await _secure.read(key: 'vs_mobile_device') ??
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
      final restoredLink = QrAuthenticationEngine.decode(d['qr']);
      QrAuthenticationEngine.validateSession(
        restoredLink,
        Map<String, dynamic>.from(d),
        now: DateTime.now().millisecondsSinceEpoch,
        restored: true,
      );
      link = restoredLink;
      schoolToken = d['schoolToken'];
      messaging = d['messaging'] is Map
          ? Map<String, dynamic>.from(d['messaging'])
          : null;
      person = Map<String, dynamic>.from(d['person'] ?? {});
      schoolName = d['schoolName'] ?? link!.projectId;
      _expiresAt = (d['expiresAt'] as num).toInt();
      _policyExpiresAt = (d['policyExpiresAt'] as num? ?? 0).toInt();
      if (d['cacheSchool'] == link!.projectId &&
          d['cachePerson'] == link!.personId) {
        dashboard = Map<String, dynamic>.from(d['dashboard'] as Map? ?? {});
        _pdfCache = Map<String, dynamic>.from(d['pdfCache'] as Map? ?? {});
      }
    } catch (_) {
      await clear();
    }
  }

  static Map<String, dynamic> _decodeSchoolResponse(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    throw StateError(
      'School service returned an invalid response. Try again; if it continues, contact the school administrator.',
    );
  }

  Future<Map<String, dynamic>> schoolCall(
    String action,
    Map<String, dynamic> body,
  ) async {
    final current = link;
    final generation = _generation;
    if (current == null) throw StateError('Scan your school ID first.');
    void unchanged() {
      if (generation != _generation || !identical(current, link))
        throw StateError('School session changed. Scan your ID again.');
    }

    if (current.managed) {
      final r = await _client
          .post(
            Uri.parse(current.endpoint),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'action': 'managed/mobile',
              'schoolId': current.schoolId,
              'request': {
                ...body,
                'action': action,
                'sessionToken': schoolToken,
              },
            }),
          )
          .timeout(const Duration(seconds: 25));
      unchanged();
      final d = _decodeSchoolResponse(r.body);
      if (r.statusCode == 401 || r.statusCode == 403) {
        await clear();
        throw SchoolAccessDenied(
          d['message']?.toString() ?? 'School access is inactive.',
        );
      }
      if (r.statusCode != 200 || d['success'] != true)
        throw StateError(
          d is Map
              ? d['message']?.toString() ?? 'Unable to connect'
              : 'Unable to connect',
        );
      if (d['schoolId'] != current.schoolId ||
          d['projectId'] != current.schoolId) {
        await clear();
        throw SchoolAccessDenied('School identity mismatch');
      }
      if (d['policyExpiresAt'] is num)
        _policyExpiresAt = (d['policyExpiresAt'] as num).toInt();
      return Map<String, dynamic>.from(d);
    }
    final r = await _client
        .post(
          Uri.parse(current.scriptUrl),
          headers: {'Content-Type': 'text/plain;charset=utf-8'},
          body: jsonEncode({
            ...body,
            'action': action,
            'projectId': current.projectId,
            'sessionToken': schoolToken,
          }),
        )
        .timeout(const Duration(seconds: 30));
    // Google Apps Script redirects POST responses to a one-time content URL.
    final response = r.isRedirect && r.headers['location'] != null
        ? await _redirect(r.headers['location']!)
        : r;
    unchanged();
    final d = _decodeSchoolResponse(response.body);
    if (d is! Map || d['success'] != true)
      throw StateError(
        d is Map
            ? d['message']?.toString() ?? 'School service unavailable'
            : 'School service unavailable',
      );
    if (d['projectId'] != current.projectId) {
      await clear();
      throw SchoolAccessDenied('School identity mismatch. Login blocked.');
    }
    return Map<String, dynamic>.from(d);
  }

  Future<http.Response> _redirect(String location) async {
    final uri = Uri.parse(location);
    requireSchoolBackendUri(uri);
    return _client.get(uri).timeout(const Duration(seconds: 20));
  }

  Future<Map<String, dynamic>> platformCall(
    String action,
    Map<String, dynamic> body,
  ) async {
    if (action == 'updates/latest') return latestAndroidUpdate();
    if (action == 'mobile/heartbeat')
      return schoolCall('mobile_heartbeat', {'version': version});
    if (action == 'complaint/create')
      return schoolCall('mobile_complaint', body);
    throw ArgumentError('Unknown mobile action');
  }

  Future<void> login(
    SchoolLink newLink, {
    String studentClass = '',
    String roll = '',
    String dob = '',
    String fcmToken = '',
  }) async {
    await clear();
    link = newLink;
    final generation = _generation;
    late final Map<String, dynamic> login;
    try {
      login = await QrAuthenticationEngine.authenticate(
        newLink,
        (body) => schoolCall('mobile_login', body),
        studentClass: studentClass,
        roll: roll,
        dob: dob,
      );
    } catch (_) {
      if (generation == _generation) await clear();
      rethrow;
    }
    if (login['sessionToken'] is! String ||
        (login['sessionToken'] as String).isEmpty ||
        login['expiresAt'] is! num ||
        (login['expiresAt'] as num) <= DateTime.now().millisecondsSinceEpoch) {
      await clear();
      throw StateError('School returned an invalid login session.');
    }
    schoolToken = login['sessionToken'] as String;
    _expiresAt = (login['expiresAt'] as num).toInt();
    person = Map<String, dynamic>.from(login['person'] ?? {});
    schoolName = login['schoolName']?.toString() ?? newLink.projectId;
    messaging = login['messaging'] is Map
        ? Map<String, dynamic>.from(login['messaging'])
        : null;
    if (messaging != null && messaging!['projectId'] != newLink.projectId) {
      await clear();
      throw StateError('School messaging project mismatch');
    }
    await _persist();
  }

  Future<void> _persist() async {
    if (!loggedIn) return;
    final generation = _generation;
    final value = jsonEncode({
      'qr': link!.rawQr,
      'schoolToken': schoolToken,
      'messaging': messaging,
      'person': person,
      'schoolName': schoolName,
      'expiresAt': _expiresAt,
      'policyExpiresAt': _policyExpiresAt,
      'cacheSchool': link!.projectId,
      'cachePerson': link!.personId,
      'dashboard': dashboard,
      'pdfCache': _pdfCache,
    });
    final write = _storageTail.then((_) async {
      if (generation == _generation)
        await _secure.write(key: 'vs_mobile_session', value: value);
    });
    _storageTail = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    await write;
  }

  /// One coalesced refresh of versioned, permission-filtered school content.
  /// Failed refreshes preserve the last durable verified generation.
  Future<Map<String, dynamic>> refreshDashboard() {
    final running = _refresh;
    if (running != null) return running;
    final pending = _refreshDashboard();
    _refresh = pending;
    pending.then(
      (_) {
        if (identical(_refresh, pending)) _refresh = null;
      },
      onError: (Object _, StackTrace __) {
        if (identical(_refresh, pending)) _refresh = null;
      },
    );
    return pending;
  }

  Future<Map<String, dynamic>> _refreshDashboard() async {
    final generation = _generation;
    final result = await schoolCall('mobile_dashboard', {
      if (dashboard['revision'] is String)
        'knownRevision': dashboard['revision'],
      if (dashboard['revisions'] is Map)
        'knownRevisions': dashboard['revisions'],
    });
    if (generation != _generation)
      throw SchoolAccessDenied('School session changed.');
    if (result['unchanged'] != true) {
      final merged = {...dashboard, ...result};
      if (jsonEncode(merged).length > 2 * 1024 * 1024)
        throw StateError('School response exceeds cache safety limit.');
      final old = dashboard, oldPerson = person;
      dashboard = merged;
      person = Map<String, dynamic>.from(dashboard['person'] as Map? ?? person);
      try {
        await _persist();
      } catch (_) {
        dashboard = old;
        person = oldPerson;
        rethrow;
      }
    } else {
      dashboard = {...dashboard, ...result};
      await _persist();
    }
    return dashboard;
  }

  Future<Directory> _files() async {
    final base =
        await (cacheDirectory?.call() ?? getApplicationSupportDirectory());
    final owner = sha256
        .convert(
          utf8.encode('${link!.projectId}/${link!.role}/${link!.personId}'),
        )
        .toString();
    return Directory('${base.path}/verified-school-content/$owner');
  }

  Future<Uint8List?> cachedPdf(String key) async {
    if (!cachedAccessAllowed) return null;
    if (_pdfMemory.containsKey(key)) return _pdfMemory[key];
    final metadata = _pdfCache[key];
    if (metadata is! Map ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(metadata['hash']?.toString() ?? ''))
      return null;
    final origin = _generation;
    final file = File('${(await _files()).path}/${metadata['hash']}.pdf');
    if (!await file.exists()) return null;
    final bytes = await file.readAsBytes();
    if (origin != _generation || !cachedAccessAllowed) return null;
    if (sha256.convert(bytes).toString() != metadata['hash']) return null;
    _pdfMemory[key] = bytes;
    return bytes;
  }

  String? cachedPdfVersion(String key) =>
      (_pdfCache[key] as Map?)?['version']?.toString();
  Future<void> cachePdf(
    String key,
    String version,
    Uint8List bytes, {
    required String expectedHash,
  }) async {
    final origin = _generation;
    if (!cachedAccessAllowed)
      throw SchoolAccessDenied('Verified school access required.');
    if (bytes.length > 20 * 1024 * 1024 ||
        bytes.length < 12 ||
        !String.fromCharCodes(bytes.take(5)).startsWith('%PDF-') ||
        !String.fromCharCodes(
          bytes.skip(bytes.length > 2048 ? bytes.length - 2048 : 0),
        ).contains('%%EOF') ||
        sha256.convert(bytes).toString() != expectedHash)
      throw StateError(
        'Published document verification failed; previous copy retained.',
      );
    final directory = await _files();
    await directory.create(recursive: true);
    final file = File('${directory.path}/$expectedHash.pdf');
    final temporary = File('${file.path}.$origin.pending');
    await temporary.writeAsBytes(bytes, flush: true);
    if (origin != _generation)
      throw SchoolAccessDenied('School session changed.');
    if (!await file.exists())
      await temporary.rename(file.path);
    else
      await temporary.delete();
    final old = _pdfCache[key];
    _pdfCache[key] = {'version': version, 'hash': expectedHash};
    try {
      await _persist();
    } catch (_) {
      if (old == null)
        _pdfCache.remove(key);
      else
        _pdfCache[key] = old;
      rethrow;
    }
    if (origin != _generation)
      throw SchoolAccessDenied('School session changed.');
    _pdfMemory[key] = bytes;
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
    _generation++;
    link = null;
    schoolToken = '';
    messaging = null;
    person = {};
    schoolName = '';
    dashboard = {};
    _pdfCache = {};
    _pdfMemory = {};
    _refresh = null;
    _expiresAt = 0;
    _policyExpiresAt = 0;
    final deletion = _storageTail.then(
      (_) => _secure.delete(key: 'vs_mobile_session'),
    );
    _storageTail = deletion.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    await deletion;
  }
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'platform/spark_client.dart';
import 'school_backend_transport.dart';
import 'windows_firebase_sync.dart';
import 'windows_local_firestore.dart';
import 'windows_local_settings.dart';

class WindowsLicenseState {
  const WindowsLicenseState(
      {required this.allowed,
      required this.status,
      required this.expiresAt,
      this.error = ''});
  final bool allowed;
  final String status;
  final DateTime expiresAt;
  final String error;
  int get daysLeft =>
      max(0, (expiresAt.difference(DateTime.now()).inMilliseconds / 86400000).ceil());
}

class WindowsPlatformClient {
  WindowsPlatformClient._();
  static final instance = WindowsPlatformClient._();
  static const _secure = FlutterSecureStorage();
  final state = ValueNotifier<WindowsLicenseState>(WindowsLicenseState(
      allowed: true, status: 'checking', expiresAt: DateTime.now()));
  String _id = '',
      _secret = '',
      _boundProject = '',
      _boundScript = '',
      _cacheProject = '';
  DateTime? _trialStart, _lastSeen, _verifiedAt;
  Timer? _timer, _refreshDebounce;
  bool _running = false, _registered = false;
  final Set<String> _sentNotices = {};
  static const version =
      String.fromEnvironment('APP_VERSION', defaultValue: '2.1.79');
  String _random() => base64UrlEncode(
          List<int>.generate(32, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');
  Future<Map<String, dynamic>> call(
      String action, Map<String, dynamic> body) async {
    if (action == 'installation/register') {
      final at = await SparkTrialClient.deviceTrial(body['deviceFingerprint'].toString());
      return {'success':true, 'trialStartedAt':at.millisecondsSinceEpoch, 'installationSecret':_secret};
    }
    final remote = await WindowsFirebaseRemote.status();
    if (!remote.authenticated || remote.projectId.isEmpty ||
        body['projectId'] != null && body['projectId'] != remote.projectId) {
      throw StateError('Connect this school administrator Firebase account first.');
    }
    final url = Uri.parse(await WindowsExternalConnections.googleScriptUrl());
    requireSchoolBackendUri(url);
    if (url.host != 'script.google.com' ||
        !RegExp(r'^/macros/s/[A-Za-z0-9_-]+/exec$').hasMatch(url.path) || url.hasQuery || url.hasFragment) {
      throw StateError('Use this school’s deployed Google Script /exec URL.');
    }
    const actions = {'school/bind':'platform_bind', 'school/heartbeat':'platform_heartbeat',
      'installation/status':'platform_status', 'license/activate':'platform_activate',
      'school/notice':'platform_notice', 'complaint/create':'platform_complaint'};
    if (!actions.containsKey(action)) throw ArgumentError('Unknown platform action');
    var response = await http.post(url,
      headers:{'Content-Type':'text/plain;charset=utf-8'},
      body:jsonEncode({'action':actions[action], 'schoolProjectId':remote.projectId,
        'schoolAdminIdToken':await WindowsFirebaseRemote.freshIdToken(),
        for(final k in ['key','version','noticeId','message']) if(body.containsKey(k)) k:body[k],
      })).timeout(const Duration(seconds: 30));
    if(response.isRedirect && response.headers['location'] != null) {
      final redirect = Uri.parse(response.headers['location']!);
      requireSchoolBackendUri(redirect);
      response = await http.get(redirect).timeout(const Duration(seconds:20));
    }
    final d = jsonDecode(response.body);
    if (d is! Map || response.statusCode >= 400 || d['success'] != true || d['projectId'] != remote.projectId)
      throw StateError(d is Map
          ? d['message']?.toString() ?? 'Platform unavailable'
          : 'Platform unavailable');
    if({'school/bind','school/heartbeat','installation/status','license/activate'}.contains(action)) {
      final hash=action=='license/activate'
          ? sha256.convert(utf8.encode(body['key'].toString().trim().toUpperCase())).toString()
          : d['licenseHash']?.toString();
      final central=SparkLicenseClient();
      try {return {...Map<String,dynamic>.from(d), ...await central.schoolStatus(remote.projectId,licenseHash:hash)};}
      finally {central.close();}
    }
    return Map<String, dynamic>.from(d);
  }

  Future<void> initialize() async {
    if (_id.isNotEmpty) return;
    _id = await _secure.read(key: 'vs_installation_id') ?? _random();
    await _secure.write(key: 'vs_installation_id', value: _id);
    _secret = await _secure.read(key: 'vs_installation_secret') ?? '';
    _registered = await _secure.read(key: 'vs_spark_trial_verified') == 'true';
    _trialStart =
        DateTime.tryParse(await _secure.read(key: 'vs_trial_start') ?? '') ??
            DateTime.now().toUtc();
    await _secure.write(
        key: 'vs_trial_start', value: _trialStart!.toIso8601String());
    _lastSeen = DateTime.tryParse(
        await _secure.read(key: 'vs_license_last_seen') ?? '');
    _verifiedAt = DateTime.tryParse(
        await _secure.read(key: 'vs_license_verified_at') ?? '');
    final cache = await _secure.read(key: 'vs_license_cache');
    if (cache != null) {
      try {
        _apply(Map<String, dynamic>.from(jsonDecode(cache)), verified: false);
      } catch (_) {}
    }
    final active = await WindowsFirebaseRemote.status();
    if (_cacheProject.isNotEmpty && active.projectId != _cacheProject) {
      _verifiedAt = null;
      state.value = WindowsLicenseState(
          allowed: false, status: 'unbound', expiresAt: DateTime.now());
    }
    _offlineState('');
    unawaited(refresh());
    _timer = Timer.periodic(
        const Duration(seconds: 60), (_) => unawaited(refresh()));
  }

  void _offlineState(String error) {
    final now = DateTime.now().toUtc();
    final clockOK = _lastSeen == null ||
        !now.isBefore(_lastSeen!.subtract(const Duration(minutes: 5)));
    final trialEnd = _trialStart!.add(const Duration(days: 5));
    final cached = state.value;
    final paidOffline = cached.status == 'licensed' &&
        _verifiedAt != null &&
        now.difference(_verifiedAt!).inHours <= 72 &&
        cached.expiresAt.isAfter(now);
    if (cached.status == 'blocked') {
      state.value = WindowsLicenseState(
          allowed: false,
          status: 'blocked',
          expiresAt: cached.expiresAt,
          error: error);
      return;
    }
    state.value = WindowsLicenseState(
        allowed: clockOK && (paidOffline || trialEnd.isAfter(now)),
        status: !clockOK
            ? 'clock_error'
            : paidOffline
                ? 'licensed'
                : trialEnd.isAfter(now)
                    ? 'trial'
                    : 'expired',
        expiresAt: paidOffline ? cached.expiresAt : trialEnd,
        error: error);
  }

  void _apply(Map<String, dynamic> data, {bool verified = true}) {
    final now = DateTime.now().toUtc();
    final serverTime = (data['serverTime'] as num?)?.toInt();
    if (verified && serverTime != null) {
      final serverDate =
          DateTime.fromMillisecondsSinceEpoch(serverTime, isUtc: true);
      // An online server check can recover from an accidentally advanced clock.
      _lastSeen = serverDate;
      if (now.difference(serverDate).inMinutes.abs() > 5) {
        state.value = WindowsLicenseState(
            allowed: false,
            status: 'clock_error',
            expiresAt: serverDate,
            error: 'Correct the device clock and reconnect.');
        return;
      }
    }
    _cacheProject = data['schoolId']?.toString() ?? '';
    var end = DateTime.fromMillisecondsSinceEpoch(
        (data['expiresAt'] as num?)?.toInt() ?? 0,
        isUtc: true);
    if (data['status'] == 'trial' || data['status'] == 'expired') {
      final trial = end.subtract(const Duration(days: 5));
      if (_trialStart == null || trial.isBefore(_trialStart!)) {
        _trialStart = trial;
        unawaited(_secure.write(
            key: 'vs_trial_start', value: trial.toIso8601String()));
      }
      final localEnd = _trialStart!.add(const Duration(days: 5));
      if (localEnd.isBefore(end)) end = localEnd;
    }
    state.value = WindowsLicenseState(
        allowed: data['allowed'] == true && end.isAfter(now),
        status: data['status']?.toString() ?? 'expired',
        expiresAt: end);
    if (verified) {
      _verifiedAt = now;
      unawaited(_secure.write(
          key: 'vs_license_verified_at', value: now.toIso8601String()));
      unawaited(
          _secure.write(key: 'vs_license_cache', value: jsonEncode(data)));
    }
  }

  Future<void> refresh() async {
    if (_running) return;
    _running = true;
    try {
      if (!_registered) {
        if (_secret.isEmpty) {
          _secret = _random();
          await _secure.write(key: 'vs_installation_registered', value: 'false');
          await _secure.write(key: 'vs_installation_secret', value: _secret);
        }
        String hardware = Platform.environment['COMPUTERNAME'] ?? _id;
        try {
          final r = await Process.run('reg', [
            'query',
            r'HKLM\SOFTWARE\Microsoft\Cryptography',
            '/v',
            'MachineGuid'
          ]);
          if (r.exitCode == 0) hardware = r.stdout.toString().trim();
        } catch (_) {}
        try {
          final data = await call('installation/register', {
            'deviceFingerprint': sha256.convert(utf8.encode(hardware)).toString()
          });
          _registered = true;
          await _secure.write(key: 'vs_spark_trial_verified', value: 'true');
          final serverStart = DateTime.fromMillisecondsSinceEpoch(
              (data['trialStartedAt'] as num).toInt(), isUtc: true);
          if (serverStart.isBefore(_trialStart!)) _trialStart = serverStart;
          await _secure.write(key: 'vs_trial_start', value: _trialStart!.toIso8601String());
        } catch (e) { debugPrint('Server trial check pending: $e'); }
      }
      final remote = await WindowsFirebaseRemote.status();
      if (_cacheProject.isNotEmpty && remote.projectId != _cacheProject) {
        _verifiedAt = null;
        state.value = WindowsLicenseState(
            allowed: false, status: 'unbound', expiresAt: DateTime.now());
      }
      final links = await WindowsExternalConnections.load();
      final script = links['googleScriptUrl']?.toString().trim() ?? '';
      if (remote.authenticated &&
          script.isNotEmpty &&
          (_boundProject != remote.projectId || _boundScript != script)) {
        final nameDoc = await FirebaseFirestore.instance
            .collection('school_config')
            .doc('school_profile_cache')
            .get();
        final bound = await call('school/bind', {
          'projectId': remote.projectId,
          'googleScriptUrl': script,
          'schoolIdToken': await WindowsFirebaseRemote.freshIdToken(),
          'schoolName': nameDoc.data()?['schoolName'] ?? remote.projectId,
          'version': version
        });
        if (_boundProject != remote.projectId) _sentNotices.clear();
        _boundProject = remote.projectId;
        _boundScript = script;
        _apply(bound);
      }
      final students = await FirebaseFirestore.instance
          .collection('students_directory')
          .get();
      final teachers = await FirebaseFirestore.instance
          .collection('teachers_directory')
          .get();
      final heartbeat = await call('school/heartbeat', {
        'version': version,
        'studentCount': students.docs.length,
        'teacherCount': teachers.docs.length
      });
      if (heartbeat['schoolId'] != null &&
          remote.projectId != heartbeat['schoolId'])
        throw StateError(
            'Connect and verify the active school before using its license.');
      _apply(heartbeat);
      if (state.value.allowed && _boundProject.isNotEmpty) {
        try { await _relayNotices(); } catch (e) { debugPrint('School notice retry pending: $e'); }
      }
    } catch (e) {
      _offlineState(e.toString().replaceFirst('Bad state: ', ''));
    } finally {
      final now = DateTime.now().toUtc();
      if (_lastSeen == null || now.isAfter(_lastSeen!)) _lastSeen = now;
      await _secure.write(
          key: 'vs_license_last_seen', value: _lastSeen!.toIso8601String());
      _running = false;
    }
  }

  Future<void> _relayNotices() async {
    final list =
        await FirebaseFirestore.instance.collection('school_notices').get();
    for (final doc in list.docs) {
      if (_sentNotices.contains(doc.id)) continue;
      final d = doc.data();
      final raw = d['timestamp'] ?? d['createdAt'];
      final at = raw is Timestamp
          ? raw.millisecondsSinceEpoch
          : raw is num
              ? raw.toInt()
              : DateTime.tryParse(raw?.toString() ?? '')
                      ?.millisecondsSinceEpoch ??
                  0;
      if (at <
          DateTime.now()
              .subtract(const Duration(days: 7))
              .millisecondsSinceEpoch) {
        _sentNotices.add(doc.id);
        continue;
      }
      await call('school/notice', {
        'noticeId': doc.id,
        'title': d['title'] ?? 'School notice',
        'message': d['description'] ?? d['message'] ?? ''
      });
      _sentNotices.add(doc.id);
    }
  }

  Future<void> activate(String key) async {
    final remote = await WindowsFirebaseRemote.status();
    if (!remote.authenticated || remote.projectId.isEmpty)
      throw StateError(
          'Connect and verify this school before activating its licence.');
    final data =
        await call('license/activate', {'key': key.trim().toUpperCase()});
    _apply(data);
    _boundProject=remote.projectId;
    _boundScript=await WindowsExternalConnections.googleScriptUrl();
    await _secure.write(
        key: 'vidya_saarthi_windows_license_status_v1', value: 'active');
  }

  Future<void> complaint(String message) async {
    await call('complaint/create', {'message': message, 'version': version});
  }

  void scheduleRefresh() {
    if (_id.isEmpty) return;
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(seconds: 2), () => unawaited(refresh()));
  }
  void dispose() {
    _refreshDebounce?.cancel();
    _timer?.cancel();
  }
}

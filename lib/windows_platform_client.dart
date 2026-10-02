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
import 'windows_notice_delivery.dart';

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
      _fingerprint = '',
      _cacheProject = '';
  DateTime? _trialStart, _lastSeen, _verifiedAt;
  Timer? _timer, _refreshDebounce;
  bool _running = false, _registered = false;
  bool _paused = false, _activating = false, _licenseDenied = false;
  String _activeLicenseHash = '', _licenseProject = '';
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
        for(final k in ['key','version','noticeId','message','deviceFingerprint']) if(body.containsKey(k)) k:body[k],
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
    _fingerprint=await _secure.read(key:'vs_device_trial_fingerprint')??'';
    if(_fingerprint.isEmpty) _registered=false;
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
    _activeLicenseHash = await _secure.read(key: 'vs_active_license_hash') ?? '';
    _licenseProject = await _secure.read(key: 'vs_active_license_project') ?? '';
    _licenseDenied = await _secure.read(key: 'vs_license_denied') == 'true';
    if (cache != null) {
      try {
        await _apply(Map<String, dynamic>.from(jsonDecode(cache)), verified: false);
      } catch (_) {}
    }
    // Migrate already-activated installations to independent central checks.
    // The saved key is a lookup capability, never evidence of validity itself.
    if (_activeLicenseHash.isEmpty && _cacheProject.isNotEmpty) {
      final previousKey = (await _secure.read(key: 'vidya_saarthi_windows_license_key_v1') ?? '').trim().toUpperCase();
      if (previousKey.isNotEmpty) {
        _activeLicenseHash = sha256.convert(utf8.encode(previousKey)).toString();
        _licenseProject = _cacheProject;
        await _secure.write(key: 'vs_active_license_hash', value: _activeLicenseHash);
        await _secure.write(key: 'vs_active_license_project', value: _licenseProject);
      }
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
    if (_licenseDenied || cached.status == 'blocked') {
      state.value = WindowsLicenseState(
          allowed: false,
          status: 'blocked',
          expiresAt: cached.expiresAt,
          error: error);
      return;
    }
    state.value = WindowsLicenseState(
        allowed: clockOK && (paidOffline || (_activeLicenseHash.isEmpty && trialEnd.isAfter(now))),
        status: !clockOK
            ? 'clock_error'
            : paidOffline
                ? 'licensed'
                : _activeLicenseHash.isEmpty && trialEnd.isAfter(now)
                    ? 'trial'
                    : 'expired',
        expiresAt: paidOffline ? cached.expiresAt : trialEnd,
        error: error);
  }

  Future<void> _apply(Map<String, dynamic> data, {bool verified = true}) async {
    final now = DateTime.now().toUtc();
    final serverTime = (data['serverTime'] as num?)?.toInt();
    if (verified && serverTime != null) {
      final serverDate =
          DateTime.fromMillisecondsSinceEpoch(serverTime, isUtc: true);
      // An online server check can recover from an accidentally advanced clock.
      if (now.difference(serverDate).inMinutes.abs() > 5) {
        state.value = WindowsLicenseState(
            allowed: false,
            status: 'clock_error',
            expiresAt: serverDate,
            error: 'Correct the device clock and reconnect.');
        return;
      }
      _lastSeen = serverDate;
    }
    if (verified && data['licenseHash'] is String) {
      _activeLicenseHash = data['licenseHash'] as String;
      _licenseProject = data['schoolId']?.toString() ?? '';
      await _secure.write(key: 'vs_active_license_hash', value: _activeLicenseHash);
      await _secure.write(key: 'vs_active_license_project', value: _licenseProject);
      _licenseDenied = data['allowed'] != true || data['status'] != 'licensed';
      await _secure.write(key: 'vs_license_denied', value: '$_licenseDenied');
    }
    _cacheProject = data['schoolId']?.toString() ?? '';
    var end = DateTime.fromMillisecondsSinceEpoch(
        (data['expiresAt'] as num?)?.toInt() ?? 0,
        isUtc: true);
    if (data['licenseHash'] == null && (data['status'] == 'trial' || data['status'] == 'expired')) {
      final trial = end.subtract(const Duration(days: 5));
      if (_trialStart == null || trial.isBefore(_trialStart!)) {
        _trialStart = trial;
        await _secure.write(
            key: 'vs_trial_start', value: trial.toIso8601String());
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
      await _secure.write(
          key: 'vs_license_verified_at', value: now.toIso8601String());
      await _secure.write(key: 'vs_license_cache', value: jsonEncode(data));
    }
  }

  Future<void> refresh() async {
    if (_running || _paused || _activating) return;
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
        _fingerprint=sha256.convert(utf8.encode(hardware)).toString();
        await _secure.write(key:'vs_device_trial_fingerprint',value:_fingerprint);
        try {
          final data = await call('installation/register', {
            'deviceFingerprint': _fingerprint
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
      // Verify the saved capability directly with the developer platform BEFORE
      // contacting school-owned scripts. A broken/modified school script must
      // not stop revocation or expiry checks of an activated Windows licence.
      if (_activeLicenseHash.isNotEmpty && _licenseProject.isNotEmpty && remote.projectId == _licenseProject) {
        final central = SparkLicenseClient();
        try {
          final checked = await central.schoolStatus(_licenseProject, licenseHash: _activeLicenseHash);
          await _apply(checked);
          if (checked['allowed'] != true || !state.value.allowed) return;
        } on LicenseVerificationRejected catch (e) {
          _licenseDenied = true;
          await _secure.write(key: 'vs_license_denied', value: 'true');
          _offlineState('$e');
          return;
        } finally { central.close(); }
      }
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
          'deviceFingerprint':_fingerprint,
          'projectId': remote.projectId,
          'googleScriptUrl': script,
          'schoolIdToken': await WindowsFirebaseRemote.freshIdToken(),
          'schoolName': nameDoc.data()?['schoolName'] ?? remote.projectId,
          'version': version
        });
        if (_boundProject != remote.projectId) _sentNotices.clear();
        _boundProject = remote.projectId;
        _boundScript = script;
        if (_activeLicenseHash.isEmpty || bound['licenseHash'] == _activeLicenseHash) await _apply(bound);
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
      // A school-owned response that omits a known licence cannot replace a
      // paid/revoked capability with a fresh trial.
      if (_activeLicenseHash.isEmpty || heartbeat['licenseHash'] == _activeLicenseHash) await _apply(heartbeat);
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
    final profile = FirebaseFirestore.instance.activeProfileId;
    final list =
        await FirebaseFirestore.instance.collection('school_notices').get();
    for (final doc in list.docs) {
      if (FirebaseFirestore.instance.activeProfileId != profile) return;
      if (_sentNotices.contains(doc.id)) continue;
      final d = doc.data();
      // Old local saves and drafts are never silently advertised as sent.
      if (d['deliveryStatus'] != 'notification_pending' ||
          (d['recipientCount'] is! num || d['recipientCount'] <= 0)) continue;
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
      final response = await call('school/notice', {
        'noticeId': doc.id,
        'title': d['title'] ?? 'School notice',
        'message': d['description'] ?? d['message'] ?? ''
      });
      if (FirebaseFirestore.instance.activeProfileId != profile) return;
      if (response['sent'] != true) continue;
      await doc.reference.update({'deliveryStatus': 'sent'});
      _sentNotices.add(doc.id);
    }
  }

  Future<WindowsNoticeDelivery> publishNotice(String id, Map<String, dynamic> data) async {
    final profile = FirebaseFirestore.instance.activeProfileId;
    final remote = await WindowsFirebaseRemote.status();
    if (!remote.authenticated || remote.projectId.isEmpty) {
      throw StateError('Notice not sent. Connect and verify this school Firebase and Google Script first.');
    }
    final token = await WindowsFirebaseRemote.freshIdToken();
    final roster = await WindowsFirebaseRemote.readCollection(
      projectId: remote.projectId, idToken: token, collection: 'students_directory');
    final users = await WindowsFirebaseRemote.readCollection(
      projectId: remote.projectId, idToken: token, collection: 'mobile_users');
    if (FirebaseFirestore.instance.activeProfileId != profile) throw StateError('School changed. Retry notice publication.');
    final recipients = schoolNoticeRecipients(roster.values, users.values);
    if (recipients == 0) {
      throw StateError('Notice not sent. No students with an issued ID-card QR have registered in this school student app.');
    }
    // The school Script must respond online before a notice is published.
    await call('installation/status', {'projectId': remote.projectId});
    final payload = {...data, 'recipientCount': recipients,
      'deliveryStatus': 'notification_pending'};
    await WindowsFirebaseRemote.writeDocument(projectId: remote.projectId,
      idToken: token, collection: 'school_notices', documentId: id, data: payload);
    if (FirebaseFirestore.instance.activeProfileId != profile) throw StateError('School changed. Retry notice publication.');
    await FirebaseFirestore.instance.collection('school_notices').doc(id).set(payload);
    try {
      final sent = await call('school/notice', {'projectId': remote.projectId, 'noticeId': id});
      if (sent['sent'] != true) throw StateError('School notification was not acknowledged.');
      if (FirebaseFirestore.instance.activeProfileId != profile) throw StateError('School changed. Check notice status in the original school.');
      _sentNotices.add(id);
      await FirebaseFirestore.instance.collection('school_notices').doc(id).update({'deliveryStatus': 'sent'});
      return WindowsNoticeDelivery(notificationSent: true, recipients: recipients);
    } catch (e) {
      return WindowsNoticeDelivery(notificationSent: false, recipients: recipients, error: '$e');
    }
  }

  static const licenseSkippedKey =
      'vidya_saarthi_windows_license_skipped_v1';

  /// Test-only override so widget tests can pin the skip state without a
  /// real secure-storage round trip. Null means "read from storage".
  static bool? skippedOverride;

  /// Remember that the user chose "Skip" on the first-run licence screen.
  Future<void> markLicenseSkipped() async {
    await _secure.write(key: licenseSkippedKey, value: 'true');
  }

  Future<bool> licenseSkipped() async =>
      skippedOverride ?? await _secure.read(key: licenseSkippedKey) == 'true';

  Future<void> clearLicenseSkipped() async {
    skippedOverride = null;
    await _secure.delete(key: licenseSkippedKey);
  }

  Future<void> activate(String key) async {
    if (_paused || _activating) throw StateError('Licence operation is already running.');
    final normalized = key.trim().toUpperCase();
    if (!RegExp(r'^VS-[A-Z0-9_-]{16,}$').hasMatch(normalized)) throw StateError('Enter the complete licence key issued by the developer website.');
    _activating = true;
    try {
    while (_running) { await Future<void>.delayed(const Duration(milliseconds: 100)); }
    final remote = await WindowsFirebaseRemote.status();
    final boundProject = remote.projectId;
    final data =
        await call('license/activate', {'key': normalized});
    final current = await WindowsFirebaseRemote.status();
    if (current.authenticated &&
        current.projectId.isNotEmpty &&
        current.projectId != boundProject) {
      throw StateError('School changed during activation. Retry for the active school.');
    }
    await _apply(data);
    if (data['allowed'] != true || data['status'] != 'licensed' || !state.value.allowed || state.value.status != 'licensed') {
      throw StateError('Licence is expired, revoked or could not be verified.');
    }
    _boundProject=boundProject;
    _boundScript=await WindowsExternalConnections.googleScriptUrl();
    await _secure.write(
        key: 'vidya_saarthi_windows_license_status_v1', value: 'active');
    await _secure.write(key: 'vidya_saarthi_windows_license_key_v1', value: normalized);
    await _secure.write(key: 'vidya_saarthi_windows_license_saved_at_v1', value: DateTime.now().toIso8601String());
    await clearLicenseSkipped();
    } finally { _activating = false; }
  }

  Future<void> resetAppActivation() async {
    _paused = true;
    _refreshDebounce?.cancel();
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (_running || _activating) {
        if (DateTime.now().isAfter(deadline)) throw StateError('Licence check is still finishing. Retry reset shortly.');
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      for (final key in ['vs_license_cache','vs_license_verified_at','vs_active_license_hash','vs_active_license_project']) {
        await _secure.delete(key: key);
      }
      _verifiedAt = null;
      _activeLicenseHash = ''; _licenseProject = ''; _cacheProject = '';
      _boundProject = ''; _boundScript = ''; _sentNotices.clear();
      // Device identity, original trial and confirmed revocation evidence stay.
      if (_trialStart != null) {
        state.value = WindowsLicenseState(allowed:false, status:_licenseDenied ? 'blocked' : 'checking', expiresAt:_trialStart!.add(const Duration(days:5)));
        _offlineState('');
      }
    } catch (_) { _paused = false; rethrow; }
  }

  void resumeAfterAppReset() { _paused = false; }

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

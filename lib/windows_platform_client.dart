import 'windows_sync_engine.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_connect/central_school_cloud.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'windows_secure_storage.dart';
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
      this.error = '',this.activated=false});
  final bool allowed;
  final bool activated;
  final String status;
  final DateTime expiresAt;
  final String error;
  int get daysLeft =>
      max(0, (expiresAt.difference(DateTime.now()).inMilliseconds / 86400000).ceil());
}

class WindowsPlatformClient {
  WindowsPlatformClient._();
  static final instance = WindowsPlatformClient._();
  static const _secure = WindowsSecureStorage();
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
    if (!remote.authenticated || remote.schoolIdentity.isEmpty ||
        body['projectId'] != null && body['projectId'] != remote.schoolIdentity) {
      throw StateError('Connect this school administrator Firebase account first.');
    }
    final centralConnection = await CentralSchoolCloud.saved();
    if(centralConnection['managed']==true){return ManagedSchoolSession.call(action=='license/activate'?'managed/licence/activate':'managed/session',action=='license/activate'?{'key':body['key']}:{});}
    if (centralConnection.isNotEmpty) {
      final cloud = CentralSchoolCloud(endpoint:centralConnection['endpoint']);
      try { return await cloud.api({'action':action,'schoolId':centralConnection['schoolId'],
        for (final k in ['key','version','noticeId','message','deviceFingerprint','studentCount','teacherCount','studentAppUsers','onlineStudents','onlineTeachers']) if (body.containsKey(k)) k:body[k]},
        token:await WindowsFirebaseRemote.freshIdToken()); }
      finally {cloud.close();}
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
    if (d is! Map || response.statusCode >= 400 || d['success'] != true || d['projectId'] != remote.schoolIdentity)
      throw StateError(d is Map
          ? d['message']?.toString() ?? 'Platform unavailable'
          : 'Platform unavailable');
    if({'school/bind','school/heartbeat','installation/status','license/activate'}.contains(action)) {
      final hash=action=='license/activate'
          ? sha256.convert(utf8.encode(body['key'].toString().trim().toUpperCase())).toString()
          : d['licenseHash']?.toString();
      final central=SparkLicenseClient();
      try {return {...Map<String,dynamic>.from(d), ...await central.schoolStatus(remote.schoolIdentity,licenseHash:hash)};}
      finally {central.close();}
    }
    return Map<String, dynamic>.from(d);
  }

  Future<void> initialize() async {
    if (_id.isNotEmpty) return;
    final managed = await CentralSchoolCloud.saved();
    if (managed['managed'] == true) {
      _id = 'managed_${managed['uid']}';
      // The cloud engine owns managed background verification; do not create
      // a second trial or replace verified access because a network call fails.
      return;
    }
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
    if (_cacheProject.isNotEmpty && active.schoolIdentity != _cacheProject) {
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
        expiresAt: end, activated:data['activated']==true);
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
      if((await CentralSchoolCloud.saved())['managed']==true)return;
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
      if (_activeLicenseHash.isNotEmpty && _licenseProject.isNotEmpty && remote.schoolIdentity == _licenseProject) {
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
      if (_cacheProject.isNotEmpty && remote.schoolIdentity != _cacheProject) {
        _verifiedAt = null;
        state.value = WindowsLicenseState(
            allowed: false, status: 'unbound', expiresAt: DateTime.now());
      }
      final links = await WindowsExternalConnections.load();
      final script = await WindowsExternalConnections.googleScriptUrl();
      if (remote.authenticated &&
          script.isNotEmpty &&
          (_boundProject != remote.schoolIdentity || _boundScript != script)) {
        final nameDoc = await FirebaseFirestore.instance
            .collection('school_config')
            .doc('school_profile_cache')
            .get();
        final bound = await call('school/bind', {
          'deviceFingerprint':_fingerprint,
          'projectId': remote.schoolIdentity,
          'googleScriptUrl': script,
          'schoolIdToken': await WindowsFirebaseRemote.freshIdToken(),
          'schoolName': nameDoc.data()?['schoolName'] ?? remote.schoolIdentity,
          'version': version
        });
        if (_boundProject != remote.schoolIdentity) _sentNotices.clear();
        _boundProject = remote.schoolIdentity;
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
          remote.schoolIdentity != heartbeat['schoolId'])
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
      try {await _secure.write(key: 'vs_license_last_seen', value: _lastSeen!.toIso8601String());}
      finally {_running = false;}
    }
  }

  Future<void> _relayNotices() async {
    if((await CentralSchoolCloud.saved())['managed']==true)return; // Managed notices are read from the school dashboard; do not pretend a session check sends FCM.
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

  /// One durable local transaction includes the notice and the tracked outbox.
  /// Never await network delivery from the user action.
  Future<WindowsNoticeDelivery> publishNotice(String id, Map<String, dynamic> data) async {
    final watch = Stopwatch()..start();
    final db = FirebaseFirestore.instance, origin = FirebaseFirestore.instance.activeProfileId;
    final saved = await CentralSchoolCloud.saved();
    if (origin != db.activeProfileId) throw StateError('School changed. Reopen notices.');
    if (saved['managed'] == true &&
        (db.activeProfileIdentity['schoolSyncId'] != saved['schoolId'] || !await db.localPersistenceEnabled())) {
      throw StateError('Current school durable notice storage is unavailable.');
    }
    await db.collection('school_notices').doc(id).set({...data,
      if(saved['managed']==true) 'schoolId':saved['schoolId'],
      'deliveryStatus':saved['managed']==true?'sync_pending':'notification_pending'});
    watch.stop();
    WindowsSyncEngine.instance.recordLocalSave('notice', watch.elapsedMicroseconds);
    WindowsSyncEngine.instance.scheduleSoon();
    return const WindowsNoticeDelivery(notificationSent:false, recipients:0,
      info:'Saved durably on this PC. Background synchronization queued.');
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
    final boundProject = remote.schoolIdentity;
    final data =
        await call('license/activate', {'key': normalized});
    final current = await WindowsFirebaseRemote.status();
    if (current.authenticated &&
        current.schoolIdentity.isNotEmpty &&
        current.schoolIdentity != boundProject) {
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

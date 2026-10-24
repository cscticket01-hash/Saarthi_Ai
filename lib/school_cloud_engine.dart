import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'windows_connect/central_school_cloud.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_secure_storage.dart';
import 'windows_sync_engine.dart';
import 'windows_platform_client.dart';
import 'windows_service_status.dart';
import 'school_cloud_state.dart';
export 'school_cloud_state.dart';

/// Restores only server-authenticated, encrypted, same-school access. Existing
/// outboxes/media/conflict handling stay in WindowsSyncEngine; no second queue.
class SchoolCloudEngine extends ChangeNotifier {
  SchoolCloudEngine({
    Future<Map<String, dynamic>> Function()? readIdentity,
    Future<Map<String, dynamic>> Function()? verify,
    Future<void> Function(
      Map<String, dynamic> identity,
      Map<String, dynamic> access,
    )?
    persist,
    Future<void> Function()? activateLocal,
    Future<Map<String, dynamic>?> Function()? legacyAccess,
    Future<void> Function(Map<String, dynamic>, int)? touchClock,
    DateTime Function()? clock,
    Duration Function()? elapsed,
    Future<bool> Function(Map<String,dynamic>, Map<String,dynamic>, int)? verifyDeviceLease,
  }) : _elapsed = elapsed ?? _monotonicClock(),
       _useServerClock = clock == null || elapsed != null,
       _deviceVerifier = verifyDeviceLease ?? _verifyDeviceLease,
       _read = readIdentity ?? CentralSchoolCloud.saved,
       _verify = verify ?? (() => ManagedSchoolSession.call('managed/session')),
       _persist =
           persist ??
           ((identity, access) => CentralSchoolCloud.updateSession(
             identity['schoolId'],
             {'verifiedAccess': access,
              if(access['deviceEnforced']==true || identity['deviceEnforced']==true)'deviceEnforced':true},
             expectedUid: identity['uid'],
           )),
       _activate =
           activateLocal ??
           (() => WindowsSyncEngine.instance.activateCurrentConnections(
             allowPairing: false,
           )),
       _legacy = legacyAccess ?? _legacyCache,
       _clock = clock ?? DateTime.now,
       _touch =
           touchClock ??
           ((identity, time) => CentralSchoolCloud.updateSession(
             identity['schoolId'],
             {'lastLocalSeenAt': time},
             expectedUid: identity['uid'],
           ));
  static final instance = SchoolCloudEngine();
  final Future<Map<String, dynamic>> Function() _read, _verify;
  final Future<void> Function(Map<String, dynamic>, Map<String, dynamic>)
  _persist;
  final Future<void> Function() _activate;
  final Future<Map<String, dynamic>?> Function() _legacy;
  final DateTime Function() _clock;
  final Duration Function() _elapsed;
  final bool _useServerClock;
  int? _verifiedServerTime;
  Duration _verifiedElapsed = Duration.zero;
  Future<void>? _verificationTask;
  static Duration Function() _monotonicClock() {
    final watch = Stopwatch()..start();
    return () => watch.elapsed;
  }
  int get _accessNow => _verifiedServerTime == null
      ? _clock().millisecondsSinceEpoch
      : _verifiedServerTime! + (_elapsed() - _verifiedElapsed).inMilliseconds;
  final Future<bool> Function(Map<String,dynamic>,Map<String,dynamic>,int) _deviceVerifier;
  int _deviceLeaseExpiry=0;
  bool _deviceEnforcedSeen=false;
  static const deviceEnforcementRequired=bool.fromEnvironment('SAARTHI_DEVICE_ENFORCEMENT_REQUIRED');
  bool get _requiresDeviceProof => deviceEnforcementRequired || _deviceEnforcedSeen || identity?['deviceEnforced']==true || access?['deviceEnforced']==true;
  static Future<bool> _verifyDeviceLease(Map<String,dynamic> identity,Map<String,dynamic> access,int now) async {
    final token=access['offlineLease'];
    if(token is! String || access['device'] is! Map || access['device']['authorizedAt'] is! int ||
        identity['endpoint'] is! String || identity['uid'] is! String)return false;
    return ManagedDeviceCredentials.verifyLease(token,schoolId:identity['schoolId'],uid:identity['uid'],
      deviceIdentity:await ManagedDeviceCredentials.identity(accountUid:identity['uid'],endpoint:identity['endpoint']),
      generationHash:await ManagedDeviceCredentials.generationHash(identity['schoolId'],accountUid:identity['uid'],
        endpoint:identity['endpoint'],authorizedAt:(access['device'] as Map)['authorizedAt'] as int),now:now);
  }
  Future<void> _refreshDeviceProof() async {
    _deviceLeaseExpiry=0;
    if(!_requiresDeviceProof || identity==null || access==null)return;
    final now=_accessNow;
    if(await _deviceVerifier(identity!,access!,now)) {
      final payload=jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize((access!['offlineLease'] as String).split('.').first))));
      _deviceLeaseExpiry=(payload['expiresAt'] as num).toInt();
    }
  }
  final Future<void> Function(Map<String, dynamic>, int) _touch;
  Map<String, dynamic>? identity, access;
  SchoolCloudState state = SchoolCloudState.authRequired;
  String? error;
  bool restoring = true,
      _disposed = false,
      _verifying = false,
      _localReady = false;
  bool get localReady => _localReady;
  int _generation = 0;
  Timer? _retry;
  DateTime? _lastVerifyAttempt;
  int _failures = 0;
  DateTime? _lastPresence;
  bool _presenceRunning=false;
  bool get hasIdentity => identity != null;
  bool get canOpen => _localReady && _leaseUsable;
  bool get accessExpired =>
      (access?['expiresAt'] as num? ?? 0) <= _accessNow;
  bool get trialAvailable => access?['status'] == 'trial' &&
      access?['allowed'] == true && !accessExpired && identity != null &&
      sameIdentity(access!, identity!);
  /// Skip licence entry only within this authenticated school's original trial.
  Future<bool> continueTrial() async {
    if (access?['status'] != 'trial') return false;
    if (!canOpen) await verify();
    return access?['status'] == 'trial' && canOpen;
  }
  String get accessProblem {
    if (error != null) return error!;
    if (accessExpired) return 'The school trial or licence has expired.';
    if (_requiresDeviceProof && _deviceLeaseExpiry <= _accessNow)
      return 'PC authorization could not be verified. Sign in again with this school account.';
    if (_verifiedServerTime == null &&
        ((access?['serverTime'] as num? ?? 0) > _accessNow + 300000 ||
         (identity?['lastLocalSeenAt'] as num? ?? 0) > _accessNow + 300000))
      return 'The PC date/time differs from saved school verification. Retry online verification.';
    return 'School access could not be verified. Sign in again with this school account.';
  }
  bool get _leaseUsable =>
      (!_requiresDeviceProof || _deviceLeaseExpiry > _accessNow) &&
      access != null &&
      sameIdentity(access!, identity!) &&
      access!['allowed'] == true &&
      (access!['status'] == 'trial' || access!['activated'] == true) &&
      (access!['expiresAt'] as num? ?? 0) > _accessNow &&
      _accessNow - (access!['serverTime'] as num? ?? 0) <
          (access!['status'] == 'trial' ? const Duration(days:5) : const Duration(hours:72)).inMilliseconds &&
      (access!['serverTime'] as num? ?? 0) <=
          _accessNow + 300000 &&
      (_verifiedServerTime != null || (identity!['lastLocalSeenAt'] as num? ?? 0) <=
          _accessNow + 300000);
  static bool sameIdentity(Map<String, dynamic> a, Map<String, dynamic> b) =>
      a['schoolId'] == b['schoolId'] &&
      a['uid'] == b['uid'] &&
      a['projectId'] == b['projectId'] &&
      validSchoolId(a['schoolId']?.toString() ?? '') &&
      a['uid'] is String &&
      (a['uid'] as String).isNotEmpty;
  static Future<Map<String, dynamic>?> _legacyCache() async {
    final raw = await const WindowsSecureStorage().read(
      key: 'vs_license_cache',
    );
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  void _notify() {
    if (_disposed) return;
    if (access != null &&
        identity != null &&
        sameIdentity(access!, identity!)) {
      WindowsPlatformClient.instance.state.value = WindowsLicenseState(
        allowed: canOpen,
        status: access!['status']?.toString() ?? 'expired',
        activated: access!['activated'] == true,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          (access!['expiresAt'] as num? ?? 0).toInt(),
        ),
      );
    }
    notifyListeners();
  }

  Future<void> restore() async {
    final generation = ++_generation;
    _retry?.cancel();
    restoring = true;
    _localReady = false;
    identity = null;
    access = null;
    _verifiedServerTime = null;
    _deviceLeaseExpiry=0;
    _deviceEnforcedSeen=false;
    error = null;
    _notify();
    try {
      final saved = await _read();
      if (generation != _generation || _disposed) return;
      if (saved['managed'] == true) {
        identity = Map<String, dynamic>.from(saved);
        _deviceEnforcedSeen=saved['deviceEnforced']==true;
        final cached = saved['verifiedAccess'] is Map
            ? Map<String, dynamic>.from(saved['verifiedAccess'])
            : await _legacy();
        if (cached != null && sameIdentity(cached, saved)) {
          access = cached;
          _deviceEnforcedSeen = _deviceEnforcedSeen || cached['deviceEnforced']==true;
        }
        await _refreshDeviceProof();
        if(generation != _generation || _disposed)return;
        if (_leaseUsable) await _checkpoint(generation);
        await _activate(); // Selects this tenant's local cache, never refreshes a token.
        if (generation != _generation || _disposed) return;
        final selectedIdentity = await _read();
        if (!sameIdentity(selectedIdentity, identity!))
          throw StateError('School changed while selecting local data.');
        _localReady = true;
        state = canOpen
            ? SchoolCloudState.localReady
            : SchoolCloudState.authRequired;
      } else
        state = SchoolCloudState.authRequired;
    } catch (e) {
      if (generation != _generation || _disposed) return;
      error = 'Saved school connection could not be read. Retry; existing data is retained.';
      state = SchoolCloudState.syncError;
    }
    if (generation != _generation || _disposed) return;
    restoring = false;
    _notify();
    if (identity != null) {
      unawaited(verify());
      _retry = Timer.periodic(const Duration(seconds: 60), (_) {
        _notify();
        final due = Duration(minutes: _failures == 0 ? 15 : (1 << _failures.clamp(0,5)));
        if (_lastVerifyAttempt == null || _clock().difference(_lastVerifyAttempt!) >= due) unawaited(verify());
        else if(canOpen && !_presenceRunning && (_lastPresence==null || _clock().difference(_lastPresence!)>=const Duration(seconds:60))) {
          _presenceRunning=true;_lastPresence=_clock();
          unawaited(_keepPresence().whenComplete(()=>_presenceRunning=false));
        }
      });
    }
  }

  Future<void> _keepPresence() async {
    final token=access?['presenceToken'];
    if(token is! String || token.isEmpty){await verify();return;} // Older broker compatibility.
    final origin=identity;
    if(origin==null)return;
    try {await ManagedSchoolSession.callForSchool(origin['schoolId'],'managed/presence',{'presenceToken':token});}
    catch(_){await verify();}
  }

  Future<void> _checkpoint(int generation) async {
    final origin = identity, time = _clock().millisecondsSinceEpoch;
    if (origin == null || generation != _generation || _disposed) return;
    await _touch(origin, time);
    if (generation == _generation && !_disposed)
      identity = {...origin, 'lastLocalSeenAt': time};
  }

  Future<void> verify() => _verificationTask ??=
      _verifyAccess().whenComplete(() => _verificationTask = null);

  Future<void> _verifyAccess() async {
    if (_verifying || identity == null || _disposed) return;
    _verifying = true;
    _lastVerifyAttempt = _clock();
    final origin = Map<String, dynamic>.from(identity!),
        generation = _generation;
    bool current() => generation == _generation && !_disposed;
    try {
      final result = await _verify();
      if (!current()) return;
      if (!sameIdentity(result, origin) ||
          result['success'] != true ||
          result['expiresAt'] is! num ||
          result['serverTime'] is! num)
        throw StateError('School verification returned a different identity.');
      final latest = await _read();
      if (!current() || !sameIdentity(latest, origin)) return;
      final snapshot = Map<String, dynamic>.from(result);
      _deviceEnforcedSeen = _deviceEnforcedSeen || snapshot['deviceEnforced']==true;
      if(_deviceEnforcedSeen && snapshot['deviceEnforced']!=true)
        throw StateError('Device authorization downgrade rejected.');
      await _persist(origin, snapshot);
      if (!current()) return;
      final stored = await _read();
      if (!current() || !sameIdentity(stored, origin)) return;
      identity=Map<String,dynamic>.from(stored);
      _deviceEnforcedSeen = _deviceEnforcedSeen || stored['deviceEnforced']==true;
      // A fresh authenticated response is authority; a future-dated cached
      // snapshot cannot override it after the PC clock has been corrected.
      access = snapshot;
      if (_useServerClock) {
        _verifiedServerTime = (snapshot['serverTime'] as num).toInt();
        _verifiedElapsed = _elapsed();
      }
      await _refreshDeviceProof();
      if(!current())return;
      _failures = 0;
      error = null;
      state = canOpen
          ? SchoolCloudState.localReady
          : SchoolCloudState.authRequired;
    } catch (e) {
      _failures++;
      if (!current()) return;
      if (e is CentralCloudException && e.authoritativeAccessDenial) {
        final denied = {
          'schoolId': origin['schoolId'],
          'uid': origin['uid'],
          'projectId': origin['projectId'],
          'allowed': false,
          'activated': false,
          'expiresAt': 0,
          'status': e.status == 403 ? 'blocked' : 'auth_required',
          'serverTime': _clock().millisecondsSinceEpoch,
        };
        access = denied;
        _deviceLeaseExpiry=0;
        state = SchoolCloudState.authRequired;
        try {
          await _persist(origin, denied);
        } catch (_) {}
      } else
        state = SchoolCloudState.offline;
      error = 'Cloud verification unavailable. Local data and pending sync are retained.';
    } finally {
      _verifying = false;
      if (current()) {
        if (canOpen) {
          try {
            await _checkpoint(generation);
          } catch (_) {}
        }
        _notify();
      }
    }
  }

  SchoolCloudState get displayState {
    if (state == SchoolCloudState.offline ||
        state == SchoolCloudState.authRequired ||
        state == SchoolCloudState.syncError)
      return state;
    final sync = WindowsSyncEngine.instance.state.value;
    if (sync != SchoolCloudState.localReady) return sync;
    final drive = WindowsServiceStatus.instance.health(
      WindowsServiceType.googleDrive,
    );
    if (drive.state == WindowsHealthState.unhealthy)
      return SchoolCloudState.driveDisconnected;
    return state;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _retry?.cancel();
    super.dispose();
  }
}

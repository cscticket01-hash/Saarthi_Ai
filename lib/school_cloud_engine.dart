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
  SchoolCloudEngine({Future<Map<String,dynamic>> Function()? readIdentity,
    Future<Map<String,dynamic>> Function()? verify,
    Future<void> Function(Map<String,dynamic> identity, Map<String,dynamic> access)? persist,
    Future<void> Function()? activateLocal,
    Future<Map<String,dynamic>?> Function()? legacyAccess,
    DateTime Function()? clock})
    : _read = readIdentity ?? CentralSchoolCloud.saved,
      _verify = verify ?? (() => ManagedSchoolSession.call('managed/session')),
      _persist = persist ?? ((identity,access) => CentralSchoolCloud.updateSession(
        identity['schoolId'], {'verifiedAccess':access},expectedUid:identity['uid'])),
      _activate = activateLocal ?? (() => WindowsSyncEngine.instance.activateCurrentConnections(allowPairing:false)),
      _legacy = legacyAccess ?? _legacyCache, _clock = clock ?? DateTime.now;
  static final instance = SchoolCloudEngine();
  final Future<Map<String,dynamic>> Function() _read, _verify;
  final Future<void> Function(Map<String,dynamic>,Map<String,dynamic>) _persist;
  final Future<void> Function() _activate;
  final Future<Map<String,dynamic>?> Function() _legacy;
  final DateTime Function() _clock;
  Map<String,dynamic>? identity, access;
  SchoolCloudState state = SchoolCloudState.authRequired;
  String? error;
  bool restoring = true, _disposed = false, _verifying = false;
  int _generation = 0;
  Timer? _retry;
  bool get hasIdentity => identity != null;
  bool get canOpen => access != null && sameIdentity(access!,identity!) &&
    access!['allowed'] == true &&
    (access!['status'] == 'trial' || access!['activated'] == true) &&
    (access!['expiresAt'] as num? ?? 0) > _clock().millisecondsSinceEpoch &&
    (access!['serverTime'] as num? ?? 0) <= _clock().millisecondsSinceEpoch + 300000;
  static bool sameIdentity(Map<String,dynamic> a,Map<String,dynamic> b) =>
    a['schoolId'] == b['schoolId'] && a['uid'] == b['uid'] &&
    a['projectId'] == b['projectId'] && validSchoolId(a['schoolId']?.toString() ?? '') &&
    a['uid'] is String && (a['uid'] as String).isNotEmpty;
  static Future<Map<String,dynamic>?> _legacyCache() async {
    final raw=await const WindowsSecureStorage().read(key:'vs_license_cache');
    if(raw==null)return null;
    try{return Map<String,dynamic>.from(jsonDecode(raw));}catch(_){return null;}
  }
  void _notify(){
    if(_disposed)return;
    if(access!=null && identity!=null && sameIdentity(access!,identity!)) {
      WindowsPlatformClient.instance.state.value=WindowsLicenseState(
        allowed:canOpen,status:access!['status']?.toString()??'expired',
        activated:access!['activated']==true,
        expiresAt:DateTime.fromMillisecondsSinceEpoch((access!['expiresAt'] as num? ?? 0).toInt()));
    }
    notifyListeners();
  }
  Future<void> restore() async {
    final generation=++_generation;
    _retry?.cancel(); restoring=true; identity=null;access=null;error=null;_notify();
    try {
      final saved=await _read();
      if(generation!=_generation||_disposed)return;
      if(saved['managed']==true) {
        identity=Map<String,dynamic>.from(saved);
        final cached=saved['verifiedAccess'] is Map
          ? Map<String,dynamic>.from(saved['verifiedAccess']) : await _legacy();
        if(cached!=null && sameIdentity(cached,saved))access=cached;
        await _activate(); // Selects this tenant's local cache, never refreshes a token.
        if(generation!=_generation||_disposed)return;
        state=canOpen?SchoolCloudState.localReady:SchoolCloudState.authRequired;
      }else state=SchoolCloudState.authRequired;
    }catch(e){if(generation!=_generation||_disposed)return;error='Saved school connection could not be read. Retry; existing data is retained.';state=SchoolCloudState.syncError;}
    if(generation!=_generation||_disposed)return;
    restoring=false;_notify();
    if(identity!=null) {
      unawaited(verify());
      _retry=Timer.periodic(const Duration(seconds:60),(_){_notify();unawaited(verify());});
    }
  }
  Future<void> verify() async {
    if(_verifying||identity==null||_disposed)return;
    _verifying=true;
    final origin=Map<String,dynamic>.from(identity!),generation=_generation;
    bool current()=>generation==_generation&&!_disposed;
    try {
      final result=await _verify();
      if(!current())return;
      if(!sameIdentity(result,origin)||result['success']!=true || result['expiresAt'] is! num || result['serverTime'] is! num)throw StateError('School verification returned a different identity.');
      final latest=await _read();
      if(!current()||!sameIdentity(latest,origin))return;
      final snapshot=Map<String,dynamic>.from(result);
      await _persist(origin,snapshot);
      if(!current())return;
      access=snapshot;error=null;
      state=canOpen?SchoolCloudState.localReady:SchoolCloudState.authRequired;
    }catch(e){
      if(!current())return;
      if(e is CentralCloudException && e.authoritativeAccessDenial){
        final denied={'schoolId':origin['schoolId'],'uid':origin['uid'],'projectId':origin['projectId'],'allowed':false,'activated':false,'expiresAt':0,
          'status':e.status==403?'blocked':'auth_required','serverTime':_clock().millisecondsSinceEpoch};
        access=denied;state=SchoolCloudState.authRequired;
        try{await _persist(origin,denied);}catch(_){}
      }else state=SchoolCloudState.offline;
      error='Cloud verification unavailable. Local data and pending sync are retained.';
    }finally{_verifying=false;if(current())_notify();}
  }
  SchoolCloudState get displayState {
    if(state==SchoolCloudState.offline||state==SchoolCloudState.authRequired||state==SchoolCloudState.syncError)return state;
    final sync=WindowsSyncEngine.instance.state.value;
    if(sync!=SchoolCloudState.localReady)return sync;
    final drive=WindowsServiceStatus.instance.health(WindowsServiceType.googleDrive);
    if(drive.state==WindowsHealthState.unhealthy)return SchoolCloudState.driveDisconnected;
    return state;
  }
  @override void dispose(){_disposed=true;_generation++;_retry?.cancel();super.dispose();}
}

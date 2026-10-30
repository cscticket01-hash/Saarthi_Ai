import '../windows_sync_evidence.dart';
import '../windows_appearance.dart';
import '../windows_theme_presets.dart';
import '../windows_local_session.dart';
import 'dart:async';
import '../windows_profile_image_policy.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../windows_secure_storage.dart';
import '../platform/platform_config.dart';
import 'central_school_cloud.dart';
import 'managed_device_credentials.dart';
import 'windows_network_connection.dart';
export 'managed_device_credentials.dart';
enum ThemeUnlockOutcome { applied, unchanged, deferred, interrupted, notManaged }
class ManagedSchoolSession {
  static http.Client? _transport;
  static String? _transportScope;
  static http.Client _transportFor(Map<String,dynamic> saved) {
    final scope=jsonEncode([saved['endpoint'],saved['schoolId'],saved['uid']]);
    if(_transport==null||_transportScope!=scope) {
      _transport?.close();_transport=ManagedDeviceClient(http.Client(), saved['endpoint'].toString(),accountUid:saved['uid'].toString());_transportScope=scope;
    }
    return _transport!;
  }
  static const enabled=bool.fromEnvironment('SAARTHI_MANAGED_ACCOUNTS');
  static void verifyBuildEndpoint(String endpoint, {String configured=CentralSchoolCloud.apiUrl}) {
    const isolated='https://saarthi-sync-v2-test.onrender.com/school-cloud';
    if(configured==isolated && endpoint!=isolated)throw CentralCloudException(409,'school_cloud',
      'This isolated TEST app cannot access the saved original-school server. Local data and pending records are retained. Use the original-school app or an isolated TEST profile.',
      diagnosticCode:'TEST_ENVIRONMENT_MISMATCH');
  }

  static final changed=ValueNotifier<int>(0);
  static final activeTransfers=ValueNotifier<int>(0);
  /// The shared review/web login must not call dart:io platform APIs.
  /// Metadata changes no credential, registry admission or authorization rule.
  static Map<String,dynamic> deviceRegistrationBody({bool web=kIsWeb,
      String Function()? hostname}) {
    if(web) return {'action':'managed/device/register','deviceManagementProtocol':2,'deviceName':'Web browser','deviceOs':'Web','type':'pc'};
    String name;
    try { name=(hostname ?? (()=>Platform.localHostname))(); } catch (_) { name='Windows PC'; }
    return {'action':'managed/device/register','deviceManagementProtocol':2,'deviceName':name.isNotEmpty&&name.length<=100?name:'Windows PC','deviceOs':'Windows','type':'pc'};
  }
  static Future<Map<String,dynamic>> call(String action,[Map<String,dynamic> body=const {}]) => callForSchool(null, action, body);
  static Future<Map<String,dynamic>> callForSchool(String? expectedSchoolId, String action, Map<String,dynamic> body) async {
    final saved=await CentralSchoolCloud.saved();verifyBuildEndpoint(saved['endpoint']?.toString()??'');if(saved['managed']!=true)throw StateError('Managed school login required');
    if(expectedSchoolId != null && saved['schoolId'] != expectedSchoolId) throw StateError('School changed before operation.');
    final cloud=CentralSchoolCloud(endpoint:saved['endpoint'],expectedSchoolId:saved['schoolId'],
      client:_transportFor(saved),closeClient:false);
    try {
      final metadata = action=='managed/session' || action=='managed/device/list'
          ? <String,dynamic>{...(deviceRegistrationBody()..remove('action')),
              ...await WindowsNetworkConnection.reportedMetadata()}
          : const <String,dynamic>{};
      final token=await CentralSchoolCloud.firebaseToken();
      final visibleTransfer=action!='managed/events' && action!='managed/theme/state' && action!='managed/theme/unlock' && action!='managed/repair-knowledge/pull'; // A quiet event subscription is not data transfer.
      if(visibleTransfer)activeTransfers.value++;
      final dataTransfer=WindowsSyncEvidence.dataAction(action);
      final dataSchool=saved['schoolId'].toString();
      if(dataTransfer){WindowsSyncEvidence.enter(dataSchool,'cloud');if(action.startsWith('managed/file/'))WindowsSyncEvidence.enter(dataSchool,'drive');}
      late final Map<String,dynamic> result;
      try {
        result=await cloud.api({...metadata,'action':action,...body,'schoolId':saved['schoolId']},token:token);
      } finally {if(visibleTransfer)activeTransfers.value--;if(dataTransfer){WindowsSyncEvidence.leave(dataSchool,'cloud');if(action.startsWith('managed/file/'))WindowsSyncEvidence.leave(dataSchool,'drive');}}
      final currentIdentity = await CentralSchoolCloud.saved();
      if (currentIdentity['schoolId'] != saved['schoolId'] || currentIdentity['uid'] != saved['uid']) {
        throw StateError('School changed during operation. Retry login.');
      }
      if (action == 'managed/session') {
        await CentralSchoolCloud.updateSession(saved['schoolId'],
          {...managedSessionConfiguration(result, saved['schoolId'], saved['uid']), 'verifiedAccess':result},
          expectedUid: saved['uid']);
      }
      if (action == 'managed/storage/check' || action == 'managed/storage/connect') {
        final current = await CentralSchoolCloud.saved();
        if (current['schoolId'] != saved['schoolId'] || current['uid'] != saved['uid']) {
          throw StateError('School changed during storage verification. Retry the current school.');
        }
        verifyStorageResponse(result, saved['schoolId'].toString(),
            scriptUrl: action == 'managed/storage/connect' ? body['scriptUrl']?.toString() : null);
      }
      return result;
    } catch (error) {
      // Revision, quota and transport failures do not invalidate authentication.
      if (error is CentralCloudException &&
          (error.status == 401 || error.invalidRefresh)) {
        CentralSchoolCloud.clearFirebaseToken();
      }
      rethrow;
    } finally {cloud.close();}
  }
  /// A successful HTTP response alone does not mean this school's storage is ready.
  static void verifyStorageResponse(Map<String,dynamic> result, String schoolId, {String? scriptUrl}) {
    if (result['success'] != true || result['storageReady'] != true || result['schoolId'] != schoolId) {
      throw StateError('The selected school storage is not ready or belongs to another school.');
    }
    if (scriptUrl != null && result['scriptUrl'] != scriptUrl.trim()) {
      throw StateError('Storage verification returned a different deployment URL.');
    }
  }
  static Future<Map<String,dynamic>> login(String email,String password,
      {http.Client? client, String endpoint = CentralSchoolCloud.apiUrl}) async {
    verifyBuildEndpoint(endpoint);
    CentralSchoolCloud.clearFirebaseToken();
    if(!CentralSchoolCloud.validEndpoint(endpoint))throw StateError('Central school server is not configured');
    final cloud=CentralSchoolCloud(client:client,endpoint:endpoint);
    try {
      final auth=await cloud.send('POST',Uri.https('identitytoolkit.googleapis.com','/v1/accounts:signInWithPassword',{'key':platformApiKey}),body:{'email':email.trim(),'password':password,'returnSecureToken':true});
      if(auth['idToken'] is! String||auth['refreshToken'] is! String||auth['localId'] is! String)throw StateError('School login failed');
      await ManagedDeviceCredentials.proof(accountUid:auth['localId'],endpoint:endpoint);
      final authenticated=CentralSchoolCloud(client:ManagedDeviceClient(cloud.client,endpoint,accountUid:auth['localId']),endpoint:endpoint,closeClient:false);
      try {
        final registration = {...deviceRegistrationBody(),
          ...await WindowsNetworkConnection.reportedMetadata()};
        verifyDeviceRegistration(await authenticated.api(registration,token:auth['idToken']), await ManagedDeviceCredentials.identity(accountUid:auth['localId'],endpoint:endpoint));
      } on CentralCloudException catch(e) {
        // Compatibility only when this feature is explicitly inactive server-side.
        if(e.status==401 && e.diagnosticCode=='REAUTHORIZATION_REQUIRES_NEW_CREDENTIAL') {
          // This path is reached only after a fresh Firebase password login.
          await ManagedDeviceCredentials.rotateRevokedCredential(accountUid:auth['localId'],endpoint:endpoint);
          verifyDeviceRegistration(await authenticated.api(registration,token:auth['idToken']), await ManagedDeviceCredentials.identity(accountUid:auth['localId'],endpoint:endpoint));
        } else if(e.status!=503 || e.diagnosticCode!='DEVICE_ROLLOUT_DISABLED') rethrow;
      }
      final session=await authenticated.api({'action':'managed/session','appearance':true},token:auth['idToken']);
      if(session['uid']!=auth['localId']||!validSchoolId(session['schoolId']?.toString()??''))throw StateError('School account mapping is invalid');
      final configuration = managedSessionConfiguration(session, session['schoolId'], auth['localId']);
      Map<String,dynamic> googleProfile={};
      try {
        final lookup=await cloud.send('POST',Uri.https('identitytoolkit.googleapis.com','/v1/accounts:lookup',{'key':platformApiKey}),body:{'idToken':auth['idToken']});
        final accounts=lookup['users'] as List? ?? [];
        if(accounts.length==1 && accounts.first['localId']==auth['localId'] && verifiedGoogleAccountPhoto(accounts.first as Map).isNotEmpty) {
          googleProfile={'photoUrl':verifiedGoogleAccountPhoto(accounts.first as Map),'displayName':accounts.first['displayName']??''};
        }
      }catch(_){}
      final old=await CentralSchoolCloud.saved();
      if(old.isNotEmpty&&old['managed']!=true)await const WindowsSecureStorage().write(key:'vidya_saarthi_legacy_cloud_preserved',value:jsonEncode(old));
      await const WindowsSecureStorage().write(key:CentralSchoolCloud.key,value:jsonEncode({'managed':true,'endpoint':endpoint,'projectId':platformProjectId,'schoolId':session['schoolId'],'uid':auth['localId'],'email':auth['email']??email.trim(),'firebaseRefreshToken':auth['refreshToken'],'folderId':'managed',...configuration,...retainedAdminGoogleProfile(previous:old,verified:googleProfile,uid:auth['localId'],schoolId:session['schoolId'],verifiedEmail:auth['email']?.toString()??email.trim()),'verifiedAccess':session}));
      await const WindowsSecureStorage().write(key:'vidya_saarthi_managed_required',value:'true');
      startAppearanceControl();
      changed.value++;return session;
    }finally{cloud.close();}
  }
  @visibleForTesting
  static Future<Map<String,dynamic>> Function(String schoolId, bool locked)? appearanceRequestForTesting;
  @visibleForTesting
  static Future<Map<String,dynamic>> Function(String schoolId)? appearanceUnlockRequestForTesting;
  static int _appearanceEpoch=0, _appearanceAttempt=0;
  static Timer? _appearanceTimer;
  static bool _appearanceLocked = true;
  static bool _appearanceNeedsReport = true;
  static Future<void> _appearanceQueue = Future<void>.value();
  static void startAppearanceControl() {
    if(kIsWeb || !enabled)return;
    WindowsLocalSession.onLockChanged = (locked) => reportAppearanceLock(locked);
    _appearanceTimer ??= Timer.periodic(const Duration(seconds:30), (_) {
      if(_appearanceLocked || _appearanceNeedsReport)unawaited(reportAppearanceLock(_appearanceLocked));
    });
    unawaited(reportAppearanceLock(WindowsLocalSession.loggedOut));
  }
  static Future<void> reportAppearanceLock(bool locked) {
    if(kIsWeb || (!enabled && appearanceRequestForTesting==null))return Future<void>.value();
    if(locked&&!_appearanceLocked)_appearanceEpoch++;
    if(_appearanceLocked!=locked)_appearanceNeedsReport=true;
    _appearanceLocked=locked;
    final next=_appearanceQueue.then((_) async {
      // Coalesce queued heartbeats; never replay a stale unlocked/locked state.
      if(locked!=_appearanceLocked)return;
      try {
        final before=await CentralSchoolCloud.saved();
        if(before['managed']!=true)return;
        await (appearanceRequestForTesting?.call(before['schoolId'].toString(),locked) ?? callForSchool(before['schoolId'], 'managed/theme/state', {'locked':locked}));
        if(locked==_appearanceLocked)_appearanceNeedsReport=false;
      } catch (_) {/* Offline/unknown PCs never count as confirmed locked. */}
    });
    _appearanceQueue=next.catchError((Object _) {});
    return next.timeout(const Duration(seconds:4),onTimeout:(){});
  }
  /// Invoked after a verified App Lock password, before the dashboard opens.
  /// Independent of heartbeat queues: an old/stalled report cannot discard it.
  static Future<ThemeUnlockOutcome> refreshAppearanceAtUnlock({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (kIsWeb ||
        (!enabled &&
            appearanceRequestForTesting == null &&
            appearanceUnlockRequestForTesting == null))
      return ThemeUnlockOutcome.notManaged;
    final attempt = ++_appearanceAttempt, epoch = _appearanceEpoch;
    _appearanceLocked = false;
    try {
      final before = await CentralSchoolCloud.saved();
      if (before['managed'] != true) return ThemeUnlockOutcome.notManaged;
      final request =
          appearanceUnlockRequestForTesting?.call(
            before['schoolId'].toString(),
          ) ??
          appearanceRequestForTesting?.call(
            before['schoolId'].toString(),
            false,
          ) ??
          callForSchool(before['schoolId'], 'managed/theme/unlock', {});
      final result = await request.timeout(timeout);
      final after = await CentralSchoolCloud.saved();
      if (attempt != _appearanceAttempt ||
          epoch != _appearanceEpoch ||
          _appearanceLocked ||
          before['uid'] != after['uid'] ||
          before['schoolId'] != after['schoolId'] ||
          before['endpoint'] != after['endpoint'])
        return ThemeUnlockOutcome.interrupted;
      final theme = result['windowsTheme'];
      if (result['schoolId'] != before['schoolId'] ||
          result['activation'] != 'app-lock-unlock-v2' ||
          theme is! Map ||
          theme['schemaVersion'] != 1 ||
          theme['revision'] is! String ||
          ![
            'red',
            'green',
            'blue',
          ].every((k) => theme[k] is int && theme[k] >= 0 && theme[k] <= 255) ||
          (theme['presetId'] != null &&
              (theme['presetId'] is! String ||
                  windowsThemePreset(theme['presetId']) == null)))
        return ThemeUnlockOutcome.deferred;
      final previous = WindowsAppearance.brandData;
      WindowsAppearance.applyBrand(theme);
      return previous['revision'] == theme['revision'] &&
              previous['presetId'] == theme['presetId'] &&
              ['red', 'green', 'blue'].every((k) => previous[k] == theme[k])
          ? ThemeUnlockOutcome.unchanged
          : ThemeUnlockOutcome.applied;
    } catch (_) {
      // A missing network/theme must not block access or change an open session.
      return ThemeUnlockOutcome.deferred;
    }
  }

  static void verifyDeviceRegistration(Map<String,dynamic> result, String deviceIdentity) {
    final device=result['device'];
    if(result['success']!=true || (result['deviceEnforced']!=true && !(result['deviceManaged']==true && result['deviceEnforced']==false)) || !validSchoolId(result['schoolId']?.toString()??'') ||
        device is! Map || device['deviceIdentity']!=deviceIdentity || device['status']!='active' ||
        device['generationHash'] is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(device['generationHash']) ||
        device['authorizedAt'] is! int || (result['deviceEnforced']==true && result['offlineLease'] is! String)) {
      throw StateError('PC registration proof could not be verified. Existing data remains preserved.');
    }
  }
  static Future<void> reauthenticate(String email,String password,{http.Client? client}) async {
    final saved=await CentralSchoolCloud.saved();
    if(saved['managed']!=true||saved['email']?.toString().toLowerCase()!=email.trim().toLowerCase())throw StateError('Use the currently logged-in school account.');
    final cloud=CentralSchoolCloud(endpoint:saved['endpoint'],expectedSchoolId:saved['schoolId'],client:ManagedDeviceClient(client ?? http.Client(), saved['endpoint'].toString(),accountUid:saved['uid'].toString()));
    try{
      final auth=await cloud.send('POST',Uri.https('identitytoolkit.googleapis.com','/v1/accounts:signInWithPassword',{'key':platformApiKey}),body:{'email':email.trim(),'password':password,'returnSecureToken':true});
      if(auth['localId']!=saved['uid']||auth['idToken'] is! String)throw StateError('School identity changed.');
      final session=await cloud.api({'action':'managed/session','schoolId':saved['schoolId']},token:auth['idToken']);
      if(session['uid']!=saved['uid']||session['schoolId']!=saved['schoolId'])throw StateError('School authentication mapping changed.');
    }finally{cloud.close();}
  }
  static Future<void> changePassword(String current,String next) async {
    if(next.length<12||next.length>128)throw const FormatException('Use 12–128 characters for the new password.');
    final saved=await CentralSchoolCloud.saved();
    final cloud=CentralSchoolCloud(endpoint:saved['endpoint'],client:ManagedDeviceClient(http.Client(),saved['endpoint'].toString(),accountUid:saved['uid'].toString()));
    try {
      final auth=await cloud.send('POST',Uri.https('identitytoolkit.googleapis.com','/v1/accounts:signInWithPassword',{'key':platformApiKey}),body:{'email':saved['email'],'password':current,'returnSecureToken':true});
      if(auth['localId']!=saved['uid'])throw StateError('School identity changed.');
      await cloud.api({'action':'managed/session','schoolId':saved['schoolId']},token:auth['idToken']);
      await cloud.send('POST',Uri.https('identitytoolkit.googleapis.com','/v1/accounts:update',{'key':platformApiKey}),body:{'idToken':auth['idToken'],'password':next,'returnSecureToken':true});
    } finally {cloud.close();}
    await logout(); // Password change revokes old Firebase tokens; require fresh login.
  }
  static Future<void> logout() async {
    await reportAppearanceLock(true);
    CentralSchoolCloud.clearFirebaseToken();
    try {await call('managed/disconnect').timeout(const Duration(seconds:5));}catch(_){}

    _transport?.close();_transport=null;_transportScope=null;
    await const WindowsSecureStorage().delete(key:CentralSchoolCloud.key);
    CentralSchoolCloud.clearFirebaseToken();changed.value++;
  }
}

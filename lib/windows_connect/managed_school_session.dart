import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../windows_secure_storage.dart';
import '../platform/platform_config.dart';
import 'central_school_cloud.dart';
class ManagedSchoolSession {
  static http.Client? _transport;
  static String? _transportScope;
  static http.Client _transportFor(Map<String,dynamic> saved) {
    final scope=jsonEncode([saved['endpoint'],saved['schoolId'],saved['uid']]);
    if(_transport==null||_transportScope!=scope) {
      _transport?.close();_transport=http.Client();_transportScope=scope;
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
  static Future<Map<String,dynamic>> call(String action,[Map<String,dynamic> body=const {}]) => callForSchool(null, action, body);
  static Future<Map<String,dynamic>> callForSchool(String? expectedSchoolId, String action, Map<String,dynamic> body) async {
    final saved=await CentralSchoolCloud.saved();verifyBuildEndpoint(saved['endpoint']?.toString()??'');if(saved['managed']!=true)throw StateError('Managed school login required');
    if(expectedSchoolId != null && saved['schoolId'] != expectedSchoolId) throw StateError('School changed before operation.');
    final cloud=CentralSchoolCloud(endpoint:saved['endpoint'],expectedSchoolId:saved['schoolId'],
      client:_transportFor(saved),closeClient:false);
    try {
      final result = await cloud.api({'action':action,...body,'schoolId':saved['schoolId']},token:await CentralSchoolCloud.firebaseToken());
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
      final session=await cloud.api({'action':'managed/session'},token:auth['idToken']);
      if(session['uid']!=auth['localId']||!validSchoolId(session['schoolId']?.toString()??''))throw StateError('School account mapping is invalid');
      final configuration = managedSessionConfiguration(session, session['schoolId'], auth['localId']);
      Map<String,dynamic> googleProfile={};
      try {
        final lookup=await cloud.send('POST',Uri.https('identitytoolkit.googleapis.com','/v1/accounts:lookup',{'key':platformApiKey}),body:{'idToken':auth['idToken']});
        final accounts=lookup['users'] as List? ?? [];
        if(accounts.length==1 && accounts.first['localId']==auth['localId'] && (accounts.first['providerUserInfo'] as List? ?? []).any((p)=>p['providerId']=='google.com')) {
          googleProfile={'photoUrl':accounts.first['photoUrl']??'','displayName':accounts.first['displayName']??''};
        }
      }catch(_){}
      final old=await CentralSchoolCloud.saved();
      if(old.isNotEmpty&&old['managed']!=true)await const WindowsSecureStorage().write(key:'vidya_saarthi_legacy_cloud_preserved',value:jsonEncode(old));
      await const WindowsSecureStorage().write(key:CentralSchoolCloud.key,value:jsonEncode({'managed':true,'endpoint':endpoint,'projectId':platformProjectId,'schoolId':session['schoolId'],'uid':auth['localId'],'email':auth['email']??email.trim(),'firebaseRefreshToken':auth['refreshToken'],'folderId':'managed',...configuration,...googleProfile,'verifiedAccess':session}));
      await const WindowsSecureStorage().write(key:'vidya_saarthi_managed_required',value:'true');
      changed.value++;return session;
    }finally{cloud.close();}
  }
  static Future<void> reauthenticate(String email,String password,{http.Client? client}) async {
    final saved=await CentralSchoolCloud.saved();
    if(saved['managed']!=true||saved['email']?.toString().toLowerCase()!=email.trim().toLowerCase())throw StateError('Use the currently logged-in school account.');
    final cloud=CentralSchoolCloud(endpoint:saved['endpoint'],expectedSchoolId:saved['schoolId'],client:client);
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
    final cloud=CentralSchoolCloud(endpoint:saved['endpoint']);
    try {
      final auth=await cloud.send('POST',Uri.https('identitytoolkit.googleapis.com','/v1/accounts:signInWithPassword',{'key':platformApiKey}),body:{'email':saved['email'],'password':current,'returnSecureToken':true});
      if(auth['localId']!=saved['uid'])throw StateError('School identity changed.');
      await cloud.api({'action':'managed/session','schoolId':saved['schoolId']},token:auth['idToken']);
      await cloud.send('POST',Uri.https('identitytoolkit.googleapis.com','/v1/accounts:update',{'key':platformApiKey}),body:{'idToken':auth['idToken'],'password':next,'returnSecureToken':true});
    } finally {cloud.close();}
    await logout(); // Password change revokes old Firebase tokens; require fresh login.
  }
  static Future<void> logout() async {
    CentralSchoolCloud.clearFirebaseToken();
    try {await call('managed/disconnect').timeout(const Duration(seconds:5));}catch(_){}

    _transport?.close();_transport=null;_transportScope=null;
    await const WindowsSecureStorage().delete(key:CentralSchoolCloud.key);
    CentralSchoolCloud.clearFirebaseToken();changed.value++;
  }
}

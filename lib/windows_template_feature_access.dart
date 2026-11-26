import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:crypto/crypto.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_local_firestore.dart';
import 'windows_secure_storage.dart';

// A school add-on entitlement and a separate global upload switch.
// Offline use is bounded; creating or publishing a new template always
// requires a fresh authenticated server check. Never use school settings
// or a local template manifest as proof of paid access.
class TemplateFeatureAccess {
  const TemplateFeatureAccess({required this.verified,required this.enabled,
    required this.uploadEnabled,required this.online});
  const TemplateFeatureAccess.unverified():verified=false,enabled=false,uploadEnabled=false,online=false;
  final bool verified,enabled,uploadEnabled,online;
  bool get canUse=>verified&&enabled;
  bool get canUpload=>canUse&&online&&uploadEnabled;
  String get uploadExplanation {
    if(!verified)return 'Connect to verify Custom TemplateForge access.';
    if(!enabled)return 'Custom TemplateForge is not enabled for this school. Contact the developer for activation.';
    if(!online)return 'Connect to upload a new template. Existing verified templates remain usable.';
    if(!uploadEnabled)return 'TemplateForge uploads are under maintenance. Existing templates continue working.';
    return 'Custom TemplateForge is enabled for this school. Upload a blank Word or Excel form.';
  }
}

class WindowsTemplateFeatureAccess {
  static final _recent=<String,({TemplateFeatureAccess access,int at})>{};
  static final _inFlight=<String,Future<TemplateFeatureAccess>>{};
  static const _storage=WindowsSecureStorage();
  static const maxOfflineMs=24*60*60*1000;
  static const refreshMs=60*1000;

  // Verify the exact authenticated school/account and bound validity.
  static TemplateFeatureAccess decode(Map<String,dynamic> data,
      {required String school,required String uid,required int nowMs,required bool online}){
    final start=data['serverTime'],end=data['expiresAt'];
    if(data['success']!=true||data['schoolId']!=school||data['uid']!=uid||
      data['customTemplates'] is! bool||data['uploadEnabled'] is! bool||
      start is! int||end is! int||end<=start||end-start>maxOfflineMs||
      nowMs<start-120000||nowMs>=end)return const TemplateFeatureAccess.unverified();
    return TemplateFeatureAccess(verified:true,enabled:data['customTemplates']==true,
      uploadEnabled:data['uploadEnabled']==true,online:online);
  }

  static bool _temporary(Object e)=>e is SocketException||e is TimeoutException||
    e is http.ClientException||(e is CentralCloudException&&
      !e.authoritativeAccessDenial&&(e.status==429||e.status>=500));

  static Future<TemplateFeatureAccess> read({bool force=false}) async {
    final db=FirebaseFirestore.instance,profile=db.activeProfileId;
    final school=db.activeProfileIdentity['schoolSyncId']?.toString()??'';
    bool current()=>db.activeProfileId==profile&&db.activeProfileIdentity['schoolSyncId']==school;
    if(!validSchoolId(school))return const TemplateFeatureAccess.unverified();
    Map<String,dynamic> saved;
    try{saved=await CentralSchoolCloud.saved();}
    catch(_){return const TemplateFeatureAccess.unverified();}
    if(!current()||saved['managed']!=true||saved['schoolId']!=school||
      (saved['uid']?.toString()??'').isEmpty)return const TemplateFeatureAccess.unverified();
    final uid=saved['uid'].toString(),endpoint=saved['endpoint']?.toString()??'';
    final scope=sha256.convert(utf8.encode(jsonEncode([school,uid,endpoint]))).toString();
    final key='template_feature_access_v1_'+scope;
    final now=DateTime.now().millisecondsSinceEpoch;
    final previous=_recent[scope];
    if(!force&&previous!=null&&now>=previous.at&&now-previous.at<refreshMs){
      // An enabled short cache must not extend its offline authorization.
      if(previous.access.canUse){
        try{
          final raw=await _storage.read(key:key);
          if(raw!=null&&current()){
            final value=decode(Map<String,dynamic>.from(jsonDecode(raw) as Map),
              school:school,uid:uid,nowMs:now,online:previous.access.online);
            if(value.verified)return value;
          }
        }catch(_){}
      }else if(current()){return previous.access;}
    }
    final lane=scope;
    final active=_inFlight[lane];
    if(active!=null){final result=await active;return current()?result:const TemplateFeatureAccess.unverified();}
    final future=()async{
      final cloud=CentralSchoolCloud(endpoint:endpoint,expectedSchoolId:school);
      try{
        final data=await (()async{
          final token=await CentralSchoolCloud.firebaseToken();
          if(!current())throw StateError('School changed before feature verification.');
          return cloud.api({'action':'managed/features','schoolId':school},token:token);
        })().timeout(const Duration(seconds:25));
        if(!current())return const TemplateFeatureAccess.unverified();
        final access=decode(data,school:school,uid:uid,
          nowMs:DateTime.now().millisecondsSinceEpoch,online:true);
        if(!access.verified){
          await _storage.delete(key:key);
          return const TemplateFeatureAccess.unverified();
        }
        // A verified live response must not be discarded just because the
        // optional offline cache cannot be written. Never extend an old lease.
        try{await _storage.write(key:key,value:jsonEncode(data));}
        catch(_){try{await _storage.delete(key:key);}catch(_){}}
        if(current())_recent[scope]=(access:access,at:DateTime.now().millisecondsSinceEpoch);
        return current()?access:const TemplateFeatureAccess.unverified();
      }catch(e){
        if(!current())return const TemplateFeatureAccess.unverified();
        if(!_temporary(e)){
          _recent.remove(scope);
          try{await _storage.delete(key:key);}catch(_){}
          return const TemplateFeatureAccess.unverified();
        }
        try{
          final raw=await _storage.read(key:key);
          if(raw!=null&&current()){
            final access=decode(Map<String,dynamic>.from(jsonDecode(raw) as Map),school:school,uid:uid,
              nowMs:DateTime.now().millisecondsSinceEpoch,online:false);
            if(current())_recent[scope]=(access:access,at:DateTime.now().millisecondsSinceEpoch);
            return current()?access:const TemplateFeatureAccess.unverified();
          }
        }catch(_){}
        return const TemplateFeatureAccess.unverified();
      }finally{cloud.close();}
    }();
    _inFlight[lane]=future;
    try{final result=await future;return current()?result:const TemplateFeatureAccess.unverified();}
    finally{if(identical(_inFlight[lane],future))_inFlight.remove(lane);}
  }

  static Future<void> requireUse({bool force=false}) async {
    final access=await read(force:force);
    if(!access.canUse)throw StateError('Custom TemplateForge access is disabled or unverified. Choose Plain White or a built-in template.');
  }

  static Future<void> requireUpload() async {
    final access=await read(force:true);
    if(!access.canUpload)throw StateError(access.uploadExplanation);
  }
}

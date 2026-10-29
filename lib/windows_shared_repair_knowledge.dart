import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'shared_repair_policy.dart';
import 'windows_local_firestore.dart';
import 'windows_connect/managed_school_session.dart';

/// Control-plane metadata. Failure never stops sync or clears pending work.
/// One release must pin the dedicated public key before remote rules can run.
class WindowsSharedRepairKnowledge {
  static const _publicKey=String.fromEnvironment('SAARTHI_REPAIR_KNOWLEDGE_PUBLIC_KEY');
  static const _keyId=String.fromEnvironment('SAARTHI_REPAIR_KNOWLEDGE_KEY_ID',defaultValue:'repair-v1');
  static String? _profile,_school;
  static SharedRepairPolicy? _policy;
  static int _sequence=0;
  static String? _hash;
  static bool _busy=false,_loaded=false;
  static int _nextRead=0;
  static int? value(String action,String school,{String module='all',String category='unknown'}) {
    final db=FirebaseFirestore.instance;
    if(_profile!=db.activeProfileId || _school!=school ||
        db.activeProfileIdentity['schoolSyncId']!=school) return null;
    return _policy?.value(action,module:module,category:category,school:school,
      now:DateTime.now().millisecondsSinceEpoch);
  }
  static Future<void> refresh(String school,List<Map<String,dynamic>> memory) async {
    if(_publicKey.isEmpty || !ManagedSchoolSession.enabled || _busy) return;
    final db=FirebaseFirestore.instance,origin=db.activeProfileId;
    if(db.activeProfileIdentity['schoolSyncId']!=school) return;
    if(_profile!=origin || _school!=school) {
      _profile=origin;_school=school;_policy=null;_sequence=0;_hash=null;_loaded=false;_nextRead=0;
    }
    final at=DateTime.now().millisecondsSinceEpoch;
    if(at<_nextRead) return;
    _nextRead=at+3600000;_busy=true;
    bool own()=>db.activeProfileId==origin && db.activeProfileIdentity['schoolSyncId']==school;
    final keys={_keyId:_publicKey};
    try {
      final ref=db.collection('_windows_sync_status').doc('shared-repair-knowledge');
      if(!_loaded) {
        final saved=(await ref.get()).data();if(!own())return;
        _loaded=true;
        if(saved?['schoolId']==school && saved?['sequence'] is int && saved!['sequence']>=0 && saved['sequence']<=2147483647 && saved['hash'] is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(saved['hash'] as String)) {
          _sequence=saved['sequence'] as int;_hash=saved['hash'] as String?;
          if(saved['envelope'] is Map) {
            try {_policy=await SharedRepairPolicy.verify(Map<String,dynamic>.from(saved['envelope']),
              trustedKeys:keys,now:at,previousSequence:_sequence,previousHash:_hash);} catch (_) {/* Expiry returns to compiled defaults; high-water sequence stays. */}
          }
        }
      }
      if(!own())return;
      final observations=sharedRepairObservations(memory);
      final body=observations.isEmpty?<String,dynamic>{}:<String,dynamic>{
        'batchId':sha256.convert(utf8.encode(jsonEncode([at~/3600000,observations]))).toString(),
        'reports':observations,
      };
      final reply=await ManagedSchoolSession.callForSchool(school,'managed/repair-knowledge/pull',
        {'observation':body}).timeout(const Duration(seconds:8));
      if(!own() || reply['success']!=true || reply['schoolId']!=school || reply['repairKnowledgeProtocol']!=1) return;
      if(reply['envelope'] is! Map) return;
      final envelope=Map<String,dynamic>.from(reply['envelope']);
      final next=await SharedRepairPolicy.verify(envelope,trustedKeys:keys,
        now:DateTime.now().millisecondsSinceEpoch,previousSequence:_sequence,previousHash:_hash);
      if(!own())return;
      if(next.sequence==_sequence && next.hash==_hash) {_policy=next;return;}
      await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(()=>ref.set({
        'schoolId':school,'sequence':next.sequence,'hash':next.hash,'envelope':envelope,
      }));
      if(!own())return;
      _policy=next;_sequence=next.sequence;_hash=next.hash;
    } catch (_) {/* Retain only previously verified, unexpired rules; defaults otherwise. */}
    finally {_busy=false;}
  }
}

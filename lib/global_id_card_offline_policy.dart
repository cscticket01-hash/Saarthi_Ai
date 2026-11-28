/// Offline eligibility for FREE templates only. This is a bounded cache of a
/// verified server response, not a payment entitlement or DRM system.
class GlobalIdCardOfflinePolicy {
  static const maxOfflineMs=24*60*60*1000;
  static final _id=RegExp(r'^gid-[a-f0-9]{32}$');
  static final _hash=RegExp(r'^[a-f0-9]{64}$');
  static bool freeRow(Map<String,dynamic> r)=>r['id'] is String&&_id.hasMatch(r['id'] as String)&&
    r['packageSha256'] is String&&_hash.hasMatch(r['packageSha256'] as String)&&
    r['name'] is String&&(r['name'] as String).isNotEmpty&&(r['name'] as String).length<=100&&
    r['version'] is int&&(r['version'] as int)>=1&&(r['version'] as int)<=10000&&
    ['studentId','teacherId','otherStaffId'].contains(r['kind'])&&r['state']=='published'&&
    r['mappingState']=='verified'&&r['accessType']=='free'&&r['pricePaise']==0&&r['unlocked']==true;
  static bool valid(Map<String,dynamic> d,{required String school,required String uid,required int nowMs}){
    final start=d['serverTime'],end=d['expiresAt'],raw=d['templates'];
    if(d['success']!=true||d['schoolId']!=school||d['uid']!=uid||d['paymentEnabled']!=false||
      start is! int||end is! int||end<=start||end-start>maxOfflineMs||
      nowMs<start-120000||nowMs>=end||raw is! List||raw.length>200)return false;
    final seen=<String>{};
    for(final v in raw){
      if(v is! Map||v['id'] is! String||!_id.hasMatch(v['id'] as String)||!seen.add(v['id'] as String))return false;
      if(v['accessType']=='free'&&v['unlocked']==true&&!freeRow(Map<String,dynamic>.from(v)))return false;
    }
    return true;
  }
  static bool contains(Map<String,dynamic> d,{required String id,required int version,required String hash}){
    final rows=d['templates'];
    return rows is List&&rows.any((v)=>v is Map&&freeRow(Map<String,dynamic>.from(v))&&
      v['id']==id&&v['version']==version&&v['packageSha256']==hash);
  }
}

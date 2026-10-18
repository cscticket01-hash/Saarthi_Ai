import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Display-only metadata. A cached directory never authorizes a device/action.
class WindowsDeviceDirectoryCache {
  static String? scope(Map<String,dynamic> profile) {
    if(profile['managed']!=true || profile['endpoint'] is! String ||
        profile['uid'] is! String || (profile['uid'] as String).isEmpty ||
        !RegExp(r'^vs-[a-f0-9]{32}$').hasMatch('${profile['schoolId']}')) return null;
    return sha256.convert(utf8.encode(jsonEncode([
      profile['endpoint'],profile['schoolId'],profile['uid'],
    ]))).toString();
  }
  static List<Map<String,dynamic>> validate(Object? value) {
    if(value is! List || value.length>100) throw const FormatException('Invalid device list.');
    final ids=<String>{};
    final rows=<Map<String,dynamic>>[];
    for(final item in value) {
      if(item is! Map) throw const FormatException('Invalid device response.');
      final row=Map<String,dynamic>.from(item),id=row['deviceIdentity'],seen=row['lastSeenAt'];
      if(id is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(id) || !ids.add(id) ||
          !['active','revoked'].contains(row['status']) || seen is! int || seen<=0 ||
          seen>8640000000000000 || row['name'] is! String || (row['name'] as String).length>100) {
        throw const FormatException('Invalid device response.');
      }
      rows.add({for(final key in ['deviceIdentity','name','status','current','lastSeenAt','activity']) key:row[key]});
    }
    if(rows.where((r)=>r['current']==true && r['status']=='active').length!=1 ||
        rows.where((r)=>r['status']=='active').length>5) {
      throw const FormatException('Current PC authorization could not be verified.');
    }
    return rows;
  }
  static String _key(String scope)=>'vidya_device_directory_v1_$scope';
  static Future<List<Map<String,dynamic>>> read(String scope) async {
    try {
      final raw=(await SharedPreferences.getInstance()).getString(_key(scope));
      if(raw==null || raw.length>100000) return [];
      final data=jsonDecode(raw);
      if(data is! Map || data['version']!=1) return [];
      return validate(data['devices']);
    } catch (_) { return []; }
  }
  static Future<void> write(String scope,List<Map<String,dynamic>> rows) async {
    final safe=validate(rows);
    await (await SharedPreferences.getInstance()).setString(_key(scope),jsonEncode({'version':1,'devices':safe}));
  }
}

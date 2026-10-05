/// Restores only the authenticated school's saved registration. The caller
/// supplies an authenticated transport and checks the active identity each time.
class WindowsSchoolProfileRestore {
  static bool complete(Map<String, dynamic> profile) =>
      (profile['schoolName']?.toString().trim().length ?? 0) >= 2 &&
      (profile['principalName']?.toString().trim().length ?? 0) >= 2;

  static Future<Map<String, dynamic>> resolve({
    required String schoolId,
    required Map<String, dynamic> localProfile,
    required Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) call,
  }) async {
    Future<Map<String, dynamic>> request(String action, Map<String, dynamic> body) async {
      final result = await call(action, body);
      if (result['success'] != true || result['schoolId'] != schoolId) {
        throw StateError('School profile response belongs to a different school or failed.');
      }
      return result;
    }
    final response = await request('managed/records', {'collection':'school_config','operation':'read'});
    final records = response['records'];
    if (records is! Map) throw StateError('Invalid school profile response. Retry restore.');
    final saved = records['school_profile_cache'];
    if (saved != null && saved is! Map) throw StateError('Invalid saved school profile.');
    var profile = saved == null ? <String,dynamic>{} : Map<String,dynamic>.from(saved as Map);
    if (profile.isNotEmpty && profile['schoolId'] != schoolId) throw StateError('Foreign school profile blocked.');
    if (!complete(profile) && complete(localProfile)) {
      profile = {...profile, 'schoolId':schoolId,
        'schoolName':localProfile['schoolName'], 'principalName':localProfile['principalName']};
      for (final prefix in ['logo','seal','principalSignature']) {
        final value = localProfile['${prefix}Url']?.toString() ?? '';
        if (value.startsWith('data:image/')) {
          final comma = value.indexOf(',');
          final separator = value.indexOf(';base64');
          if (comma < 0 || separator < 0) throw StateError('Invalid school image.');
          final uploaded = await request('managed/file/upload', {
            'name':'$prefix.png', 'mime':value.substring(5,separator), 'base64':value.substring(comma+1)});
          if (uploaded['fileId'] is! String || uploaded['fileUrl'] is! String) throw StateError('School image upload failed.');
          profile['${prefix}FileId'] = uploaded['fileId'];
          profile['${prefix}Url'] = uploaded['fileUrl'];
        } else if (value.isNotEmpty) {
          profile['${prefix}Url'] = value;
        }
      }
      await request('managed/records', {'collection':'school_config','operation':'write','id':'school_profile_cache','data':profile});
    }
    if (!complete(profile)) return {};
    final restored = Map<String,dynamic>.from(profile);
    for (final prefix in ['logo','seal','principalSignature']) {
      final fileId = profile['${prefix}FileId'];
      if (fileId is String && fileId.isNotEmpty) {
        final file = await request('managed/file/read', {'fileId':fileId});
        if (file['mime'] is! String || !file['mime'].startsWith('image/') || file['base64'] is! String) throw StateError('School image restore failed.');
        restored['${prefix}Url'] = 'data:${file['mime']};base64,${file['base64']}';
      }
    }
    return restored;
  }
}

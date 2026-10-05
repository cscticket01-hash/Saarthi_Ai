/// Restores only the authenticated school's saved registration. The caller
/// supplies an authenticated transport and checks the active identity each time.
class WindowsSchoolProfileRestore {
  static bool complete(Map<String, dynamic> profile) =>
      (profile['schoolName']?.toString().trim().length ?? 0) >= 2 &&
      (profile['principalName']?.toString().trim().length ?? 0) >= 2;

  static bool ready(Map<String, dynamic> profile) => complete(profile) ||
      profile['enrollmentRecovery'] == true &&
      (profile['schoolName']?.toString().trim().length ?? 0) >= 2;

  /// A missing PC cache is never evidence that a school is new. Only the
  /// authenticated server can declare first registration safe.
  static Future<Map<String, dynamic>> resolveEnrollment({
    required String schoolId,
    required Map<String, dynamic> localProfile,
    required Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) call,
  }) async {
    if (localProfile['schoolId'] != null && localProfile['schoolId'] != schoolId) {
      throw StateError('Foreign local school profile blocked.');
    }
    Future<Map<String, dynamic>> registry(String operation, [Map<String, dynamic> data = const {}]) async {
      final result = await call('managed/profile', {'operation': operation, ...data});
      if (result['success'] != true || result['schoolId'] != schoolId ||
          !['new', 'complete', 'unknown', 'recovery'].contains(result['registrationState']) ||
          result['storageReady'] is! bool) {
        throw StateError('School registration could not be verified. Retry restore.');
      }
      final profile = result['profile'];
      if (profile != null && (profile is! Map || profile['schoolId'] != schoolId) ||
          result['registrationState'] == 'complete' &&
          (profile is! Map || !complete(Map<String, dynamic>.from(profile))) ||
          result['registrationState'] == 'recovery' &&
          (profile is! Map || (profile['schoolName']?.toString().trim().length ?? 0) < 2 || profile['principalName'] != '') ||
          !['complete', 'recovery'].contains(result['registrationState']) && profile != null) {
        throw StateError('Saved school registration requires recovery.');
      }
      return result;
    }
    final enrollment = await registry('read');
    final central = enrollment['profile'] is Map
        ? Map<String, dynamic>.from(enrollment['profile']) : <String, dynamic>{};
    Map<String, dynamic> restored;
    if (enrollment['storageReady'] == true) {
      restored = await resolve(schoolId: schoolId, localProfile: localProfile, call: call);
    } else {
      restored = Map<String, dynamic>.from(localProfile);
    }
    if (!complete(restored) && complete(central)) {
      restored = {...restored, ...central,
        'restoreNotice': 'School registration restored. Files and local-only data that were not synced are unavailable on this PC.'};
    }
    if (complete(restored)) {
      if (!complete(central)) {
        // Backfill an existing Drive/local registration without creating a new
        // school, resetting its trial, or changing its licence.
        await registry('initialize', {'schoolName': restored['schoolName'],
          'principalName': restored['principalName']});
      }
      restored['schoolId'] = schoolId;
      return restored;
    }
    if (enrollment['registrationState'] == 'new') return {};
    if (enrollment['registrationState'] == 'recovery') {
      return {...restored, ...central, 'enrollmentRecovery': true,
        'restoreNotice': 'Your existing school account was recovered. The saved principal details, logo and any data that was never synced are unavailable. No new school or licence was created. Restore the original PC backup to recover those details.'};
    }
    throw StateError('Existing school registration is not available in synced storage. '
      'Restore its original PC backup or contact the developer; do not create another school.');
  }

  static Future<Map<String, dynamic>> resolve({
    required String schoolId,
    required Map<String, dynamic> localProfile,
    required Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) call,
  }) async {
    if (localProfile['schoolId'] != null && localProfile['schoolId'] != schoolId) {
      throw StateError('Foreign local school profile blocked.');
    }
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
    if (profile.isEmpty) return {};
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

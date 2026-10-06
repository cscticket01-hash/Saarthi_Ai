import 'windows_connect/central_school_cloud.dart';
import 'windows_local_firestore.dart';

/// Commit profile, images, location and the durable sync outbox together.
class WindowsSchoolProfileStore {
  static Future<Map<String,dynamic>> saveLocal(Map<String,dynamic> payload) async {
    if (!await FirebaseFirestore.instance.localPersistenceEnabled()) {
      throw StateError('Enable Local Data in Advanced Settings before saving on this PC.');
    }
    final db = FirebaseFirestore.instance;
    final origin = db.activeProfileId;
    final saved = await CentralSchoolCloud.saved();
    final school = saved['schoolId'];
    void verify() {
      if (db.activeProfileId != origin || saved['managed'] == true &&
          db.activeProfileIdentity['schoolSyncId'] != school) throw StateError('School changed. Reopen school settings.');
    }
    verify();
    final ref = db.collection('school_config').doc('school_profile_cache');
    final previous = (await ref.get()).data() ?? <String,dynamic>{};
    verify();
    if (saved['managed'] == true && previous['schoolId'] != null && previous['schoolId'] != school) {
      throw StateError('Foreign school profile blocked.');
    }
    final profile = <String,dynamic>{...previous,
      for (final key in ['schoolName','principalName','schoolContactNo','latitude','longitude','attendanceRadiusMeters'])
        if (payload.containsKey(key)) key: payload[key],
      if (saved['managed'] == true) 'schoolId': school,
      'updatedAt': DateTime.now().millisecondsSinceEpoch};
    for (final prefix in ['logo','seal','principalSignature']) {
      final raw = payload['${prefix}Base64'];
      if (raw is String && raw.startsWith('data:image/')) {
        profile['${prefix}Url'] = raw;
        profile.remove('${prefix}FileId');
      }
    }
    final batch = db.batch();
    batch.set(ref, profile);
    batch.set(db.collection('school_settings').doc('school_location'), {
      'latitude': profile['latitude'], 'longitude': profile['longitude'],
      'radiusMeters': profile['attendanceRadiusMeters'], 'updatedAt': profile['updatedAt'],
      if (saved['managed'] == true) 'schoolId': school,
    });
    await batch.commit();
    verify();
    return profile;
  }
}

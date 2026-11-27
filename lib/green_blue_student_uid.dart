import 'windows_local_firestore.dart';

const greenBlueStudentTemplateId = 'student-green-blue-modern-v1';

/// Read the active school's server-owned UID projections only.
Future<Map<String, dynamic>> greenBlueStudentData(Map<String, dynamic> data) async {
  final result = <String, dynamic>{...data, '_greenBlueVerifiedUid': ''};
  final db = FirebaseFirestore.instance;
  final origin = db.activeProfileId;
  final school = db.activeProfileIdentity['schoolSyncId']?.toString() ?? '';
  final generation = data['mobileStableId']?.toString() ?? '';
  if (school.isEmpty || !RegExp(r'^p-[a-f0-9]{32,64}$').hasMatch(generation)) return result;
  if (data['schoolId'] != null && data['schoolId'] != school) {
    throw StateError('Foreign student UID request');
  }
  void guard() {
    if (db.activeProfileId != origin || db.activeProfileIdentity['schoolSyncId'] != school) {
      throw StateError('School changed during student UID lookup');
    }
  }
  final config = db.collection('school_config');
  final activation = (await config.doc('universal_uid_v1_activation').get()).data();
  guard();
  if (activation == null || activation['schoolId'] != school ||
      activation['uidProtocol'] != 1 || activation['_syncDeleted'] == true ||
      activation['deleted'] == true) return result;
  final assignment = (await config.doc('universal_uid_v1_$generation').get()).data();
  guard();
  if (assignment == null || assignment['schoolId'] != school ||
      assignment['uidProtocol'] != 1 || assignment['personId'] != generation ||
      assignment['sourceCollection'] != 'students_directory' ||
      assignment['family'] != 'STU' || assignment['category'] != 'student' ||
      assignment['_syncDeleted'] == true || assignment['deleted'] == true) return result;
  final uid = assignment['universalUid'];
  final serial = assignment['serial'];
  final code = activation['schoolCode'];
  if (uid is String && code is String && serial is int && serial >= 1 && serial <= 999999 &&
      uid.startsWith('STU-$code-') && uid.endsWith('-${serial.toString().padLeft(6, '0')}')) {
    result['_greenBlueVerifiedUid'] = uid;
  }
  return result;
}

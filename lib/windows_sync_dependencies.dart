import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'windows_local_firestore.dart';

/// Local write-ahead work, never a cloud outbox or an idle full-school scan.
/// Retain each verified input revision until its dependent stages complete.
class WindowsSyncDependencies {
  static bool relevant(String collection, String id) =>
      collection == 'students_directory' ||
      collection == 'teachers_directory' ||
      collection == 'school_config' && id == 'school_profile_cache' ||
      collection == 'school_settings' && id == 'document_templates';

  static void _requireSchool(String school) {
    if (FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'] !=
        school) {
      throw StateError('School changed during dependent sync work.');
    }
  }

  static Future<void> retain(
    String school,
    String collection,
    String id,
    String revision, {Map<String,dynamic>? previousRecord,}
  ) => retainMany(school, collection, {id: revision},previousRecords:previousRecord==null?const {}:{id:previousRecord});

  static Future<void> retainMany(
    String school,
    String collection,
    Map<String, String> revisions, {Map<String,Map<String,dynamic>> previousRecords=const {},}
  ) async {
    final entries = revisions.entries
        .where((e) => relevant(collection, e.key))
        .toList();
    if (entries.isEmpty) return;
    _requireSchool(school);
    if (entries.any((e) => e.value.isEmpty))
      throw StateError('Verified dependency revision required.');
    final db = FirebaseFirestore.instance,
        origin = FirebaseFirestore.instance.activeProfileId;
    for (var offset = 0; offset < entries.length; offset += 200) {
      if (db.activeProfileId != origin)
        throw StateError('School profile changed during dependent sync work.');
      _requireSchool(school);
      final batch = db.batch();
      for (final entry in entries.skip(offset).take(200)) {
        final key = sha256
            .convert(
              utf8.encode(jsonEncode([collection, entry.key, entry.value])),
            )
            .toString();
        batch.set(db.collection('_windows_sync_dependencies').doc(key), {
          'schoolId': school,
          'collection': collection,
          'documentId': entry.key,
          'revision': entry.value,
          if(previousRecords[entry.key]!=null&&previousRecords[entry.key]!['schoolId']==school)
            'previousRecord':previousRecords[entry.key],
        },const SetOptions(merge:true));
      }
      await batch.commit();
    }
    _requireSchool(school);
  }

  static Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> read(
    String school,
  ) async {
    _requireSchool(school);
    final db = FirebaseFirestore.instance,
        origin = FirebaseFirestore.instance.activeProfileId;
    final rows = (await db.collection('_windows_sync_dependencies').get()).docs;
    if (db.activeProfileId != origin)
      throw StateError('School profile changed during dependent sync work.');
    _requireSchool(school);
    return rows.where((row) => row.data()['schoolId'] == school).toList();
  }

  static Future<void> complete(
    String school,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> captured,
  ) async {
    _requireSchool(school);
    final origin = FirebaseFirestore.instance.activeProfileId;
    for (var offset = 0; offset < captured.length; offset += 200) {
      if (FirebaseFirestore.instance.activeProfileId != origin) {
        throw StateError('School profile changed during dependent sync work.');
      }
      _requireSchool(school);
      final batch = FirebaseFirestore.instance.batch();
      for (final row in captured.skip(offset).take(200)) {
        row.reference.requireOriginProfile();
        if (row.data()['schoolId'] != school)
          throw StateError('Foreign dependency rejected.');
        batch.delete(row.reference);
      }
      await batch.commit();
    }
  }
}

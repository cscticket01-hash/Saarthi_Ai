import 'dart:convert';

import 'windows_local_firestore.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_connect/central_school_cloud.dart';

String sheetRecoveryCacheKey(String collection, String id) =>
    base64UrlEncode(utf8.encode(jsonEncode([collection, id])))
        .replaceAll('=', '');

Future<void> cacheVerifiedSheetRecord(
  String school,
  String collection,
  String id,
  Map<String, dynamic> record,
) => cacheVerifiedSheetRecords(school,collection,{id:record});

/// Recovery originals remain durable before business-record apply; commit up
/// to 100 verified originals together rather than fsync once for every record.
Future<void> cacheVerifiedSheetRecords(String school,String collection,
    Map<String,Map<String,dynamic>> records) async {
  final db = FirebaseFirestore.instance,
      profile = FirebaseFirestore.instance.activeProfileId;
  if (records.length>100||db.activeProfileIdentity['schoolSyncId'] != school ||
      records.values.any((record)=>record['schoolId'] != school ||
      record['_syncRevision'] is! String ||
      (record['_syncRevision'] as String).isEmpty)) {
    throw StateError('Verified same-school cloud record required.');
  }
  final batch=db.batch();
  for(final entry in records.entries) {
  final ref = db
      .collection('_windows_verified_cloud_records')
      .doc(sheetRecoveryCacheKey(collection, entry.key));
  batch.set(ref,{
    'schoolId': school,
    'collection': collection,
    'documentId': entry.key,
    'record': migrationJsonValue(entry.value),
  });
  }
  await batch.commit();
  if (db.activeProfileId != profile)
    throw StateError('School changed during recovery cache commit.');
}

/// Only the exact last verified cloud payload may repair a missing Sheet row.
/// Pending edits remain in their existing queue and are applied after recovery.
Future<int> recoverMissingSheetRecords(
  String school,
  String collection,
  List missing, {
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? request,
}) async {
  final db = FirebaseFirestore.instance,
      profile = FirebaseFirestore.instance.activeProfileId;
  var restored = 0;
  for (final raw in missing.take(100)) {
    if (db.activeProfileId != profile ||
        db.activeProfileIdentity['schoolSyncId'] != school)
      throw StateError('School changed during Sheet recovery.');
    if (raw is! Map ||
        raw['deleted'] == true ||
        raw['id'] is! String ||
        raw['revision'] is! String)
      continue;
    final id = raw['id'] as String;
    final cached =
        (await db
                .collection('_windows_verified_cloud_records')
                .doc(sheetRecoveryCacheKey(collection, id))
                .get())
            .data();
    final local = cached?['record'];
    if (cached?['schoolId'] != school ||
        cached?['collection'] != collection ||
        cached?['documentId'] != id ||
        local is! Map ||
        local['_syncRevision'] != raw['revision'])
      continue;
    final result = await (request != null
        ? request('managed/records', {
            'operation': 'recover',
            'collection': collection,
            'id': id,
            'syncProtocol': 2,
            'operationId': 'recover-${raw['revision']}',
            'expectedRecordRevision': raw['revision'],
            'data': local,
          })
        : ManagedSchoolSession.callForSchool(school, 'managed/records', {
            'operation': 'recover',
            'collection': collection,
            'id': id,
            'syncProtocol': 2,
            'operationId': 'recover-${raw['revision']}',
            'expectedRecordRevision': raw['revision'],
            'data': local,
          }));
    if (db.activeProfileId != profile ||
        result['schoolId'] != school ||
        result['success'] != true ||
        result['syncProtocol'] != 2 ||
        result['recovered'] != true ||
        result['recordRevision'] != raw['revision'])
      throw StateError('Sheet recovery receipt did not verify.');
    restored++;
  }
  return restored;
}

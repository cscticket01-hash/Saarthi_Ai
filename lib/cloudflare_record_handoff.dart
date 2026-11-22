import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Transport-only Cloudflare ACK. This is NOT a canonical Drive record
/// revision or proof that a user file was written to Google Drive.
class CloudflareRecordHandoff implements Exception {
  const CloudflareRecordHandoff({
    required this.school,
    required this.collection,
    required this.id,
    required this.operationId,
    required this.ticketId,
    this.lane = 'records',
    this.mediaSourceHash,
    this.mediaFileSha256,
  });
  final String school, collection, id, operationId, ticketId, lane;
  final String? mediaSourceHash, mediaFileSha256;

  @override
  String toString() => 'Cloudflare accepted the original operation; '
      'provider delivery is independently pending.';
}

/// Real-school two-phase stage admission is negotiated from the existing,
/// authenticated broker capability. A valid school ID by itself NEVER
/// authorizes an early Cloudflare-only ACK.
bool eligibleForRecordHandoff(
  Map item,
  String school, {
  required bool edgeDeliverySupported,
}) {
  return edgeDeliverySupported &&
      RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school) &&
      item['schoolId'] == school &&
      item['collection'] is String &&
      (item['collection'] as String).isNotEmpty &&
      // Binary attachments and their Drive fileId-dependent metadata have a
      // different owner; stage them only after a separate file-first handoff.
      item['collection'] != 'documents' &&
      item['atomicBundleId'] == null &&
      item['priorDeletion'] == null &&
      item['priorCloudWrite'] == null &&
      {'set','update'}.contains(item['operation']) &&
      item['data'] is Map &&
      item['operationId'] is String &&
      RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(item['operationId']) &&
      item['baseCloudRevision'] is String;
}


/// Calendar deletions have no person, document or financial cascade owner.
/// Require an already verified base and a first-class outbox operation.
/// A recreate's nested deletion must wait for canonical proof before its write.
bool eligibleForStagedDelete(Map item, String school, {
  required bool edgeDeliverySupported,
}) =>
    edgeDeliverySupported &&
    RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school) &&
    item['schoolId'] == school &&
    item['collection'] == 'school_calendar' &&
    item['operation'] == 'delete' &&
    item['documentId'] is String &&
    (item['documentId'] as String).isNotEmpty &&
    item['operationId'] is String &&
    RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(item['operationId']) &&
    item['baseCloudRevision'] is String &&
    (item['baseCloudRevision'] as String).isNotEmpty &&
    item['atomicBundleId'] == null &&
    item['priorDeletion'] == null &&
    item['requireCanonicalDeleteReceipt'] != true;

/// Broker-derived ticket, not merely a string that resembles a SHA-256 hash.
String? exactStagedRecordTicket(Map original, String school) {
  if (!RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school) ||
      original['schoolId'] != school ||
      original['collection'] is! String ||
      (original['collection'] as String).isEmpty ||
      original['documentId'] is! String ||
      (original['documentId'] as String).isEmpty ||
      original['operationId'] is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(original['operationId']))
    return null;
  return sha256.convert(utf8.encode(jsonEncode([
    school, 'managed_records', [
      original['collection'], original['documentId'], original['operationId'],
    ],
  ]))).toString();
}

/// A retained, explicitly authorized first-phase receipt can restore a CAS
/// marker lost between the journal write and the outbox write. It cannot ACK
/// the provider or authorize a different original operation.
bool recoverableStagedRecordJournal(Map original, Map journal, String school) {
  final expected = exactStagedRecordTicket(original, school);
  return expected != null &&
      (eligibleForRecordHandoff(original,school,edgeDeliverySupported:true) ||
       eligibleForStagedDelete(original,school,edgeDeliverySupported:true)) &&
      {null,'pending','retry'}.contains(original['syncState']) &&
      journal['schoolId'] == school &&
      journal['edgeDeliveryVersion'] == 1 &&
      journal['cloudflareAccepted'] == true &&
      journal['handoffAuthorized'] == true &&
      journal['action'] == 'managed/records' &&
      journal['state'] == 'pending' &&
      journal['lane'] == 'records' &&
      journal['ticketId'] == expected &&
      journal['originalOperationId'] == original['operationId'] &&
      journal['collection'] == original['collection'] &&
      journal['id'] == original['documentId'] &&
      journal['operation'] == (original['operation']=='delete'?'delete':'write');
}

/// A staged ticket is not a final result. It may retire the original
/// locally retained operation only after the authenticated owner separately
/// proves a canonical revision for that exact same-school ticket.
bool verifiedStagedRecordFinal(Map original, Map journal, Map proof,
    String school) {
  final ticket=journal['ticketId'];
  if(ticket is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(ticket)||
      exactStagedRecordTicket(original,school)!=ticket||
      journal['schoolId']!=school||original['schoolId']!=school||
      journal['action']!='managed/records'||
      journal['originalOperationId']!=original['operationId']||
      journal['collection']!=original['collection']||
      journal['id']!=original['documentId']||
      original['cloudTicketId']!=ticket||
      original['cloudTicketLane']!='records'||
      original['syncState']!='cloudAccepted'||
      (!{'set','update'}.contains(original['operation']) &&
       !eligibleForStagedDelete(original,school,edgeDeliverySupported:true))||
      original['collection']=='documents'||
      original['atomicBundleId']!=null||
      original['priorDeletion']!=null||
      (original['operation']!='delete' && original['data'] is! Map)||
      proof['success']!=true||proof['schoolId']!=school||
      proof['cloudflareAccepted']!=true||
      proof['driveState']!='verified'||
      proof['syncProtocol']!=2||
      proof['recordRevision'] is! String||
      (proof['recordRevision'] as String).isEmpty||
      RegExp(r'^(live-|cf-)').hasMatch(proof['recordRevision']))
    return false;
  final record=proof['record'];
  if (original['operation'] == 'delete') {
    // Staging alone is never a deletion ACK. Both providers and the exact
    // completed erase-plan tombstone must agree before local settlement.
    return journal['operation'] == 'delete' &&
        proof['deleteEverywhereVersion'] == 1 &&
        proof['driveDeletionComplete'] == true &&
        proof['firebaseDeletionComplete'] == true &&
        !RegExp(r'^(live-|cf-)').hasMatch(proof['recordRevision'] as String) &&
        record is Map &&
        record['schoolId'] == school &&
        record['_syncDeleted'] == true &&
        record['_syncRevision'] == proof['recordRevision'] &&
        record['_syncOperationId'] == original['operationId'] &&
        (record['id'] == null || record['id'] == original['documentId']) &&
        record['_syncErasePlan'] is Map &&
        record['_syncErasePlan']['complete'] == true;
  }
  if(record is Map) {
    // A verified Script projection sometimes omits wrapper metadata. Its
    // signed broker owner still binds the immutable original operation ID
    // through the stored ticket. Reject any *present* contradictory identity.
    if(record['schoolId']!=school||
        (record['_syncRevision']!=null&&
         record['_syncRevision']!=proof['recordRevision'])||
        (record['_syncOperationId']!=null&&
         record['_syncOperationId']!=original['operationId'])||
        (record['id']!=null&&record['id']!=original['documentId']))
      return false;
  }
  return true;
}


/// The broker has verified the original Google file and its canonical
/// same-operation photo record; only this exact file/record pair may ACK.
bool verifiedStagedPhotoRecordFinal(Map original, Map journal, Map proof,
    String school) {
  final id=journal['ticketId'], media=proof['mediaRecord'];
  if(id is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)||
      journal['schoolId']!=school||original['schoolId']!=school||
      journal['action']!='managed/record/media/stage/resumable'||
      journal['originalOperationId']!=original['operationId']||
      journal['collection']!=original['collection']||
      journal['id']!=original['documentId']||
      original['cloudTicketId']!=id||
      original['cloudTicketLane']!='file-$id'||
      original['syncState']!='cloudAccepted'||
      !{'set','update'}.contains(original['operation'])||
      !{'students_directory','teachers_directory'}.contains(original['collection'])||
      original['atomicBundleId']!=null||original['priorDeletion']!=null||
      original['data'] is! Map||
      proof['success']!=true||proof['schoolId']!=school||
      proof['cloudflareAccepted']!=true||
      proof['driveState']!='verified'||proof['committed']!=true||
      proof['fileId'] is! String||proof['sha256'] is! String||
      media is! Map||media['collection']!=original['collection']||
      media['id']!=original['documentId']||
      media['operationId']!=original['operationId']||
      media['fileId']!=proof['fileId']||
      media['fileSha256']!=proof['sha256']||
      original['cloudMediaSourceHash']!=media['sourceHash']||
      original['cloudMediaFileSha256']!=media['fileSha256']||
      media['recordRevision'] is! String||
      (media['recordRevision'] as String).isEmpty||
      RegExp(r'^(live-|cf-)').hasMatch(media['recordRevision'])) return false;
  return true;
}

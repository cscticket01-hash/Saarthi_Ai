/// Transport-only Cloudflare ACK. This is NOT a canonical Drive record
/// revision or proof that a user file was written to Google Drive.
class CloudflareRecordHandoff implements Exception {
  const CloudflareRecordHandoff({
    required this.school,
    required this.collection,
    required this.id,
    required this.operationId,
    required this.ticketId,
  });
  final String school, collection, id, operationId, ticketId;

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
      {'set','update'}.contains(item['operation']) &&
      item['data'] is Map &&
      item['operationId'] is String &&
      RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(item['operationId']) &&
      item['baseCloudRevision'] is String;
}


/// A staged ticket is not a final result. It may retire the original
/// locally retained operation only after the authenticated owner separately
/// proves a canonical revision for that exact same-school ticket.
bool verifiedStagedRecordFinal(Map original, Map journal, Map proof,
    String school) {
  final ticket=journal['ticketId'];
  if(ticket is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(ticket)||
      journal['schoolId']!=school||original['schoolId']!=school||
      journal['action']!='managed/records'||
      journal['originalOperationId']!=original['operationId']||
      journal['collection']!=original['collection']||
      journal['id']!=original['documentId']||
      original['cloudTicketId']!=ticket||
      original['cloudTicketLane']!='records'||
      original['syncState']!='cloudAccepted'||
      !{'set','update'}.contains(original['operation'])||
      original['collection']=='documents'||
      original['atomicBundleId']!=null||
      original['priorDeletion']!=null||
      original['data'] is! Map||
      proof['success']!=true||proof['schoolId']!=school||
      proof['cloudflareAccepted']!=true||
      proof['driveState']!='verified'||
      proof['syncProtocol']!=2||
      proof['recordRevision'] is! String||
      (proof['recordRevision'] as String).isEmpty)
    return false;
  final record=proof['record'];
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

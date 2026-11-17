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

/// Fail-closed canary gate. Old/new versions and school baselines must be
/// reconciled BEFORE any real school is allowlisted. No school is enabled in
/// a default production build.
bool eligibleForRecordHandoff(
  Map item,
  String school, {
  String enabledTestSchool = '',
}) {
  return enabledTestSchool.isNotEmpty &&
      enabledTestSchool == school &&
      RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school) &&
      item['schoolId'] == school &&
      item['collection'] == 'school_calendar' &&
      item['operation'] == 'set' &&
      item['data'] is Map &&
      (item['data'] as Map)['syntheticTest'] == true &&
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
      original['operation']!='set'||
      original['collection']!='school_calendar'||
      original['data'] is! Map||
      (original['data'] as Map)['syntheticTest']!=true||
      proof['success']!=true||proof['schoolId']!=school||
      proof['cloudflareAccepted']!=true||
      proof['driveState']!='verified'||
      proof['syncProtocol']!=2||
      proof['recordRevision'] is! String||
      (proof['recordRevision'] as String).isEmpty)
    return false;
  final record=proof['record'];
  if(record is Map) {
    if(record['schoolId']!=school||
        record['_syncRevision']!=proof['recordRevision']||
        record['_syncOperationId']!=original['operationId']||
        (record['id']!=null&&record['id']!=original['documentId']))
      return false;
  }
  return true;
}

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

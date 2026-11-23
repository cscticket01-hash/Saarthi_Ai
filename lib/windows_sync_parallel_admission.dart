import 'windows_pending_school_sync.dart'
    show canStageStandaloneSchoolMessagePastUnrelatedOwners;

/// The oldest independent school notice may be staged alongside a different
/// person operation. The device still cannot acknowledge its Google delivery.
Map<String, dynamic>? oldestIndependentNotice(
  List<Map<String, dynamic>> rows, {
  required String schoolId,
  required int nowMillis,
}) {
  final notices = rows.where((row) =>
      row['collection'] == 'school_notices' &&
      row['schoolId'] == schoolId &&
      row['syncState'] != 'cloudAccepted').toList()
    ..sort((a, b) {
      final at = a['queuedAtMillis'];
      final bt = b['queuedAtMillis'];
      final aMillis = at is num && at >= 0 ? at.toInt() : 0;
      final bMillis = bt is num && bt >= 0 ? bt.toInt() : 0;
      final cmp = aMillis.compareTo(bMillis);
      return cmp != 0 ? cmp : (a['queueId'] ?? '').toString()
          .compareTo((b['queueId'] ?? '').toString());
    });
  if (notices.isEmpty) return null;
  final first = notices.first;
  final operationId = first['operationId'];
  final queueId = first['queueId'];
  if (!{'pending', 'retry'}.contains(first['syncState']) ||
      first['operation'] != 'set' ||
      first['atomicBundleId'] != null ||
      first['priorDeletion'] != null ||
      first['priorCloudWrite'] != null ||
      (first['retryAtMillis'] is num &&
        (first['retryAtMillis'] as num) > nowMillis) ||
      queueId is! String || queueId.isEmpty ||
      operationId is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(operationId)) {
    return null;
  }
  // Reuse the exact existing dependency/isolation policy. Targeted notices,
  // same-resource predecessors, school configuration, deletes and malformed
  // foreign rows cannot bypass the serialized CAS owner for faster UI.
  if (!canStageStandaloneSchoolMessagePastUnrelatedOwners(
      first, rows, schoolId)) {
    return null;
  }
  return {'queueId': queueId, 'operationId': operationId};
}

/// Two independently Cloudflare-admitted requests begin immediately but the
/// owning device cycle remains joined until both attempts settle. A failure
/// never leaves an untracked local CAS write.
Future<void> runIndependentCloudAdmissions(
  Future<void> Function() sendPeople,
  Future<void> Function() sendNotice,
) async {
  await Future.wait<void>([sendPeople(), sendNotice()]);
}

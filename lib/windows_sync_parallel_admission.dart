/// A notification to Cloudflare is independent of a Student/Teacher create.
/// Select at most ONE oldest local notice so same-notice revisions stay FIFO.
/// This is local dispatch only: it must never acknowledge Drive or remove data.
Map<String, dynamic>? oldestIndependentNotice(
  List<Map<String, dynamic>> rows, {
  required String schoolId,
  required int nowMillis,
}) {
  final notices = rows.where((row) =>
      row['collection'] == 'school_notices' &&
      row['schoolId'] == schoolId &&
      row['syncState'] != 'cloudAccepted').toList()
    ..sort((a,b) {
      final x=a['queuedAtMillis'],y=b['queuedAtMillis'];
      final xt=x is int && x>=0?x:0, yt=y is int && y>=0?y:0;
      final order=xt.compareTo(yt);
      return order!=0?order:(a['queueId']??'').toString()
        .compareTo((b['queueId']??'').toString());
    });
  if (notices.isEmpty) return null;
  final first=notices.first;
  final op=first['operationId'],id=first['queueId'];
  if ((first['syncState'] != 'pending' && first['syncState'] != 'retry') ||
      first['operation'] != 'set' ||
      first['atomicBundleId'] != null ||
      first['priorDeletion'] != null ||
      (first['retryAtMillis'] is num &&
        (first['retryAtMillis'] as num)>nowMillis) ||
      id is! String || id.isEmpty ||
      op is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(op)) {
    return null;
  }
  return {'queueId':id,'operationId':op};
}

/// Only these record types already have independent per-identity delivery
/// resources in the Cloudflare owner. Never fast-forward people, exam,
/// fee/receipt, document, settings or delete dependencies around their owner.
Map<String, dynamic>? oldestIndependentRecord(
  List<Map<String, dynamic>> rows, {
  required String schoolId,
  required int nowMillis,
}) {
  const collections = {
    'attendance_records', 'attendance_logs',
    'teacher_attendance', 'school_expenses',
  };
  final eligible = rows.where((row) =>
      row['schoolId'] == schoolId &&
      collections.contains(row['collection']) &&
      row['syncState'] != 'cloudAccepted').toList()
    ..sort((a, b) {
      int time(Map<String, dynamic> row) =>
          row['queuedAtMillis'] is num && (row['queuedAtMillis'] as num) >= 0
              ? (row['queuedAtMillis'] as num).toInt() : 0;
      final order = time(a).compareTo(time(b));
      return order != 0 ? order : (a['queueId'] ?? '').toString()
          .compareTo((b['queueId'] ?? '').toString());
    });
  final seen = <String>{};
  for (final row in eligible) {
    final doc = row['documentId'];
    final collection = row['collection'];
    if (doc is! String || doc.isEmpty ||
        !seen.add('$collection:$doc')) continue;
    // An earlier retry, in-flight mutation or operator review is a FIFO
    // barrier for subsequent writes to this exact document.
    if (!{'pending', 'retry'}.contains(row['syncState']) ||
        row['operation'] != 'set' ||
        row['atomicBundleId'] != null ||
        row['priorDeletion'] != null ||
        row['retryAtMillis'] is num &&
          (row['retryAtMillis'] as num) > nowMillis) continue;
    final id = row['queueId'], operation = row['operationId'];
    if (id is! String || id.isEmpty ||
        operation is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(operation)) continue;
    return {'queueId': id, 'operationId': operation};
  }
  return null;
}

/// Both independent Cloudflare admissions start immediately. A failed lane
/// cannot make the owner exit while the other lane is still retaining its
/// immutable local receipt.
Future<void> runIndependentCloudAdmissions(
  Future<void> Function() sendPeople,
  Future<void> Function() sendNotice,
) async {
  await Future.wait<void>([sendPeople(),sendNotice()]);
}

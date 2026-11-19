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

/// Both independent Cloudflare admissions start immediately. A failed lane
/// cannot make the owner exit while the other lane is still retaining its
/// immutable local receipt.
Future<void> runIndependentCloudAdmissions(
  Future<void> Function() sendPeople,
  Future<void> Function() sendNotice,
) async {
  await Future.wait<void>([sendPeople(),sendNotice()]);
}

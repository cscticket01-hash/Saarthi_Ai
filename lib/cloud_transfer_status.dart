/// Presentation only. Transfer status never acknowledges or removes queued data.
String? cloudTransferMessage(Map<String, dynamic>? status) {
  if (status == null) return null;
  if (status['unavailable'] == true) {
    return 'Cloudflare transfer status unavailable; saved work retained.';
  }
  if (status['enabled'] == false) return null;
  final notices = status['notices'], delivery = status['delivery'];
  bool count(Object? value) => value is num && value.isFinite && value >= 0 && value == value.roundToDouble();
  if (status['enabled'] != true || notices is! Map || delivery is! Map ||
      !count(notices['pending']) || !count(notices['needsAttention']) ||
      !count(delivery['pendingPartitions'])) {
    return 'Cloudflare transfer status not verified; saved work retained.';
  }
  if (delivery['needsAttention'] != null && !count(delivery['needsAttention'])) return 'Cloudflare transfer status not verified; saved work retained.';
  final noticeAttention = (notices['needsAttention'] as num).toInt();
  final allAttention = (delivery['needsAttention'] as num? ?? 0).toInt();
  final attention = noticeAttention > allAttention ? noticeAttention : allAttention;
  if (attention > 0) return 'Cloudflare saved · $attention transfers need school review.';
  if ((notices['pending'] as num) > 0 || (delivery['pendingPartitions'] as num) > 0) {
    return 'Cloudflare saved · Google Drive transfer pending.';
  }
  return null;
}

/// Live backup history uses a separate persisted journal. These messages cannot
/// acknowledge the local record outbox and never relabel staging as Drive save.
List<String> driveSaveMessages(Map<String, dynamic>? status) {
  if (status == null || status['driveHistoryLocal'] != true && status['unavailable'] == true) return const [];
  final rows = status['driveSaveHistory'];
  if (rows is! List || rows.length > 25) return const [];
  final messages = <String>[];
  for (final row in rows) {
    if (row is! Map || row['id'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(row['id'] as String)) continue;
    final recordId = row['recordId'], collection = row['collection'];
    final label = recordId is String && collection is String
        ? '$collection · $recordId' : (row['id'] as String).substring(0, 8);
    final completedAt = row['completedAt'];
    if (row['state'] == 'completed' && completedAt is int && completedAt > 0) {
      // Completed writes remain in the durable history, not the alert panel.
      // Do not hide pending/retry or needsAttention entries.
      continue;
    } else if (row['state'] == 'needsAttention') {
      messages.add('Drive save needs review · $label');
    } else if (const ['pending', 'retry', 'processing'].contains(row['state'])) {
      messages.add(row['cloudflareAccepted'] == true
          ? 'Cloudflare saved · Drive save pending · $label'
          : 'Drive save pending · $label');
    }
  }
  return messages;
}


/// A percentage is available only for bytes acknowledged by Google Drive.
/// Cloudflare staging bytes, elapsed time and retry counts are not progress.
Map<String, dynamic>? measuredDriveProgress(Map<String, dynamic>? status) {
  if (status == null || status['unavailable'] == true ||
      status['driveHistoryLocal'] != true) return null;
  final rows = status['driveSaveHistory'];
  if (rows is! List || rows.length > 25) return null;
  Map? latestCompleted;
  for (final item in rows) {
    if (item is! Map || item['id'] is! String) continue;
    if (item['state'] == 'completed') {
      latestCompleted ??= item;
      continue;
    }
    if (item['state'] != 'pending') continue;
    final progress = item['driveProgress'];
    if (progress is Map && progress['version'] == 1 &&
        progress['totalBytes'] is int && progress['totalBytes'] > 0 &&
        progress['acknowledgedBytes'] is int &&
        progress['acknowledgedBytes'] >= 0 &&
        progress['acknowledgedBytes'] < progress['totalBytes']) {
      final done=progress['acknowledgedBytes'] as int;
      final total=progress['totalBytes'] as int;
      return {'state':'uploading', 'percent':(done*100/total).floor(),
        'acknowledgedBytes':done, 'totalBytes':total};
    }
    return {'state':'verifying'};
  }
  // Completed means an independently verified owner receipt, not a timer.
  // Older completions may have no trustworthy total-duration measurement.
  if (latestCompleted != null) {
    final duration = latestCompleted['driveDurationMillis'];
    return {'state':'completed', 'percent':100,
      if (duration is int && duration >= 0 && duration <= 86400000)
        'durationMillis':duration};
  }
  return null;
}

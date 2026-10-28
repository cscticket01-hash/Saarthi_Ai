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
  final attention = (notices['needsAttention'] as num).toInt();
  if (attention > 0) return 'Cloudflare saved · $attention notice transfers need school review.';
  if ((notices['pending'] as num) > 0 || (delivery['pendingPartitions'] as num) > 0) {
    return 'Cloudflare saved · Google Drive transfer pending.';
  }
  return null;
}

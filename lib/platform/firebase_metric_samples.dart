/// Bind older/raw monitoring responses using observed samples only. Quota
/// limits, backend response time and estimates never substitute for usage.
const _patterns = <String, String>{
  'storageBytes': r'storage.*(bytes|size)|total_size',
  'readsPerSecond': r'document/read(_ops)?_count$',
  'writesPerSecond': r'document/write(_ops)?_count$',
  'outboundBitsPerSecond': r'network/sent_bytes_count$',
  'inboundBitsPerSecond': r'network/received_bytes_count$',
  'latency': r'request.*latenc',
};
List<Map> _candidates(Map metrics, String key) =>
    (metrics['metrics'] is List ? metrics['metrics'] as List : const [])
        .whereType<Map>()
        .where((m) => RegExp(_patterns[key] ?? r'$^').hasMatch('${m['type']}'))
        .toList()
      ..sort(
        (a, b) =>
            ('${b['type']}'.contains('_ops_count') ? 1 : 0) -
            ('${a['type']}'.contains('_ops_count') ? 1 : 0),
      );

Map<String, dynamic> firebaseMetricCards(Map metrics) {
  final result = <String, dynamic>{};
  for (final key in _patterns.keys) {
    final supplied = metrics['cards'] is Map ? metrics['cards'][key] : null;
    if (supplied is Map &&
        supplied['value'] is num &&
        (supplied['value'] as num).isFinite) {
      result[key] = supplied;
      continue;
    }
    final candidates = _candidates(
      metrics,
      key,
    ).where((m) => m['available'] == true && m['partial'] != true);
    if (candidates.isEmpty) continue;
    final metric = candidates.first,
        rate = key.endsWith('PerSecond'),
        mean = key == 'latency';
    var total = 0.0, weight = 0.0, at = 0;
    for (final series
        in (metric['series'] is List ? metric['series'] as List : const [])
            .whereType<Map>()) {
      final points = series['points'];
      if (points is! List || points.isEmpty || points.first is! Map) continue;
      final p = points.first as Map, value = p['value'];
      if (value is! Map) continue;
      final distribution = value['distributionValue'];
      var v = double.tryParse(
        '${value['int64Value'] ?? value['doubleValue'] ?? (distribution is Map ? distribution['mean'] : null)}',
      );
      if (v == null || !v.isFinite) continue;
      final interval = p['interval'];
      final end = interval is Map
          ? DateTime.tryParse('${interval['endTime']}')
          : null;
      final start = interval is Map
          ? DateTime.tryParse('${interval['startTime']}')
          : null;
      if (rate) {
        if (end == null || start == null || !end.isAfter(start)) continue;
        if (metric['kind'] == 'CUMULATIVE') {
          if (points.length < 2 || points[1] is! Map) continue;
          final previous = points[1] as Map,
              oldInterval = previous['interval'],
              oldValue = previous['value'];
          if (oldInterval is! Map ||
              oldValue is! Map ||
              oldInterval['startTime'] != interval['startTime'])
            continue;
          final old = double.tryParse(
                '${oldValue['int64Value'] ?? oldValue['doubleValue']}',
              ),
              oldEnd = DateTime.tryParse('${oldInterval['endTime']}');
          if (old == null ||
              !old.isFinite ||
              oldEnd == null ||
              !end.isAfter(oldEnd) ||
              v < old)
            continue;
          v = (v - old) / (end.difference(oldEnd).inMilliseconds / 1000);
        } else {
          v /= end.difference(start).inMilliseconds / 1000;
        }
      }
      final count = distribution is Map
          ? double.tryParse('${distribution['count']}')
          : null;
      if (distribution is Map &&
          (count == null || !count.isFinite || count <= 0))
        continue;
      final n = mean ? (count ?? 1) : 1.0;
      total += v * n;
      weight += n;
      if (end != null && end.millisecondsSinceEpoch > at)
        at = end.millisecondsSinceEpoch;
    }
    if (weight == 0) continue;
    final bits = key.contains('Bits');
    result[key] = {
      'value': (mean ? total / weight : total) * (bits ? 8 : 1),
      'unit': bits ? 'bit/s' : metric['unit'],
      'type': metric['type'],
      'sampledAt': at == 0 ? null : at,
    };
  }
  return result;
}

String firebaseMetricMissingStatus(
  Map? metrics,
  String key, {
  bool loading = false,
  bool apiError = false,
}) {
  if (metrics == null)
    return apiError
        ? 'API error'
        : loading
        ? 'Loading…'
        : 'Waiting for sample';
  if (metrics['available'] != true)
    return '${metrics['reason']}'.contains('403')
        ? 'Permission unavailable'
        : 'Monitoring unavailable';
  final candidates = _candidates(metrics, key);
  if (candidates.any((m) => m['partial'] == true)) return 'Incomplete sample';
  if (candidates.any(
    (m) => m['status'] == 403 || '${m['reason']}'.contains('403'),
  ))
    return 'Permission unavailable';
  if (candidates.any((m) => m['status'] is num && m['status'] >= 400))
    return 'API error';
  return 'Metric not reported';
}

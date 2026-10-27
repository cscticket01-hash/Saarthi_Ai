/// Empirical quantiles always select an observed value, never a fabricated RTT.
/// Small samples and correlated cohorts must be disclosed by the caller.
Map<String, dynamic>? syncLatencyQuantiles(Iterable<int> observations) {
  final sorted = observations.toList()..sort();
  if (sorted.isEmpty) return null;
  if (sorted.first < 0) throw ArgumentError('Negative latency observation.');
  int percentile(double p) => sorted[((sorted.length - 1) * p).ceil()];
  return {
    'samples': sorted.length,
    'p50': percentile(.5),
    'p95': percentile(.95),
    'p99': percentile(.99),
    'quantileMethod': 'upper observed order statistic ceil((n-1)*p)',
  };
}

import 'package:flutter_test/flutter_test.dart';
import '../lib/sync_latency_statistics.dart';

void main() {
  test('empty observations never manufacture latency or percentiles', () {
    expect(syncLatencyQuantiles([]), isNull);
    expect(() => syncLatencyQuantiles([-1]), throwsArgumentError);
  });
  test('p50 p95 p99 select actual observations without mutating source', () {
    final values = [for (var n = 100; n > 0; n--) n];
    final summary = syncLatencyQuantiles(values)!;
    expect(summary['samples'], 100);
    expect(summary['p50'], 51);
    expect(summary['p95'], 96);
    expect(summary['p99'], 100);
    expect(values.first, 100);
    expect(values.last, 1);
  });
  test('correlated or small samples remain descriptive, not independent evidence', () {
    expect(syncLatencyQuantiles([5, 5, 5])!['samples'], 3);
    expect(syncLatencyQuantiles([5, 5, 5])!['p99'], 5);
    expect(syncLatencyQuantiles([0])!['p50'], 0);
  });
}

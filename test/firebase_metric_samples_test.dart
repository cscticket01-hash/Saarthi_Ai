import 'package:flutter_test/flutter_test.dart';

import '../lib/platform/firebase_metric_samples.dart';

void main() {
  Map response(Map metric) => {
    'available': true,
    'metrics': [metric],
  };
  Map point(int value, int seconds) => {
    'value': {'int64Value': '$value'},
    'interval': {
      'startTime': '2026-01-01T00:00:00Z',
      'endTime': '2026-01-01T00:00:${seconds.toString().padLeft(2, '0')}Z',
    },
  };
  Map metric(List<Map> points, {String kind = 'DELTA'}) => {
    'type': 'firestore.googleapis.com/document/read_ops_count',
    'available': true,
    'kind': kind,
    'unit': '1',
    'series': [
      {'points': points},
    ],
  };
  test('real zero and delta counts bind without invented quota usage', () {
    expect(
      firebaseMetricCards(
        response(metric([point(0, 10)])),
      )['readsPerSecond']['value'],
      0,
    );
    expect(
      firebaseMetricCards(
        response(metric([point(20, 10)])),
      )['readsPerSecond']['value'],
      2,
    );
    expect(firebaseMetricCards({'available': true, 'quota': 1000}), isEmpty);
  });
  test('cumulative counters use adjacent intervals and reject resets', () {
    expect(
      firebaseMetricCards(
        response(metric([point(30, 20), point(10, 10)], kind: 'CUMULATIVE')),
      )['readsPerSecond']['value'],
      2,
    );
    expect(
      firebaseMetricCards(
        response(metric([point(5, 20), point(10, 10)], kind: 'CUMULATIVE')),
      ),
      isEmpty,
    );
  });
  test('partial and forbidden observations remain explicit', () {
    final partial = metric([point(20, 10)])..['partial'] = true;
    expect(firebaseMetricCards(response(partial)), isEmpty);
    expect(
      firebaseMetricMissingStatus(response(partial), 'readsPerSecond'),
      'Incomplete sample',
    );
    expect(
      firebaseMetricMissingStatus(
        response({'type': partial['type'], 'status': 403}),
        'readsPerSecond',
      ),
      'Permission unavailable',
    );
  });
  test('missing samples never become zero or backend response latency', () {
    expect(firebaseMetricCards({'available': true, 'responseMs': 42}), isEmpty);
    expect(
      firebaseMetricMissingStatus(null, 'latency', loading: true),
      'Loading…',
    );
    expect(
      firebaseMetricMissingStatus(null, 'latency', apiError: true),
      'API error',
    );
  });
}

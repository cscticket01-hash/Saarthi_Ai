import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_disk_storage.dart';

void main() {
  test('whole local volume usage is measured independently of application bytes and cached', () async {
    var calls = 0;
    var now = DateTime(2026, 10, 11);
    final disk = WindowsDiskStorage(supported: true, clock: () => now,
      probe: (root) async {
        calls++; expect(root, 'C:\');
        return {'totalBytes': 1000, 'freeBytes': 400, 'availableBytes': 300};
      });
    final first = await disk.measure('C:\\School\\LocalFiles')
        .timeout(const Duration(seconds: 2));
    expect(first['usedBytes'], 600);
    expect(first['freeBytes'], 400);
    expect(first['availableBytes'], 300);
    first['usedBytes'] = 999;
    expect((await disk.measure('c:\\other'))['usedBytes'], 600);
    expect(calls, 1);
    now = now.add(const Duration(minutes: 6));
    await disk.measure('C:\\School'); expect(calls, 2);
  });
  test('unsupported, UNC and malformed paths do not call native API or shell', () async {
    var calls = 0;
    final disk = WindowsDiskStorage(supported: true, probe: (_) async {
      calls++; return {'totalBytes': 1, 'freeBytes': 0, 'availableBytes': 0};
    });
    for (final path in ['\\\\server\\share', 'relative', '/tmp', 'C:relative']) {
      expect((await disk.measure(path))['status'], 'Unknown');
    }
    expect(calls, 0);
  });
  test('failed and impossible volume readings remain Unknown', () async {
    final disk = WindowsDiskStorage(supported: true, probe: (_) async =>
      {'totalBytes': 10, 'freeBytes': 11, 'availableBytes': 0});
    expect((await disk.measure('C:\\app'))['status'], 'Unknown');
    final unavailable = WindowsDiskStorage(supported: true,
      probe: (_) => Future.error(StateError('private detail')));
    final result = await unavailable.measure('C:\\app');
    expect(result['status'], 'Unknown');
    expect(result.toString(), isNot(contains('private detail')));
  });
  test('overlapping probes share one in-flight read', () async {
    final complete = Completer<Map<String, int>>(); var calls = 0;
    final disk = WindowsDiskStorage(supported: true, probe: (_) {calls++; return complete.future;});
    final a = disk.measure('D:\\a'), b = disk.measure('D:\\b');
    complete.complete({'totalBytes': 100, 'freeBytes': 50, 'availableBytes': 50});
    final results = await Future.wait([a, b]).timeout(const Duration(seconds: 2));
    expect(results[0]['usedBytes'], 50); expect(results[1]['usedBytes'], 50);
    expect(calls, 1);
  });
  testWidgets('timed-out read stays Unknown and its late result is never cached', (tester) async {
    final lateRead = Completer<Map<String, int>>();
    var calls = 0;
    final disk = WindowsDiskStorage(supported: true, probe: (_) {
      calls++;
      if (calls == 1) return lateRead.future;
      return Future.value({'totalBytes': 200, 'freeBytes': 100, 'availableBytes': 100});
    });
    final first = disk.measure('C:\\app');
    await tester.pump(const Duration(seconds: 3));
    expect((await first)['status'], 'Unknown');
    lateRead.complete({'totalBytes': 1000, 'freeBytes': 900, 'availableBytes': 900});
    await tester.pump();
    final next = await disk.measure('C:\\app');
    expect(next['totalBytes'], 200);
    expect(calls, 2);
  });

}

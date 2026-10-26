import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_drive_quota.dart';

void main() {
  test('no authorized reader reports Unknown with permission reason', () async {
    final r = await WindowsDriveQuota.measure();
    expect(r['status'], 'Unknown');
    expect(r['reason'], contains('permission'));
  });
  test('authorized quota reports measured bytes without inventing totals',
      () async {
    final r = await WindowsDriveQuota.measure(
        authorizedRead: () async => {'usage': '30', 'limit': '100'});
    expect(r['availableBytes'], 70);
    expect(r['usageBytes'], 30);
    final unlimited = await WindowsDriveQuota.measure(
        authorizedRead: () async => {'usage': '30'});
    expect(unlimited['limitBytes'], isNull);
    expect(unlimited.containsKey('availableBytes'), false);
  });
  test('malformed or rejected quota remains Unknown', () async {
    expect(
        (await WindowsDriveQuota.measure(
            authorizedRead: () async => {'usage': '-1'}))['status'],
        'Unknown');
    expect(
        (await WindowsDriveQuota.measure(
            authorizedRead: () async =>
                throw StateError('private-token')))['status'],
        'Unknown');
  });
}

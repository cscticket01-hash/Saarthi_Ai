import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_json_replace_retry.dart';

void main() {
  final locked = FileSystemException('in use', r'D:\local_database_v1.json',
      const OSError('sharing violation',32));
  test('transient Windows sharing violation retries exact same delete', () async {
    if (!Platform.isWindows) return;
    var deletes = 0, waits = 0;
    await retryLockedDatabaseDelete(() async {
      deletes++;
      if (deletes < 3) throw locked;
    },pause: (_) async { waits++; });
    expect(deletes,3);
    expect(waits,2);
  });
  test('persistent Windows lock is bounded and preserves failure', () async {
    if (!Platform.isWindows) return;
    var attempts=0;
    await expectLater(retryLockedDatabaseDelete(() async {
      attempts++;
      throw locked;
    },maxAttempts:3,pause: (_) async {}),
        throwsA(isA<FileSystemException>().having((e)=>e.osError?.errorCode,'code',32)));
    expect(attempts,3);
  });
  test('unrelated filesystem errors are not blindly retried', () async {
    var attempts=0;
    await expectLater(retryLockedDatabaseDelete(() async {
      attempts++;
      throw FileSystemException('permission denied','test',const OSError('denied',5));
    },pause: (_) async {}),throwsA(isA<FileSystemException>()));
    expect(attempts,1);
  });
}

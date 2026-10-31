import 'dart:async';
import 'dart:io';

/// Legacy JSON fallback only. Waiting is bounded, and the original/pending
/// generations remain intact if Windows reports an external file lock.
///
/// This does not bypass other processes' locks or silently acknowledge writes.
Future<void> retryLockedDatabaseDelete(
  Future<void> Function() delete, {
  int maxAttempts = 7,
  Future<void> Function(Duration)? pause,
}) async {
  if (maxAttempts < 1 || maxAttempts > 10) {
    throw ArgumentError.value(maxAttempts, 'maxAttempts');
  }
  final delay = pause ?? (Duration d) => Future<void>.delayed(d);
  for (var attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      await delete();
      return;
    } on FileSystemException catch (e) {
      // ERROR_SHARING_VIOLATION (32) / ERROR_LOCK_VIOLATION (33):
      // do not retry permissions errors, missing paths, or corrupt content.
      if (!Platform.isWindows ||
          (e.osError?.errorCode != 32 && e.osError?.errorCode != 33)) rethrow;
      if (attempt == maxAttempts) {
        throw FileSystemException(
          'School database is open in another process. Close the other app '
          'or editor using this file, then retry. Original/backup are retained.',
          e.path, e.osError);
      }
      await delay(Duration(milliseconds: 250 * attempt));
    }
  }
}

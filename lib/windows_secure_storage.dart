import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart' as native;

/// One queue for every Windows credential operation, plus an OS file lock
/// shared by separate app processes. Never deletes/resets the credential file.
class WindowsSecureStorage {
  const WindowsSecureStorage();
  static const _native = native.FlutterSecureStorage();
  @visibleForTesting
  static bool? forceCrossProcessLock;
  static Future<void> _tail = Future<void>.value();
  static bool sharingViolation(Object e) =>
      e is FileSystemException && {32, 33}.contains(e.osError?.errorCode);

  static Future<T> run<T>(Future<T> Function() operation) {
    final result = _tail.catchError((_) {}).then((_) async {
      for (var attempt = 0; ; attempt++) {
        RandomAccessFile? guard;
        var locked = false;
        try {
          if (!kIsWeb &&
              Platform.isWindows &&
              (forceCrossProcessLock ??
                  !(kDebugMode &&
                      Platform.environment['FLUTTER_TEST'] == 'true'))) {
            final base =
                Platform.environment['APPDATA'] ??
                Platform.environment['LOCALAPPDATA'];
            if (base == null)
              throw StateError('Windows credential directory unavailable.');
            final directory = Directory(
              '$base${Platform.pathSeparator}VidyaSaarthi',
            );
            await directory.create(recursive: true);
            guard = await File(
              '${directory.path}${Platform.pathSeparator}secure_storage.lock',
            ).open(mode: FileMode.append);
            await guard.lock(FileLock.exclusive);
            locked = true;
          }
          return await operation();
        } catch (e) {
          if (!sharingViolation(e) || attempt >= 8) rethrow;
        } finally {
          if (locked) await guard?.unlock();
          await guard?.close();
        }
        await Future<void>.delayed(Duration(milliseconds: 100 * (attempt + 1)));
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object e, StackTrace s) {});
    return result;
  }

  Future<String?> read({required String key}) =>
      run(() => _native.read(key: key));
  Future<void> write({required String key, required String? value}) =>
      run(() => _native.write(key: key, value: value));
  Future<void> delete({required String key}) =>
      run(() => _native.delete(key: key));
  Future<Map<String, String>> readAll() => run(() => _native.readAll());
  Future<void> deleteAll() => run(() => _native.deleteAll());
}

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

/// Read-only measurements of the local volume containing application storage.
/// This is whole-volume usage, never a measurement of one school's files.
class WindowsDiskStorage {
  WindowsDiskStorage({Future<Map<String, int>> Function(String)? probe,
      DateTime Function()? clock, bool? supported})
      : _probe = probe ?? ((root) => Isolate.run(() => _nativeDisk(root))),
        _clock = clock ?? DateTime.now,
        _supported = supported ?? Platform.isWindows;
  final Future<Map<String, int>> Function(String) _probe;
  final DateTime Function() _clock;
  final bool _supported;
  final Map<String, Map<String, dynamic>> _cache = {};
  final Map<String, Future<Map<String, dynamic>>> _pending = {};
  static const freshness = Duration(minutes: 5);

  Future<Map<String, dynamic>> measure(String applicationPath) {
    final match = RegExp(r'^([A-Za-z]):[\\/]').firstMatch(applicationPath);
    if (!_supported || match == null) return Future.value({
      'status': 'Unknown', 'reason': 'Local Windows volume measurement unavailable',
    });
    final root = '${match[1]!.toUpperCase()}:\\';
    final cached = _cache[root];
    if (cached != null && _clock().millisecondsSinceEpoch -
        (cached['measuredAt'] as int) >= 0 && _clock().millisecondsSinceEpoch -
        (cached['measuredAt'] as int) < freshness.inMilliseconds) {
      return Future.value(Map<String, dynamic>.from(cached));
    }
    return _pending[root] ??= _measure(root).whenComplete(() {
      // Do not return remove()'s value: it is this same completing Future,
      // and awaiting it inside whenComplete creates a self-dependent cycle.
      _pending.remove(root);
    });
  }

  Future<Map<String, dynamic>> _measure(String root) async {
    try {
      final values = await _probe(root).timeout(const Duration(seconds: 3));
      final total = values['totalBytes'], free = values['freeBytes'];
      final available = values['availableBytes'];
      if (total == null || total <= 0 || free == null || free < 0 || free > total ||
          available == null || available < 0 || available > free) {
        throw StateError('Invalid volume measurement');
      }
      final result = <String, dynamic>{
        'status': 'Measured', 'volume': root, 'totalBytes': total,
        'freeBytes': free, 'usedBytes': total - free,
        'availableBytes': available, 'measuredAt': _clock().millisecondsSinceEpoch,
      };
      if (_cache.length >= 16) _cache.remove(_cache.keys.first);
      _cache[root] = result;
      return Map<String, dynamic>.from(result);
    } catch (_) {
      return {'status': 'Unknown', 'volume': root,
        'reason': 'Volume usage unavailable; no estimated capacity shown'};
    }
  }
}

Map<String, int> _nativeDisk(String root) {
  if (!Platform.isWindows) throw UnsupportedError('Windows required');
  final library = DynamicLibrary.open('kernel32.dll');
  final alloc = library.lookupFunction<Pointer<Void> Function(Uint32, UintPtr),
      Pointer<Void> Function(int, int)>('GlobalAlloc');
  final release = library.lookupFunction<Pointer<Void> Function(Pointer<Void>),
      Pointer<Void> Function(Pointer<Void>)>('GlobalFree');
  final driveType = library.lookupFunction<Uint32 Function(Pointer<Uint16>),
      int Function(Pointer<Uint16>)>('GetDriveTypeW');
  final read = library.lookupFunction<Int32 Function(Pointer<Uint16>,
      Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>),
      int Function(Pointer<Uint16>, Pointer<Uint64>, Pointer<Uint64>,
          Pointer<Uint64>)>('GetDiskFreeSpaceExW');
  final path = alloc(0x40, (root.length + 1) * 2);
  final bytes = alloc(0x40, 24);
  try {
    if (path == nullptr || bytes == nullptr) throw StateError('Allocation failed');
    final chars = path.cast<Uint16>().asTypedList(root.length + 1);
    chars.setAll(0, root.codeUnits);
    // Reject remote, unknown, absent and optical volumes before querying space.
    if (!{2, 3, 6}.contains(driveType(path.cast<Uint16>()))) {
      throw UnsupportedError('Local writable volume required');
    }
    final numbers = bytes.cast<Uint64>();
    if (read(path.cast<Uint16>(), numbers, numbers + 1, numbers + 2) == 0) {
      throw StateError('Windows disk query failed');
    }
    return {'availableBytes': numbers.value, 'totalBytes': (numbers + 1).value,
      'freeBytes': (numbers + 2).value};
  } finally {
    if (path != nullptr) release(path);
    if (bytes != nullptr) release(bytes);
  }
}

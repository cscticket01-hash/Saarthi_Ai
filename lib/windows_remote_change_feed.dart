import 'dart:async';

/// Notification reader only: never uploads, acknowledges, or edits a queue.
class WindowsRemoteChangeFeed {
  WindowsRemoteChangeFeed({
    required this.read,
    required this.onHint,
    required this.allowedCollections,
    this.onError,
    this.onReset,
    this.onVerified,
    this.onRecords,
    this.loadCursor,
    this.persistEvent,
    this.readTimeout = const Duration(seconds: 45),
  });
  final Future<Map<String, dynamic>> Function(String school, String? cursor)
  read;
  final void Function(Set<String>) onHint;
  final Set<String> allowedCollections;
  final void Function(Object)? onError;
  final void Function()? onReset;
  final void Function()? onVerified;
  final void Function(Map<String, Set<String>>)? onRecords;
  final Future<String?> Function(String school)? loadCursor;
  final Future<void> Function(String school, Map<String, dynamic> event)?
  persistEvent;
  /// Transport liveness only. This timeout never advances a received cursor,
  /// applies records, changes the original outbox, or grants a cloud ACK.
  final Duration readTimeout;
  Timer? _timer;
  String? _scope, _school, _cursor;
  int _generation = 0, _failures = 0;
  bool _healthy = false;
  bool get isHealthy => _scope != null && _healthy;
  void start(String scope, String school) {
    if (_scope == scope) return;
    stop();
    _scope = scope;
    _school = school;
    if (loadCursor == null) {
      _poll(_generation);
    } else {
      _resume(_generation, school);
    }
  }

  Future<void> _resume(int generation, String school) async {
    try {
      final cursor = await loadCursor!(school);
      if (generation != _generation) return;
      _cursor = cursor;
    } catch (error) {
      if (generation != _generation) return;
      onError?.call(error);
    }
    if (generation == _generation) _poll(generation);
  }

  void stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    _scope = null;
    _school = null;
    _cursor = null;
    _failures = 0;
    _healthy = false;
  }

  Future<void> _poll(int generation) async {
    if (generation != _generation || _school == null) return;
    var delay = const Duration(milliseconds: 250);
    try {
      // A stalled listener must not suppress hourly fallback indefinitely.
      // A late response after timeout is discarded by Future.timeout.
      final out = await read(_school!, _cursor).timeout(readTimeout);
      if (generation != _generation) return;
      final names = out['collections'], cursor = out['cursor'];
      if (out['success'] != true ||
          out['schoolId'] != _school ||
          out['changeFeedVersion'] != 1 ||
          out['reset'] is! bool ||
          cursor is! String ||
          cursor.length > 80 ||
          !RegExp(r'^(?:empty|[a-f0-9-]{36}):[0-9]{1,15}$').hasMatch(cursor) ||
          names is! List ||
          names.length > allowedCollections.length ||
          names.any((c) => c is! String || !allowedCollections.contains(c)) ||
          names.toSet().length != names.length) {
        throw StateError('Unverified school change notification.');
      }
      final targets = <String, Set<String>>{};
      final raw = out['records'];
      if (raw != null) {
        if (raw is! Map || raw.keys.any((k) => !names.contains(k)))
          throw StateError('Invalid record notification.');
        for (final entry in raw.entries) {
          final ids = entry.value;
          if (ids is! List ||
              ids.isEmpty ||
              ids.length > 64 ||
              ids.any(
                (id) =>
                    id is! String ||
                    id.isEmpty ||
                    id.length > 200 ||
                    id.contains('/') ||
                    {
                      '.',
                      '..',
                      '__proto__',
                      'prototype',
                      'constructor',
                    }.contains(id),
              ) ||
              ids.toSet().length != ids.length)
            throw StateError('Invalid record notification.');
          targets[entry.key as String] = ids.cast<String>().toSet();
        }
      }
      if (persistEvent != null && (cursor != _cursor || out['reset'] == true))
        await persistEvent!(_school!, Map<String, dynamic>.from(out));
      if (generation != _generation) return;
      onVerified?.call();
      _healthy = true;
      _cursor = cursor;
      _failures = 0;
      if (out['reset'] == true && onReset != null)
        onReset!();
      else if (names.isNotEmpty) {
        if (onRecords != null && targets.isNotEmpty) onRecords!(targets);
        final broad = names.cast<String>().toSet()
          ..removeAll(onRecords == null ? const <String>{} : targets.keys);
        if (broad.isNotEmpty) onHint(broad);
      }
    } catch (error) {
      if (generation != _generation) return;
      _healthy = false;
      _failures = (_failures + 1).clamp(1, 6);
      delay = Duration(seconds: (1 << _failures).clamp(2, 60));
      onError?.call(error);
    }
    if (generation == _generation)
      _timer = Timer(delay, () => _poll(generation));
  }
}

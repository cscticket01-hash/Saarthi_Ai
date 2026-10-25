import 'dart:async';
import 'package:clock/clock.dart';

const windowsIdleTimeout = Duration(hours: 1);

/// Monotonic App Lock deadline. It keeps running while minimized or unfocused.
class WindowsInactivityTimer {
  WindowsInactivityTimer({required this.onTimeout});

  final void Function() onTimeout;
  final Stopwatch _elapsed = clock.stopwatch();
  Timer? _timer;
  Duration _remaining = windowsIdleTimeout;
  bool _started = false;
  bool _disposed = false;

  Duration get remaining {
    if (_disposed) return Duration.zero;
    final value = _remaining - _elapsed.elapsed;
    return value.isNegative ? Duration.zero : value;
  }

  void _startCountdown() {
    if (_disposed || !_started) return;
    _elapsed..reset()..start();
    _timer = Timer(_remaining, () {
      if (_disposed || !_started) return;
      _elapsed.stop();
      _timer = null;
      _remaining = Duration.zero;
      _started = false;
      onTimeout();
    });
  }

  /// Only the caller's explicit mouse-click event should invoke reset().
  void reset() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _elapsed..stop()..reset();
    _remaining = windowsIdleTimeout;
    _started = true;
    _startCountdown();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _elapsed..stop()..reset();
  }
}

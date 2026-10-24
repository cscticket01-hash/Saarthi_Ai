import 'dart:async';
import 'package:clock/clock.dart';

const windowsIdleTimeout = Duration(hours: 1);

/// Monotonic, foreground-only App Lock timer. Switching to another Windows
/// application pauses this timer without logging out the school session.
class WindowsInactivityTimer {
  WindowsInactivityTimer({required this.onTimeout});

  final void Function() onTimeout;
  final Stopwatch _elapsed = clock.stopwatch();
  Timer? _timer;
  Duration _remaining = windowsIdleTimeout;
  bool _started = false;
  bool _paused = false;
  bool _disposed = false;

  bool get isPaused => _paused;
  Duration get remaining {
    if (_disposed) return Duration.zero;
    final value = _remaining - (_paused ? Duration.zero : _elapsed.elapsed);
    return value.isNegative ? Duration.zero : value;
  }

  void _startCountdown() {
    if (_disposed || _paused || !_started) return;
    _elapsed..reset()..start();
    _timer = Timer(_remaining, () {
      if (_disposed || _paused || !_started) return;
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

  void pause() {
    if (_disposed || _paused) return;
    _remaining = remaining;
    _paused = true;
    _timer?.cancel();
    _timer = null;
    _elapsed..stop()..reset();
  }

  void resume() {
    if (_disposed || !_paused) return;
    _paused = false;
    _startCountdown();
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _elapsed..stop()..reset();
  }
}

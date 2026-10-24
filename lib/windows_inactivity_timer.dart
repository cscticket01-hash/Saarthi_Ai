import 'dart:async';

const windowsIdleTimeout = Duration(seconds: 30);

/// A relative timer, so changing the Windows clock cannot postpone App Lock.
class WindowsInactivityTimer {
  WindowsInactivityTimer({required this.onTimeout});
  final void Function() onTimeout;
  Timer? _timer;
  bool _disposed = false;
  void reset() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer(windowsIdleTimeout, onTimeout);
  }
  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}

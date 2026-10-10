import 'dart:async';

/// Existing reconciliation/hourly timers and OS wake signals, kept testable.
/// The engine still decides whether automatic sync, retry or school isolation
/// permits work; a timer never grants an ACK or bypasses that decision.
class WindowsSyncSchedule {
  WindowsSyncSchedule(this.request, {Timer Function(Duration, void Function(Timer))? periodic})
      : periodic = periodic ?? Timer.periodic;
  final void Function(Duration) request;
  final Timer Function(Duration, void Function(Timer)) periodic;
  Timer? reconciliation, hourly;
  void start(Duration interval) {
    stop();
    reconciliation = periodic(interval, (_) => request(const Duration(milliseconds: 250)));
    hourly = periodic(const Duration(hours: 1), (_) => request(const Duration(milliseconds: 250)));
  }
  void wake() => request(const Duration(milliseconds: 250));
  void reconnected() => request(const Duration(seconds: 2));
  void stop() {reconciliation?.cancel();hourly?.cancel();reconciliation = null;hourly = null;}
}

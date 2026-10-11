import 'dart:async';

/// Existing reconciliation/hourly timers and OS wake signals, kept testable.
/// The engine still decides whether automatic sync, retry or school isolation
/// permits work; a timer never grants an ACK or bypasses that decision.
class WindowsSyncSchedule {
  WindowsSyncSchedule(this.request, {Timer Function(Duration, void Function(Timer))? periodic,
        Timer Function(Duration, void Function())? once, DateTime Function()? now})
      : periodic = periodic ?? Timer.periodic, once = once ?? Timer.new,
        now = now ?? DateTime.now;
  final void Function(Duration) request;
  final Timer Function(Duration, void Function(Timer)) periodic;
  final Timer Function(Duration, void Function()) once;
  final DateTime Function() now;
  Timer? reconciliation, hourly, checkpoint;

  /// Anchored to a durable verified checkpoint, not process uptime or polling.
  void armCheckpoint(DateTime? lastVerified) {
    hourly?.cancel();
    checkpoint?.cancel();
    final current = now();
    final due = lastVerified == null || lastVerified.isAfter(current)
        ? current : lastVerified.add(const Duration(hours: 1));
    final remaining = due.difference(current);
    checkpoint = once(remaining.isNegative ? Duration.zero : remaining, () {
      checkpoint = null;
      request(const Duration(milliseconds: 250));
    });
  }
  void start(Duration interval) {
    stop();
    reconciliation = periodic(interval, (_) => request(const Duration(milliseconds: 250)));
    hourly = periodic(const Duration(hours: 1), (_) => request(const Duration(milliseconds: 250)));
  }
  void wake() => request(const Duration(milliseconds: 250));
  void reconnected() => request(const Duration(seconds: 2));
  void stop() {reconciliation?.cancel();hourly?.cancel();checkpoint?.cancel();reconciliation = null;hourly = null;checkpoint = null;}
}

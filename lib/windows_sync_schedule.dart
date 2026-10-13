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
  DateTime? _checkpointDue;
  bool get checkpointExpected => _checkpointDue?.isAfter(now()) == true;
  bool get checkpointRunning => checkpoint?.isActive == true;
  void repairCheckpoint() {
    if (!checkpointExpected || checkpointRunning) return;
    checkpoint = once(_checkpointDue!.difference(now()), () {
      checkpoint = null; _checkpointDue = null;
      request(const Duration(milliseconds: 250));
    });
  }

  /// Anchored to a durable verified checkpoint, not process uptime or polling.
  void armCheckpoint(DateTime? lastVerified) {
    hourly?.cancel();
    checkpoint?.cancel();
    final current = now();
    final due = lastVerified == null || lastVerified.isAfter(current)
        ? current : lastVerified.add(const Duration(hours: 1));
    final remaining = due.difference(current);
    _checkpointDue = due;
    checkpoint = once(remaining.isNegative ? Duration.zero : remaining, () {
      checkpoint = null;
      _checkpointDue = null;
      request(const Duration(milliseconds: 250));
    });
  }
  void start(Duration interval) {
    stop();
    reconciliation = periodic(interval, (_) => request(const Duration(milliseconds: 250)));
    hourly = periodic(const Duration(hours: 1), (_) => request(const Duration(milliseconds: 250)));
  }
  void repairReconciliationTimer(Duration interval) {
    if (reconciliation?.isActive == true) return;
    reconciliation?.cancel();
    // Preserve the anchored checkpoint and any existing hourly timer.
    reconciliation = periodic(interval, (_) => request(const Duration(milliseconds:250)));
  }
  void wake() => request(const Duration(milliseconds: 250));
  void reconnected() => request(const Duration(seconds: 2));
  void stop() {reconciliation?.cancel();hourly?.cancel();checkpoint?.cancel();reconciliation = null;hourly = null;checkpoint = null;_checkpointDue=null;}
}

/// Bounded dispatch debounce. Fresh durable changes can advance an older retry
/// timer; ordinary polling cannot postpone or multiply the pending dispatch.
class WindowsSyncDispatch {
  WindowsSyncDispatch(this.dispatch,
      {Timer Function(Duration,void Function())? once, DateTime Function()? now})
      : once = once ?? Timer.new, now = now ?? DateTime.now;
  final void Function() dispatch;
  final Timer Function(Duration,void Function()) once;
  final DateTime Function() now;
  Timer? _timer;
  DateTime? scheduledAt;
  bool get expected => scheduledAt != null;
  bool get running => _timer?.isActive == true;
  // Restore only an already-admitted owner deadline. No new retry admission.
  void repair() {
    final due = scheduledAt;
    if (due == null || running) return;
    final remaining = due.difference(now());
    _timer = once(remaining.isNegative ? Duration.zero : remaining, () {
      _timer = null; scheduledAt = null; dispatch();
    });
  }

  void request(Duration delay, {bool localMutation = false}) {
    final bounded = delay.isNegative ? Duration.zero : delay;
    final due = now().add(bounded);
    if (_timer?.isActive == true &&
        (!localMutation || scheduledAt == null || !due.isBefore(scheduledAt!))) return;
    _timer?.cancel();
    scheduledAt = due;
    _timer = once(bounded,() {
      _timer = null;
      scheduledAt = null;
      dispatch();
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    scheduledAt = null;
  }
}

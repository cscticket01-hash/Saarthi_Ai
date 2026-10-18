import 'dart:async';

/// Existing reconciliation/hourly timers and OS wake signals, kept testable.
/// The engine still decides whether automatic sync, retry or school isolation
/// permits work; a timer never grants an ACK or bypasses that decision.
class WindowsSyncSchedule {
  WindowsSyncSchedule(
    this.request, {
    Timer Function(Duration, void Function(Timer))? periodic,
    Timer Function(Duration, void Function())? once,
    DateTime Function()? now,
  }) : periodic = periodic ?? Timer.periodic,
       once = once ?? Timer.new,
       now = now ?? DateTime.now;
  final void Function(Duration) request;
  final Timer Function(Duration, void Function(Timer)) periodic;
  final Timer Function(Duration, void Function()) once;
  final DateTime Function() now;
  Timer? reconciliation, hourly, checkpoint;
  DateTime? _checkpointDue;
  bool get checkpointExpected => _checkpointDue != null;
  bool get checkpointRunning => checkpoint?.isActive == true;
  void repairCheckpoint() {
    if (!checkpointExpected || checkpointRunning) return;
    final remaining = _checkpointDue!.difference(now());
    // An elapsed captured deadline remains admitted by the owner. Restoring
    // it requests normal owner dispatch; it does not admit a data retry.
    checkpoint = once(remaining.isNegative ? Duration.zero : remaining, () {
      checkpoint = null;
      _checkpointDue = null;
      request(const Duration(milliseconds: 250));
    });
  }

  /// Anchored to a durable verified checkpoint, not process uptime or polling.
  void armCheckpoint(DateTime? lastVerified) {
    hourly?.cancel();
    checkpoint?.cancel();
    final current = now();
    final due = lastVerified == null || lastVerified.isAfter(current)
        ? current
        : lastVerified.add(const Duration(hours: 1));
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
    reconciliation = periodic(
      interval,
      (_) => request(const Duration(milliseconds: 250)),
    );
  }

  void repairReconciliationTimer(Duration interval) {
    if (reconciliation?.isActive == true) return;
    reconciliation?.cancel();
    // Preserve the anchored checkpoint and any existing hourly timer.
    reconciliation = periodic(
      interval,
      (_) => request(const Duration(milliseconds: 250)),
    );
  }

  void wake() => request(const Duration(milliseconds: 250));
  void reconnected() => request(const Duration(seconds: 2));
  void stop() {
    reconciliation?.cancel();
    hourly?.cancel();
    checkpoint?.cancel();
    reconciliation = null;
    hourly = null;
    checkpoint = null;
    _checkpointDue = null;
  }
}

/// Bounded dispatch debounce. Fresh durable changes can advance an older retry
/// timer; ordinary polling cannot postpone or multiply the pending dispatch.
class WindowsSyncDispatch {
  WindowsSyncDispatch(
    this.dispatch, {
    Timer Function(Duration, void Function())? once,
    DateTime Function()? now,
  }) : once = once ?? Timer.new,
       now = now ?? DateTime.now;
  final void Function() dispatch;
  final Timer Function(Duration, void Function()) once;
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
      _timer = null;
      scheduledAt = null;
      dispatch();
    });
  }

  void request(Duration delay, {bool localMutation = false}) {
    final bounded = delay.isNegative ? Duration.zero : delay;
    final due = now().add(bounded);
    if (_timer?.isActive == true &&
        (!localMutation || scheduledAt == null || !due.isBefore(scheduledAt!)))
      return;
    _timer?.cancel();
    scheduledAt = due;
    _timer = once(bounded, () {
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

bool canRestoreOwnerDispatch({
  required bool retryAllowed,
  required DateTime? admittedAt,
  DateTime? nextRetry,
  DateTime? quotaRetry,
}) {
  if (!retryAllowed || admittedAt == null) return false;
  return (nextRetry == null || !admittedAt.isBefore(nextRetry)) &&
      (quotaRetry == null || !admittedAt.isBefore(quotaRetry));
}

/// Idle checks are session-local: reopening the process always admits one sync.
/// Failed empty checks also consume the idle interval, without inventing ACKs.
bool automaticWindowsSyncDue({
  required DateTime now,
  required DateTime? lastAttempt,
  required bool localMutation,
  required bool pendingWork,
}) =>
    localMutation ||
    pendingWork ||
    windowsIntegrityAuditDue(now: now, lastAttempt: lastAttempt);

/// A failed/incomplete verified checkpoint stays visible, but cannot turn every
/// subsequent remote change into another full-school integrity audit.
bool windowsIntegrityAuditDue({
  required DateTime now,
  required DateTime? lastAttempt,
  bool manual = false,
}) =>
    manual ||
    lastAttempt == null ||
    now.isBefore(lastAttempt) ||
    !now.isBefore(lastAttempt.add(const Duration(hours: 1)));

/// Collection heads are discovery hints. They cannot grant an ACK/checkpoint.
Set<String> changedWindowsCollections(
  Map<String, String> known,
  Map<String, String> observed,
) {
  if (known.length != observed.length ||
      known.keys.any(
        (key) => observed[key] == null || observed[key]!.isEmpty,
      )) {
    throw StateError('Incomplete school change heads.');
  }
  return known.keys.where((key) => known[key] != observed[key]).toSet();
}

/// Independent bounded read-only discovery backoff; never mutates queue retries.
class WindowsCloudChangeWatch {
  DateTime? nextCheck;
  int failures = 0;
  bool _verified = false;
  bool get hasVerifiedDiscovery => _verified;
  bool due(DateTime now) => nextCheck == null || !now.isBefore(nextCheck!);
  void succeeded(DateTime now) {
    _verified = true;
    failures = 0;
    nextCheck = now.add(const Duration(seconds: 30));
  }

  void failed(DateTime now) {
    _verified = false;
    failures = (failures + 1).clamp(1, 6);
    nextCheck = now.add(
      Duration(seconds: (30 * (1 << failures)).clamp(60, 900)),
    );
  }

  void reset({DateTime? notBefore}) {
    _verified = false;
    nextCheck = notBefore;
    failures = 0;
  }
}

/// Durable collection heads can be reused after process restart. Older caches
/// without per-record revisions still need one verified baseline.
String windowsManagedCheckpointRevision(
  Map<String, dynamic>? manifest, {
  required bool recordDeltas,
}) {
  if (recordDeltas && manifest?['recordRevisions'] is! Map) return '';
  final revision = manifest?['revision'];
  return revision is String ? revision : '';
}

/// Only identity inputs require card publication. Null requests a full audit.
Map<String, Set<String>>? windowsIdPublicationTargets(
  Map<String, Set<String>> changes, {
  bool audit = false,
}) {
  if (audit ||
      (changes['school_config']?.contains('school_profile_cache') ?? false) ||
      (changes['school_settings']?.contains('document_templates') ?? false)) {
    return null;
  }
  return {
    if (changes['students_directory']?.isNotEmpty ?? false)
      'studentId': {...changes['students_directory']!},
    if (changes['teachers_directory']?.isNotEmpty ?? false)
      'teacherId': {...changes['teachers_directory']!},
  };
}

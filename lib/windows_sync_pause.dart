/// Device-local admission policy. It never cancels an accepted request or ACK.
/// Persistence is provided by the active local profile, never a cloud record.
class WindowsSyncPause {
  WindowsSyncPause({DateTime Function()? now}) : now = now ?? DateTime.now;
  static const maximumDuration = Duration(hours: 24);
  final DateTime Function() now;
  DateTime? _until;
  DateTime? get pausedUntil => isPaused ? _until : null;
  bool get isPaused => _until != null && now().isBefore(_until!);

  void restore(Map<String, dynamic>? saved) {
    _until = null;
    final start = saved?['startedAtMillis'];
    final end = saved?['pausedUntilMillis'];
    if (start is! int || end is! int || end <= start ||
        end - start > maximumDuration.inMilliseconds) return;
    final candidate = DateTime.fromMillisecondsSinceEpoch(end);
    if (candidate.isAfter(now()) &&
        candidate.difference(now()) <= maximumDuration) _until = candidate;
  }

  Map<String, dynamic> pause(Duration duration) {
    if (duration <= Duration.zero || duration > maximumDuration) {
      throw ArgumentError.value(duration, 'duration', 'Must be positive and at most 24 hours');
    }
    final start = now();
    _until = start.add(duration);
    return {'startedAtMillis': start.millisecondsSinceEpoch,
      'pausedUntilMillis': _until!.millisecondsSinceEpoch};
  }

  void resume() => _until = null;
}

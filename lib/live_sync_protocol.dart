/// Experimental live-authority protocol. Deliberately separate from protocol-2
/// Drive receipts: cloud commitment cannot acknowledge a Drive backup queue.
const liveSyncCollections = {
  'school_expenses', 'school_calendar', 'school_notices', 'school_settings',
};

class LiveSyncPage {
  const LiveSyncPage(this.schoolId, this.after, this.cursor, this.head, this.events);
  final String schoolId;
  final int after, cursor, head;
  final List<Map<String, dynamic>> events;
  bool get more => cursor < head;
  static LiveSyncPage parse(Map value, String school, int after) {
    final cursor = value['cursor'], head = value['head'], raw = value['events'];
    if (value['success'] != true || value['liveProtocol'] != 1 ||
        value['schoolId'] != school || after < 0 || cursor is! int ||
        head is! int || cursor < after || head < cursor ||
        raw is! List || raw.length > 100 || value['more'] != (cursor < head)) {
      throw StateError('Live replay page did not verify; cursor retained.');
    }
    final events = <Map<String, dynamic>>[];
    var expected = after + 1;
    for (final entry in raw) {
      if (entry is! Map || entry['sequence'] != expected ||
          !liveSyncCollections.contains(entry['collection']) ||
          entry['id'] is! String || (entry['id'] as String).isEmpty ||
          (entry['id'] as String).length > 200 ||
          (entry['id'] as String).contains('/') ||
          {'.', '..', '__proto__', 'prototype', 'constructor'}.contains(entry['id']) ||
          entry['record'] is! Map || entry['record']['schoolId'] != school ||
          entry['record']['_syncRevision'] is! String ||
          !(entry['record']['_syncRevision'] as String).startsWith('live-')) {
        throw StateError('Live replay identity or sequence differs; cursor retained.');
      }
      events.add(Map<String, dynamic>.from(entry));
      expected++;
    }
    if (cursor != expected - 1 || raw.isEmpty && head != after) {
      throw StateError('Live replay gap; cursor retained.');
    }
    return LiveSyncPage(school, after, cursor, head, events);
  }
}

abstract interface class LiveSyncStore {
  Future<int> cursor(String school);
  /// Atomically retain all incoming events and advance exactly page.after.
  /// A crash must leave either the old cursor or the entire retained page.
  Future<void> retainPage(LiveSyncPage page);
}

typedef LiveSyncCall = Future<Map<String, dynamic>> Function(
    String action, Map<String, dynamic> body);

class LiveSyncReplay {
  LiveSyncReplay({required this.schoolId, required this.deviceId,
      required this.store, required this.call, required this.currentSchool});
  final String schoolId, deviceId;
  final LiveSyncStore store;
  final LiveSyncCall call;
  final String Function() currentSchool;
  Future<void>? _flight;
  bool _closed = false;
  void close() => _closed = true;
  void _check() {
    if (_closed || currentSchool() != schoolId) {
      throw StateError('Live school changed; original checkpoint retained.');
    }
  }
  /// WebSocket hints and reconnects call this same serialized replay owner.
  /// A hint never contains record truth and never advances a checkpoint.
  Future<void> pull() => _flight ??= _pull().whenComplete(() => _flight = null);
  Future<void> _pull() async {
    _check();
    while (true) {
      final after = await store.cursor(schoolId);
      _check();
      final value = await call('managed/live/changes', {
        'liveProtocol': 1, 'schoolId': schoolId, 'after': after,
      });
      _check();
      final page = LiveSyncPage.parse(value, schoolId, after);
      await store.retainPage(page);
      _check();
      // Receiver receipt follows durable local retention, never socket arrival.
      await call('managed/live/received', {
        'liveProtocol': 1, 'schoolId': schoolId,
        'deviceId': deviceId, 'cursor': page.cursor,
      });
      _check();
      if (!page.more) return;
      await Future<void>.delayed(Duration.zero);
    }
  }
}

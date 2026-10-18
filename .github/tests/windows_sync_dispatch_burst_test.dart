import 'dart:async';

import '../../lib/windows_sync_schedule.dart';

class ObservedTimer implements Timer {
  ObservedTimer(this.callback);
  final void Function() callback;
  bool active = true;
  @override
  bool get isActive => active;
  @override
  int get tick => 0;
  @override
  void cancel() => active = false;
  void fire() {
    if (active) {
      active = false;
      callback();
    }
  }
}

void main() {
  final discovery = WindowsCloudChangeWatch();
  final discoveryNow = DateTime.utc(2026, 10, 18);
  if (discovery.hasVerifiedDiscovery) throw StateError('Missing initial catch-up');
  discovery.succeeded(discoveryNow);
  if (!discovery.hasVerifiedDiscovery) throw StateError('Healthy listener must suppress duplicate heads');
  discovery.failed(discoveryNow);
  if (discovery.hasVerifiedDiscovery || discovery.due(discoveryNow)) {
    throw StateError('Failed catch-up must retain bounded retry');
  }
  discovery.succeeded(discoveryNow);
  discovery.reset();
  if (discovery.hasVerifiedDiscovery || !discovery.due(discoveryNow)) {
    throw StateError('Listener reset must require a fresh catch-up');
  }

  if (windowsIdPublicationTargets({'notices': {'N1'}})!.isNotEmpty) {
    throw StateError('Notice scheduled unrelated ID work');
  }
  final mixed = windowsIdPublicationTargets({
    'notices': {'N1'}, 'students_directory': {'S1'}, 'fees': {'F1'},
  })!;
  if (mixed.length != 1 || mixed['studentId']?.single != 'S1') {
    throw StateError('Mixed mutation lost precise student target');
  }

  discovery.reset(notBefore: discoveryNow.add(const Duration(seconds: 6)));
  if (discovery.hasVerifiedDiscovery || discovery.due(discoveryNow) ||
      !discovery.due(discoveryNow.add(const Duration(seconds: 6)))) {
    throw StateError('Catch-up must wait for cached heads to expire');
  }

  var now = DateTime.utc(2026, 10, 11), calls = 0;
  final timers = <ObservedTimer>[];
  final dispatch = WindowsSyncDispatch(
    () => calls++,
    now: () => now,
    once: (delay, callback) {
      final timer = ObservedTimer(callback);
      timers.add(timer);
      return timer;
    },
  );
  void check(bool value) {
    if (!value) throw StateError('Dispatch regression');
  }

  // Checkpoint and startup request coalesce into one admitted attempt.
  dispatch.request(const Duration(milliseconds: 250));
  dispatch.request(const Duration(milliseconds: 800));
  check(timers.length == 1);
  timers.last.fire();
  check(calls == 1);
  dispatch.request(const Duration(minutes: 5));
  now = now.add(const Duration(seconds: 1));
  dispatch.request(const Duration(milliseconds: 250), localMutation: true);
  for (var i = 0; i < 100; i++) {
    now = now.add(const Duration(milliseconds: 1));
    dispatch.request(const Duration(milliseconds: 250), localMutation: true);
  }
  check(timers.length == 3);
  check(!timers[1].isActive);
  timers[1].fire();
  check(calls == 1);
  timers.last.fire();
  check(calls == 2);
  // Stop/restart drops stale dispatch without dropping durable queue data.
  dispatch.request(Duration.zero);
  dispatch.cancel();
  timers.last.fire();
  check(calls == 2);
  dispatch.request(Duration.zero);
  timers.last.fire();
  check(calls == 3);
  // Restart keeps a completed baseline; an old/missing baseline cannot skip.
  final saved = <String, dynamic>{
    'revision': 'r1',
    'recordRevisions': {'a': 'a1'},
  };
  final known = {
    'students_directory': windowsManagedCheckpointRevision(
      saved,
      recordDeltas: true,
    ),
  };
  check(changedWindowsCollections(known, {'students_directory': 'r1'}).isEmpty);
  check(
    changedWindowsCollections(known, {
      'students_directory': 'r2',
    }).contains('students_directory'),
  );
  check(windowsManagedCheckpointRevision(null, recordDeltas: true).isEmpty);
  check(
    windowsManagedCheckpointRevision({
      'revision': 'r1',
    }, recordDeltas: true).isEmpty,
  );
  check(
    windowsManagedCheckpointRevision({
          'revision': 'empty',
          'recordRevisions': {},
        }, recordDeltas: true) ==
        'empty',
  );
  print('Startup dispatch and durable checkpoint checks passed');
}

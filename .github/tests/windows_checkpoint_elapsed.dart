import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../lib/windows_sync_schedule.dart';

// No Flutter installation, credentials, cloud calls, mocked time or school data.
// Actual production checkpoint scheduler only; not a Windows engine/device test.
Future<void> main() async {
  final clock = Stopwatch()..start();
  final verified = DateTime.now();
  final events = <Map<String, Object?>>[];
  final done = Completer<void>();
  var polling = false;
  var restarted = false;
  var polls = 0;
  late WindowsSyncSchedule scheduler;
  void record(String type) => events.add({
    'type': type,
    'atUtc': DateTime.now().toUtc().toIso8601String(),
    'elapsedMicroseconds': clock.elapsedMicroseconds,
  });
  void request(Duration delay) {
    if (polling) return;
    record('checkpoint_request');
    if (!done.isCompleted) done.complete();
  }

  WindowsSyncSchedule restored() {
    final value = WindowsSyncSchedule(
      request,
      periodic: (duration, callback) {
        return Timer.periodic(duration, (timer) {
          polling = true;
          callback(timer);
          polling = false;
        });
      },
    );
    value.start(const Duration(minutes: 4));
    value.armCheckpoint(verified);
    return value;
  }

  scheduler = restored();
  // Ordinary poll completion rereads the unchanged durable checkpoint. This
  // rearming must not defer the due time by another hour each four minutes.
  final poll = Timer.periodic(const Duration(minutes: 4), (_) {
    polling = true;
    scheduler.armCheckpoint(verified);
    polling = false;
    polls++;
    record('ordinary_poll_rearm');
  });
  final restart = Timer(const Duration(minutes: 5), () {
    scheduler.stop();
    scheduler = restored();
    restarted = true;
    record('scheduler_recreated_same_checkpoint');
  });
  var status = 'FAIL';
  String? failure;
  try {
    await done.future.timeout(const Duration(minutes: 65));
    if (clock.elapsedMicroseconds < const Duration(hours: 1).inMicroseconds) {
      throw StateError(
        'Checkpoint request preceded strict monotonic full hour',
      );
    }
    if (!restarted || polls < 14)
      throw StateError('Missing real poll/restart observations');
    scheduler.stop();
    poll.cancel();
    await Future<void>.delayed(const Duration(seconds: 2));
    if (events.where((e) => e['type'] == 'checkpoint_request').length != 1) {
      throw StateError('Expected exactly one checkpoint request');
    }
    status = 'PASS';
  } catch (error) {
    failure = error.toString();
    exitCode = 1;
  } finally {
    scheduler.stop();
    poll.cancel();
    restart.cancel();
    clock.stop();
    final report = {
      'status': status,
      'failure': failure,
      'sourceSha':
          Platform.environment['ACCEPTANCE_SOURCE_SHA'] ?? 'unverified',
      'scope':
          'Production Dart checkpoint scheduler on ${Platform.operatingSystem}; real elapsed hour',
      'verifiedCheckpointUtc': verified.toUtc().toIso8601String(),
      'elapsedMicroseconds': clock.elapsedMicroseconds,
      'timeSource': 'monotonic Stopwatch; actual UTC deadline unchanged',
      'ordinaryPollCount': polls,
      'schedulerRecreated': restarted,
      'processRestartVerified': false,
      'osSleepWakeVerified': false,
      'physicalDeviceVerified': false,
      'providerCalls': 0,
      'events': events,
    };
    final output = File('build/hourly-standby/checkpoint-elapsed.json');
    await output.parent.create(recursive: true);
    await output.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );
    print(jsonEncode(report));
  }
}

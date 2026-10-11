import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../../lib/windows_sync_schedule.dart';

/// Actual production scheduler and actual elapsed time. No mocked clock, school
/// database, provider requests or remote ACKs. This is not OS sleep/wake proof.
void main() {
  test('production hourly scheduler requests once after a full elapsed hour', () async {
    final started = DateTime.now().toUtc();
    final stopwatch = Stopwatch()..start();
    final firstHourly = Completer<void>();
    final events = <Map<String, dynamic>>[];
    var phase = 'hourly_wait';
    var status = 'RUNNING';
    String? errorCategory;
    final schedule = WindowsSyncSchedule((delay) {
      events.add({
        'source': phase,
        'atUtc': DateTime.now().toUtc().toIso8601String(),
        'elapsedMilliseconds': stopwatch.elapsedMilliseconds,
        'requestedDelayMilliseconds': delay.inMilliseconds,
      });
      if (phase == 'hourly_wait' && !firstHourly.isCompleted) {
        firstHourly.complete();
      }
    });
    try {
      // Reconciliation cannot fire during this hour and cannot be confused with
      // the independently fixed one-hour production timer.
      schedule.start(const Duration(hours: 2));
      expect(schedule.hourly?.isActive, true);
      expect(schedule.reconciliation?.isActive, true);
      await firstHourly.future.timeout(const Duration(minutes: 64));
      final hourlyEvents = events.where((e) => e['source'] == 'hourly_wait').toList();
      expect(hourlyEvents, hasLength(1));
      expect(hourlyEvents.single['elapsedMilliseconds'],
          greaterThanOrEqualTo(const Duration(hours: 1).inMilliseconds));
      expect(DateTime.now().toUtc().difference(started).inMilliseconds,
          greaterThanOrEqualTo(const Duration(hours: 1).inMilliseconds));
      expect(hourlyEvents.single['requestedDelayMilliseconds'], 250);

      phase = 'wake_signal';
      schedule.wake();
      expect(events.last['source'], 'wake_signal');
      expect(events.last['requestedDelayMilliseconds'], 250);
      phase = 'reconnect_signal';
      schedule.reconnected();
      expect(events.last['source'], 'reconnect_signal');
      expect(events.last['requestedDelayMilliseconds'], 2000);
      final hourlyTimer = schedule.hourly!;
      final reconciliationTimer = schedule.reconciliation!;
      phase = 'stopped';
      schedule.stop();
      expect(hourlyTimer.isActive, false);
      expect(reconciliationTimer.isActive, false);
      expect(schedule.hourly, null);
      expect(schedule.reconciliation, null);
      final stoppedCount = events.length;
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(events, hasLength(stoppedCount));
      expect(events.where((e) => e['source'] == 'hourly_wait'), hasLength(1));
      expect(events.where((e) => e['source'] == 'wake_signal'), hasLength(1));
      expect(events.where((e) => e['source'] == 'reconnect_signal'), hasLength(1));
      status = 'PASS';
    } catch (error) {
      status = 'FAIL';
      errorCategory = error.runtimeType.toString();
      rethrow;
    } finally {
      schedule.stop();
      stopwatch.stop();
      final report = <String, dynamic>{
        'version': 1,
        'sourceSha': Platform.environment['GITHUB_SHA'] ?? 'local-uncommitted',
        'sourceRef': Platform.environment['GITHUB_REF'] ?? 'local',
        'startedAtUtc': started.toIso8601String(),
        'finishedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'elapsedMilliseconds': stopwatch.elapsedMilliseconds,
        'status': status,
        if (errorCategory != null) 'errorCategory': errorCategory,
        'hourlyRequestCount': events.where((e) => e['source'] == 'hourly_wait').length,
        'wakeSignalRequestCount': events.where((e) => e['source'] == 'wake_signal').length,
        'reconnectSignalRequestCount': events.where((e) => e['source'] == 'reconnect_signal').length,
        'events': events,
        'scope': 'Production Dart scheduler on hosted Windows; actual elapsed hour',
        'providerCalls': 0,
        'cloudAcknowledgements': 0,
        'schoolRecordsAccessed': false,
        'physicalDeviceVerified': false,
        'osSleepWakeVerified': false,
        'minimizedApplicationVerified': false,
        'networkReconnectVerified': false,
        'wakeAndReconnectCoverage': 'Direct production scheduler signal callbacks only',
      };
      final output = File('build/hourly-standby/elapsed.json');
      await output.parent.create(recursive: true);
      await output.writeAsString(const JsonEncoder.withIndent('  ').convert(report), flush: true);
      print(jsonEncode(report));
      print('Scheduler-only elapsed-hour result: $status; elapsed ms=${stopwatch.elapsedMilliseconds}; no provider calls.');
    }
  }, timeout: const Timeout(Duration(minutes: 70)));
}

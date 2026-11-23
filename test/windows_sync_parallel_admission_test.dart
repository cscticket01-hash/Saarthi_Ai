import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:saarthi_ai/windows_sync_parallel_admission.dart';

void main() {
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  Map<String, dynamic> notice(String id, String operation, int millis, {
    String state = 'pending',
    String schoolId = school,
    Map<String, dynamic>? data,
  }) => {
    'queueId': id,
    'schoolId': schoolId,
    'collection': 'school_notices',
    'documentId': id,
    'operationId': operation,
    'operation': 'set',
    'syncState': state,
    'queuedAtMillis': millis,
    'data': data ?? {'schoolId': schoolId, 'title': 'Independent notice'},
  };
  final person = {
    'queueId': 'person-one',
    'collection': 'students_directory',
    'documentId': 'person-one',
    'operationId': 'person-operation-000000001',
    'schoolId': school,
    'operation': 'set',
    'syncState': 'pending',
    'queuedAtMillis': 1,
  };

  test('independent plain notice can stage while a different person is pending', () {
    expect(oldestIndependentNotice([
      person, notice('notice-1', 'notice-operation-00000001', 2),
    ], schoolId: school, nowMillis: 100),
      {'queueId': 'notice-1', 'operationId': 'notice-operation-00000001'});
  });

  test('oldest notice review blocks newer notice; never bypass FIFO', () {
    expect(oldestIndependentNotice([
      notice('notice-new', 'notice-operation-00000002', 20),
      notice('notice-old', 'notice-operation-00000001', 10,
          state: 'needsAttention'),
    ], schoolId: school, nowMillis: 100), isNull);
  });

  test('global delete, school-policy change and foreign pending row block fast path', () {
    final message = notice('notice-1', 'notice-operation-00000001', 2);
    for (final owner in [
      {...person, 'operation': 'delete'},
      {...person, 'collection': 'school_settings'},
      {...person, 'schoolId': 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'},
    ]) {
      expect(oldestIndependentNotice([owner, message],
        schoolId: school, nowMillis: 100), isNull);
    }
  });

  test('targeted data, prior owner, quota and atomic reservations never bypass', () {
    final base = notice('notice-1', 'notice-operation-00000001', 2);
    for (final modified in [
      {...base, 'data': {'schoolId': school, 'studentId': 'student-1'}},
      {...base, 'priorCloudWrite': {'operationId': 'old'}},
      {...base, 'priorDeletion': {'operationId': 'old'}},
      {...base, 'atomicBundleId': 'atomic-owner'},
      {...base, 'retryAtMillis': 1000},
    ]) {
      expect(oldestIndependentNotice([person, modified],
        schoolId: school, nowMillis: 100), isNull);
    }
  });

  test('same notice successor is blocked until its older original settles', () {
    final old = notice('notice-a', 'notice-operation-00000001', 1,
        state: 'cloudAccepted');
    final next = notice('notice-a', 'notice-operation-00000002', 2);
    // The canonical local owner keeps the priorCloudWrite when the newer
    // generation shares the same document. That dependency must be honored.
    next['priorCloudWrite'] = {'operationId': old['operationId']};
    expect(oldestIndependentNotice([old, next],
      schoolId: school, nowMillis: 100), isNull);
  });

  test('two Cloudflare attempts start promptly and stay joined until both settle', () async {
    final people = Completer<void>();
    final messages = Completer<void>();
    final called = <String>[];
    final future = runIndependentCloudAdmissions(
      () { called.add('people'); return people.future; },
      () { called.add('notice'); return messages.future; },
    );
    expect(called, ['people', 'notice']);
    var finished = false;
    future.then((_) => finished = true);
    messages.complete();
    await Future<void>.delayed(Duration.zero);
    expect(finished, false);
    people.complete();
    await future;
    expect(finished, true);
  });
}

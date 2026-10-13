import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

import '../lib/document_processing_engine.dart';
import '../lib/document_pipeline.dart';
import '../lib/health/document_worker_owner.dart';
import '../lib/health/universal_health.dart';
import 'autonomous_infrastructure_repair_test.dart' show RepairHistory;

class FixtureImageHandle implements ImageWorkerHandle {
  final reply = Completer<Map<String, dynamic>>(), exit = Completer<void>();
  bool stopsExit = true;
  int stops = 0;
  @override
  Future<Map<String, dynamic>> get result => reply.future;
  @override
  Future<void> get exited => exit.future;
  @override
  void stop() {
    stops++;
    if (stopsExit && !exit.isCompleted) exit.complete();
  }

  void succeed(Map<String, dynamic> result) {
    reply.complete(result);
    if (!exit.isCompleted) exit.complete();
  }

  void fail(Object error) {
    reply.completeError(error);
    if (!exit.isCompleted) exit.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const scope = HealthContext('school-A', 'profile-A');
  final bytes = Uint8List.fromList(
    image.encodePng(image.Image(width: 40, height: 60)),
  );
  final input = <String, dynamic>{'bytes': bytes};
  Map<String, dynamic> verified() => {
    ...DocumentProcessingEngine.process(input),
    '__imageInputFingerprint': DocumentWorkerOwner.inputFingerprint(input),
  };
  test('autonomous owner repair completes the original processing request exactly once', () async {
    final engine = UniversalHealth(store: RepairHistory());
    await engine.bind(scope);
    var calls = 0;
    final owner = DocumentWorkerOwner(
      engine,
      autoRecover: true,
      spawn: (_) {
        final h = FixtureImageHandle();
        calls++;
        Timer.run(
          () => calls == 1
              ? h.fail(const ImageWorkerFault())
              : h.succeed(verified()),
        );
        return h;
      },
    );
    engine.register(owner.provider());
    try {
      final original = List<int>.from(bytes),
          first = owner.process(input),
          second = owner.process(input);
      final result = await first;
      await second;
      expect(calls, 2);
      expect(bytes, original);
      expect(result['originalBytes'], bytes.length);
      expect(engine.history.where((e) => e.stage == 'verified').length, 1);
      expect(
        engine.observations['document-worker']!.state,
        HealthState.healthy,
      );
    } finally {
      await engine.dispose();
    }
  });
  test(
    'real owned isolate processes and independently verifies image result',
    () async {
      final engine = UniversalHealth(store: RepairHistory());
      await engine.bind(scope);
      final owner = DocumentWorkerOwner(engine);
      engine.register(owner.provider());
      try {
        final before = List<int>.from(bytes),
            result = await owner.process(input);
        expect(image.decodeImage(result['optimized'] as Uint8List)!.width, 40);
        expect(bytes, before);
        await engine.check('document-worker');
        expect(
          engine.observations['document-worker']!.state,
          HealthState.healthy,
        );
        (result['optimized'] as Uint8List).fillRange(0, 12, 0);
        final cached = await owner.process(input);
        expect(image.decodeImage(cached['optimized'] as Uint8List), isNotNull);
      } finally {
        await engine.dispose();
      }
    },
  );
  for (final fault in ['timeout', 'crash']) {
    test(
      '$fault: owner-approved automatic retry verifies result and preserves original/identity',
      () async {
        final engine = UniversalHealth(store: RepairHistory());
        await engine.bind(scope);
        var calls = 0;
        final handles = <FixtureImageHandle>[];
        final owner = DocumentWorkerOwner(
          engine,
          deadline: const Duration(milliseconds: 15),
          spawn: (_) {
            final h = FixtureImageHandle();
            handles.add(h);
            calls++;
            if (calls == 1 && fault == 'crash')
              Timer.run(() => h.fail(const ImageWorkerFault()));
            if (calls == 2) Timer.run(() => h.succeed(verified()));
            return h;
          },
        );
        engine.register(owner.provider());
        try {
          final before = List<int>.from(bytes);
          await expectLater(
            owner.process(input),
            fault == 'timeout'
                ? throwsA(isA<TimeoutException>())
                : throwsA(isA<ImageWorkerFault>()),
          );
          expect(owner.canRepair, true);
          await engine.check('document-worker');
          expect(await engine.recover('document-worker'), true);
          expect(calls, 2);
          expect(engine.history.last.stage, 'verified');
          expect(bytes, before);
          expect(await engine.recover('document-worker'), false);
          expect(calls, 2);
          final cached = await owner.process(input);
          expect(calls, 2);
          expect(cached['originalBytes'], bytes.length);
        } finally {
          await engine.dispose();
        }
      },
    );
  }
  test(
    'unsettled owned worker is quarantined; no duplicate until actual exit',
    () async {
      final engine = UniversalHealth(store: RepairHistory());
      await engine.bind(scope);
      var calls = 0;
      final h = FixtureImageHandle()..stopsExit = false;
      final owner = DocumentWorkerOwner(
        engine,
        deadline: const Duration(milliseconds: 5),
        exitDeadline: const Duration(milliseconds: 5),
        spawn: (_) {
          calls++;
          return h;
        },
      );
      engine.register(owner.provider());
      try {
        await expectLater(
          owner.process(input),
          throwsA(isA<TimeoutException>()),
        );
        await engine.check('document-worker');
        expect(owner.canRepair, false);
        expect(
          engine.observations['document-worker']!.state,
          HealthState.needsAttention,
        );
        expect(await engine.recover('document-worker'), false);
        expect(calls, 1);
        h.exit.complete();
        h.reply.complete(verified());
        await Future<void>.delayed(Duration.zero);
        expect(owner.canRepair, true);
        expect(engine.history.any((e) => e.stage == 'verified'), false);
      } finally {
        await engine.dispose();
      }
    },
  );
  test(
    'cross-school and pause cannot authorize a retained image retry',
    () async {
      final engine = UniversalHealth(store: RepairHistory());
      await engine.bind(scope);
      var calls = 0;
      final owner = DocumentWorkerOwner(
        engine,
        spawn: (_) {
          calls++;
          final h = FixtureImageHandle();
          Timer.run(() => h.fail(const ImageWorkerFault()));
          return h;
        },
      );
      engine.register(owner.provider());
      try {
        await expectLater(
          owner.process(input),
          throwsA(isA<ImageWorkerFault>()),
        );
        await engine.bind(const HealthContext('school-B', 'profile-B'));
        await engine.check('document-worker');
        expect(owner.canRepair, false);
        expect(await engine.recover('document-worker'), false);
        expect(calls, 1);
        await engine.bind(scope);
        engine.pause();
        expect(owner.canRepair, false);
        expect(await engine.recover('document-worker'), false);
      } finally {
        await engine.dispose();
      }
    },
  );
  test(
    'invalid media is not retried and failed recovery never reports Healthy',
    () async {
      final engine = UniversalHealth(store: RepairHistory());
      await engine.bind(scope);
      var calls = 0;
      final owner = DocumentWorkerOwner(
        engine,
        spawn: (_) {
          calls++;
          final h = FixtureImageHandle();
          Timer.run(
            () => h.fail(
              calls == 1
                  ? const ImageWorkerFault()
                  : const FormatException('invalid fixture'),
            ),
          );
          return h;
        },
      );
      engine.register(owner.provider());
      try {
        await expectLater(
          owner.process(input),
          throwsA(isA<ImageWorkerFault>()),
        );
        await engine.check('document-worker');
        expect(await engine.recover('document-worker'), false);
        expect(calls, 2);
        expect(owner.canRepair, false);
        expect(
          engine.observations['document-worker']!.state,
          HealthState.needsAttention,
        );
        expect(engine.history.last.stage, 'unverified');
      } finally {
        await engine.dispose();
      }
    },
  );
  test('lost admission survives restart without replaying a private input or granting success', () async {
    final store = RepairHistory(), now = DateTime.utc(2026, 10, 13);
    store.records[scope.fingerprint] = [
      HealthEvent(
        'document-worker',
        HealthFailure.timeout,
        'started',
        now,
        'a' * 64,
        playbook: 'restart-owned-image-worker',
        providerVersion: '2.1',
      ),
    ];
    final engine = UniversalHealth(
      store: store,
      now: () => now.add(const Duration(seconds: 1)),
    );
    final owner = DocumentWorkerOwner(engine);
    engine.register(owner.provider());
    try {
      await engine.bind(scope);
      await engine.check('document-worker');
      expect(engine.pendingQuarantineVerification, 1);
      expect(owner.canRepair, false);
      expect(await engine.recover('document-worker'), false);
    } finally {
      await engine.dispose();
    }
  });
  test(
    'borrowed output with another source fingerprint cannot become verified',
    () async {
      final engine = UniversalHealth(store: RepairHistory());
      await engine.bind(scope);
      final owner = DocumentWorkerOwner(
        engine,
        spawn: (_) {
          final h = FixtureImageHandle();
          Timer.run(
            () =>
                h.succeed({...verified(), '__imageInputFingerprint': '0' * 64}),
          );
          return h;
        },
      );
      engine.register(owner.provider());
      try {
        await expectLater(owner.process(input), throwsFormatException);
        await engine.check('document-worker');
        expect(owner.canRepair, false);
        expect(
          engine.observations['document-worker']!.state,
          HealthState.needsAttention,
        );
      } finally {
        await engine.dispose();
      }
    },
  );
  test('school change during an admitted repair prevents its late success from committing', () async {
    final engine = UniversalHealth(store: RepairHistory());
    await engine.bind(scope);
    var calls = 0;
    final repair = FixtureImageHandle(), ready = Completer<void>();
    final owner = DocumentWorkerOwner(
      engine,
      spawn: (_) {
        calls++;
        if (calls == 2) {
          ready.complete();
          return repair;
        }
        final h = FixtureImageHandle();
        Timer.run(() => h.fail(const ImageWorkerFault()));
        return h;
      },
    );
    engine.register(owner.provider());
    try {
      await expectLater(owner.process(input), throwsA(isA<ImageWorkerFault>()));
      await engine.check('document-worker');
      final attempt = engine.recover('document-worker');
      await ready.future;
      await engine.bind(const HealthContext('school-B', 'profile-B'));
      repair.succeed(verified());
      expect(await attempt, false);
      expect(owner.canRepair, false);
      expect(
        engine.observations['document-worker']!.state,
        isNot(HealthState.healthy),
      );
    } finally {
      await engine.dispose();
    }
  });
  test(
    'coalesced processing returns one worker and retains protected source',
    () async {
      final engine = UniversalHealth(store: RepairHistory());
      await engine.bind(scope);
      var calls = 0;
      final h = FixtureImageHandle(),
          owner = DocumentWorkerOwner(
            engine,
            spawn: (_) {
              calls++;
              return h;
            },
          );
      try {
        final first = owner.process(input), second = owner.process(input);
        expect(identical(first, second), true);
        await Future<void>.delayed(Duration.zero);
        expect(calls, 1);
        h.succeed(verified());
        await first;
        await second;
      } finally {
        await engine.dispose();
      }
    },
  );
  test('pipeline cached output cannot be poisoned by a caller mutating the returned image', () async {
    final original = List<int>.from(bytes);
    final first = await DocumentPipeline.process(
      bytes,
      'image/png',
      scope: 'fixture-private',
    );
    (first['optimized'] as Uint8List).fillRange(0, 12, 0);
    first['mimeType'] = 'broken';
    final second = await DocumentPipeline.process(
      bytes,
      'image/png',
      scope: 'fixture-private',
    );
    expect(image.decodeImage(second['optimized'] as Uint8List), isNotNull);
    expect(second['mimeType'], isNot('broken'));
    expect(bytes, original);
  });
}

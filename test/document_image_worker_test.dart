import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

import '../lib/document_image_worker.dart';
import '../lib/document_processing_engine.dart';
import '../lib/document_pipeline.dart';

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

  void succeed(Map<String, dynamic> value) {
    reply.complete(value);
    if (!exit.isCompleted) exit.complete();
  }

  void fail(Object error) {
    reply.completeError(error);
    if (!exit.isCompleted) exit.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final bytes = Uint8List.fromList(
    image.encodePng(image.Image(width: 40, height: 60)),
  );
  final input = <String, dynamic>{'bytes': bytes};
  Map<String, dynamic> verified() => {
    ...DocumentProcessingEngine.process(input),
    '__imageInputFingerprint': DocumentImageWorker.inputFingerprint(input),
  };
  test(
    'actual isolated processing validates output and preserves source bytes',
    () async {
      final before = List<int>.from(bytes),
          result = await DocumentImageWorker().process(
            input,
            scope: 'school-A/profile-A',
          );
      expect(image.decodeImage(result['optimized'] as Uint8List), isNotNull);
      expect(result['__imageInputFingerprint'], isNull);
      expect(bytes, before);
    },
  );
  test(
    'worker failure surfaces once without automatic restart or retry',
    () async {
      var calls = 0;
      final owner = DocumentImageWorker(
        spawn: (_) {
          calls++;
          final h = FixtureImageHandle();
          Timer.run(() => h.fail(const ImageWorkerFault()));
          return h;
        },
      );
      await expectLater(owner.process(input), throwsA(isA<ImageWorkerFault>()));
      expect(calls, 1);
    },
  );
  test(
    'deadline stops owned worker and surfaces timeout without a retry',
    () async {
      final h = FixtureImageHandle();
      var calls = 0;
      final owner = DocumentImageWorker(
        deadline: const Duration(milliseconds: 10),
        spawn: (_) {
          calls++;
          return h;
        },
      );
      await expectLater(owner.process(input), throwsA(isA<TimeoutException>()));
      expect(h.stops, 1);
      expect(calls, 1);
    },
  );
  test('malformed worker result never replaces original input', () async {
    final before = List<int>.from(bytes);
    final owner = DocumentImageWorker(
      spawn: (_) {
        final h = FixtureImageHandle();
        Timer.run(() => h.succeed({...verified(), 'width': 9999}));
        return h;
      },
    );
    await expectLater(owner.process(input), throwsFormatException);
    expect(bytes, before);
  });
  test(
    'same-scope callers share work but each receives a defensive copy',
    () async {
      var calls = 0;
      final h = FixtureImageHandle(),
          owner = DocumentImageWorker(
            spawn: (_) {
              calls++;
              return h;
            },
          );
      final one = owner.process(input, scope: 'A'),
          two = owner.process(input, scope: 'A');
      await Future<void>.delayed(Duration.zero);
      h.succeed(verified());
      final a = await one;
      (a['optimized'] as Uint8List).fillRange(0, 12, 0);
      final b = await two;
      expect(calls, 1);
      expect(image.decodeImage(b['optimized'] as Uint8List), isNotNull);
    },
  );
  test('different school scopes never share worker requests', () async {
    final handles = <FixtureImageHandle>[];
    final owner = DocumentImageWorker(
      spawn: (_) {
        final h = FixtureImageHandle();
        handles.add(h);
        return h;
      },
    );
    final a = owner.process(input, scope: 'A'),
        b = owner.process(input, scope: 'B');
    await Future<void>.delayed(Duration.zero);
    expect(handles.length, 2);
    for (final h in handles) h.succeed(verified());
    await Future.wait([a, b]);
  });
  test(
    'bounded admission retains capacity until an unsettled isolate exits',
    () async {
      final handles = <FixtureImageHandle>[];
      final owner = DocumentImageWorker(
        deadline: const Duration(milliseconds: 10),
        exitDeadline: const Duration(milliseconds: 10),
        spawn: (_) {
          final h = FixtureImageHandle()..stopsExit = false;
          handles.add(h);
          return h;
        },
      );
      final futures = [
        for (var n = 0; n < 8; n++) owner.process(input, scope: 'scope-$n'),
      ];
      // Attach handlers before the first deadline expires.
      final assertions = [
        for (final f in futures)
          expectLater(f, throwsA(isA<TimeoutException>())),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(handles.length, 2);
      await expectLater(
        owner.process(input, scope: 'overflow'),
        throwsFormatException,
      );
      for (var n = 0; n < 8; n++) {
        while (handles.length <= n)
          await Future<void>.delayed(const Duration(milliseconds: 1));
        if (!handles[n].exit.isCompleted) handles[n].exit.complete();
      }
      await Future.wait(assertions);
    },
  );
  test(
    'pipeline school cache cannot be poisoned by a returned image mutation',
    () async {
      final before = List<int>.from(bytes),
          first = await DocumentPipeline.process(
            bytes,
            'image/png',
            scope: 'school-A',
          );
      (first['optimized'] as Uint8List).fillRange(0, 12, 0);
      first['mimeType'] = 'broken';
      final second = await DocumentPipeline.process(
        bytes,
        'image/png',
        scope: 'school-A',
      );
      expect(image.decodeImage(second['optimized'] as Uint8List), isNotNull);
      expect(second['mimeType'], isNot('broken'));
      expect(bytes, before);
      final other = await DocumentPipeline.process(
        bytes,
        'image/png',
        scope: 'school-B',
      );
      expect(image.decodeImage(other['optimized'] as Uint8List), isNotNull);
    },
  );
}

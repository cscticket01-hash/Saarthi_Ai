import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_remote_change_feed.dart';
import '../lib/windows_connect/school_drive_images.dart';

Map<String, dynamic> event(
  String school, {
  List<String> collections = const [],
}) => {
  'success': true,
  'schoolId': school,
  'changeFeedVersion': 1,
  'reset': false,
  'cursor': '00000000-0000-4000-8000-000000000000:1',
  'collections': collections,
};

void main() {
  test('verified listener health disables duplicate discovery until an error', () {
    fakeAsync((clock) {
      var failRead = false, verified = 0;
      final feed = WindowsRemoteChangeFeed(
        allowedCollections: {'notices'},
        onVerified: () => verified++,
        read: (school, cursor) async {
          if (failRead) throw StateError('Offline');
          return event(school);
        },
        onHint: (_) {},
      );
      feed.start('profile', 'school');
      expect(feed.isHealthy, false);
      clock.flushMicrotasks();
      expect(feed.isHealthy, true);
      expect(verified, 1);
      failRead = true;
      clock.elapse(const Duration(milliseconds: 250));
      clock.flushMicrotasks();
      expect(feed.isHealthy, false);
      failRead = false;
      clock.elapse(const Duration(seconds: 2));
      clock.flushMicrotasks();
      expect(feed.isHealthy, true);
      expect(verified, 2);
      feed.stop();
      expect(feed.isHealthy, false);
    });
  });
  testWidgets(
    'image rebuild retains its download future; changed source replaces it',
    (tester) async {
      Widget view(String source, double width) => MaterialApp(
        home: Scaffold(
          body: schoolNetworkImage(source, width: width, height: 32),
        ),
      );
      await tester.pumpWidget(view('invalid-image-a', 32));
      final finder = find.byWidgetPredicate(
        (w) => w is FutureBuilder<Uint8List?>,
      );
      final first = tester.widget<FutureBuilder<Uint8List?>>(finder).future;
      await tester.pumpWidget(view('invalid-image-a', 64));
      expect(
        identical(
          first,
          tester.widget<FutureBuilder<Uint8List?>>(finder).future,
        ),
        true,
      );
      await tester.pumpWidget(view('invalid-image-b', 64));
      expect(
        identical(
          first,
          tester.widget<FutureBuilder<Uint8List?>>(finder).future,
        ),
        false,
      );
      await tester.pump();
    },
  );

  test(
    'cursor reset requests head discovery without claiming every collection changed',
    () {
      fakeAsync((clock) {
        var resets = 0, calls = 0;
        final hints = <Set<String>>[];
        final reader = WindowsRemoteChangeFeed(
          allowedCollections: {'fee_payments'},
          read: (school, cursor) async {
            calls++;
            return {
              ...event(school, collections: ['fee_payments']),
              'reset': calls == 1,
            };
          },
          onReset: () => resets++,
          onHint: hints.add,
        );
        reader.start('a', 'school-a');
        clock.flushMicrotasks();
        expect(resets, 1);
        expect(hints, isEmpty);
        clock.elapse(const Duration(milliseconds: 250));
        clock.flushMicrotasks();
        expect(hints, [
          {'fee_payments'},
        ]);
        reader.stop();
      });
    },
  );
  test(
    'verified hints schedule changed collections; stop cancels reconnect',
    () {
      fakeAsync((clock) {
        final hints = <Set<String>>[];
        var calls = 0;
        final reader = WindowsRemoteChangeFeed(
          allowedCollections: {'fee_payments'},
          read: (school, cursor) async {
            calls++;
            return event(school, collections: ['fee_payments']);
          },
          onHint: hints.add,
        );
        reader.start('profile-a', 'school-a');
        clock.flushMicrotasks();
        expect(hints, [
          {'fee_payments'},
        ]);
        expect(calls, 1);
        reader.stop();
        clock.elapse(const Duration(minutes: 2));
        expect(calls, 1);
      });
    },
  );
  test(
    'late response from previous school cannot schedule or advance new school',
    () {
      fakeAsync((clock) {
        final pending = <String, Completer<Map<String, dynamic>>>{};
        final hints = <Set<String>>[];
        final reader = WindowsRemoteChangeFeed(
          allowedCollections: {'fee_payments'},
          read: (school, cursor) => (pending[school] = Completer()).future,
          onHint: hints.add,
        );
        reader.start('a', 'school-a');
        reader.start('b', 'school-b');
        pending['school-a']!.complete(
          event('school-a', collections: ['fee_payments']),
        );
        clock.flushMicrotasks();
        expect(hints, isEmpty);
        pending['school-b']!.complete(
          event('school-b', collections: ['fee_payments']),
        );
        clock.flushMicrotasks();
        expect(hints, [
          {'fee_payments'},
        ]);
        reader.stop();
      });
    },
  );
  test('foreign and malformed hints fail visibly with bounded backoff', () {
    fakeAsync((clock) {
      var calls = 0, errors = 0, verified = 0;
      final reader = WindowsRemoteChangeFeed(
        allowedCollections: {'fee_payments'},
        onVerified: () => verified++,
        read: (school, cursor) async {
          calls++;
          return event('another-school', collections: ['fee_payments']);
        },
        onHint: (_) => fail('Unverified hint admitted'),
        onError: (_) => errors++,
      );
      reader.start('a', 'school-a');
      clock.flushMicrotasks();
      expect(errors, 1);
      expect(verified, 0);
      clock.elapse(const Duration(seconds: 1));
      expect(calls, 1);
      clock.elapse(const Duration(seconds: 1));
      clock.flushMicrotasks();
      expect(calls, 2);
      reader.stop();
    });
  });
}

import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/mobile/published_id_card.dart';

void main() {
  testWidgets('missing card refreshes and opens newly published exact PDF', (
    tester,
  ) async {
    final pdf = Uint8List.fromList([1, 2, 3]);
    var ready = false, opened = 0, refreshed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PublishedIdCard(
            load: () async => ready ? pdf : null,
            refresh: () async {
              refreshed++;
              ready = true;
            },
            rasterize: (_) async =>
                throw StateError('Native preview unavailable'),
            open: (bytes) async {
              expect(bytes, pdf);
              opened++;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Open my ID card'), findsNothing);
    expect(find.textContaining('preparing your ID card'), findsOneWidget);
    await tester.tap(find.text('Refresh ID card'));
    await tester.pumpAndSettle();
    expect(refreshed, 1);
    expect(find.text('Your school ID card is ready.'), findsOneWidget);
    await tester.tap(find.text('Open my ID card'));
    await tester.pumpAndSettle();
    expect(opened, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('temporary download failure stays retryable', (tester) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PublishedIdCard(
            load: () async {
              if (++calls == 1) throw StateError('offline');
              return Uint8List(3);
            },
            refresh: () async {},
            rasterize: (_) async => throw StateError('raster'),
            open: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Unable to load'), findsOneWidget);
    await tester.tap(find.text('Refresh ID card'));
    await tester.pumpAndSettle();
    expect(find.text('Open my ID card'), findsOneWidget);
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'school/profile key change discards previous PDF and in-flight result',
    (tester) async {
      final old = Uint8List.fromList([1]), current = Uint8List.fromList([2]);
      Widget card(String school, Uint8List pdf) => MaterialApp(
        home: Scaffold(
          body: PublishedIdCard(
            key: ValueKey(school),
            load: () async => pdf,
            refresh: () async {},
            rasterize: (_) async => throw StateError('raster'),
            open: (bytes) async => expect(bytes, current),
          ),
        ),
      );
      await tester.pumpWidget(card('A/student', old));
      await tester.pumpAndSettle();
      await tester.pumpWidget(card('B/student', current));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open my ID card'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

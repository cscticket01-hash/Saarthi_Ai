import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/id_card_manifest.dart';
import '../lib/windows_manifest_record_id_preview.dart';

void main() {
  final sample = IdCardManifest.fromJson({
    'version': 1,
    'id': 'synthetic-classic-school-id',
    'canvasWidth': 216,
    'canvasHeight': 342.4,
    'printWidthMm': 54,
    'printHeightMm': 85.6,
    'regions': [
      {'key': 'name', 'side': 'front', 'kind': 'text',
       'x': 10, 'y': 10, 'width': 185, 'height': 24,
       'fontSize': 14, 'minFontSize': 8, 'textColor': '#000000'},
      {'key': 'qr', 'side': 'back', 'kind': 'qr',
       'x': 25, 'y': 25, 'width': 90, 'height': 90},
    ],
  });

  testWidgets('selected native card uses the manifest front/back and record fields without a PDF', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: SingleChildScrollView(child: WindowsManifestRecordIdPreview(
        manifest: sample,
        record: const {'name': 'Verified Test Pupil'},
        backgrounds: const {}, images: const {}, qr: 'test-only-qr-data',
      )),
    )));
    expect(find.byKey(const ValueKey('record-id-front')), findsOneWidget);
    expect(find.byKey(const ValueKey('record-id-back')), findsOneWidget);
    expect(find.byKey(const ValueKey('id-data-front-name')), findsOneWidget);
    expect(find.text('Verified Test Pupil'), findsOneWidget);
    expect(find.textContaining('no PDF'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('selected identity re-renders when member data changes', (tester) async {
    Widget card(String name) => MaterialApp(home: Scaffold(
      body: SingleChildScrollView(child: WindowsManifestRecordIdPreview(
        manifest: sample, record: {'name': name},
        backgrounds: const {}, images: const {},
      )),
    ));
    await tester.pumpWidget(card('First Pupil'));
    expect(find.text('First Pupil'), findsOneWidget);
    await tester.pumpWidget(card('Second Pupil'));
    expect(find.text('First Pupil'), findsNothing);
    expect(find.text('Second Pupil'), findsOneWidget);
  });
}

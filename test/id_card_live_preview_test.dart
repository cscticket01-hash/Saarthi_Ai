import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/id_card_live_preview.dart';
import '../lib/id_card_manifest.dart';

void main() {
  final manifest = IdCardManifest.fromJson({
    'version': 1,
    'id': 'live-preview-test',
    'canvasWidth': 200,
    'canvasHeight': 300,
    'printWidthMm': 54,
    'printHeightMm': 81,
    'regions': [
      {
        'key': 'name', 'side': 'front', 'kind': 'text',
        'x': 15, 'y': 12, 'width': 170, 'height': 30,
        'fontSize': 15,
      },
      {
        'key': 'qr', 'side': 'back', 'kind': 'qr',
        'x': 50, 'y': 50, 'width': 80, 'height': 80,
      }
    ],
  });

  testWidgets('live front/back preview draws person data without PDF export',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(
        width: 500,
        child: IdCardLivePreview(
          template: manifest,
          data: const {'name': 'Sample Student'},
          qr: 'student-school-record-v1',
        ),
      )),
    ));
    expect(find.text('Sample Student'), findsOneWidget);
    expect(find.byType(IdCardLivePreview), findsOneWidget);
    // There is no Printing/PdfPreview dependency or file creation in this
    // presentation widget. Export stays owned by the existing PDF pipeline.
  });

  testWidgets('preview does not require a PDF or even an available portrait',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(
        width: 200,
        child: IdCardLivePreview(
          template: manifest,
          data: const {'name': 'No Photo'},
          qr: '',
          images: const <String, Uint8List>{},
        ),
      )),
    ));
    expect(find.text('No Photo'), findsOneWidget);
  });
}

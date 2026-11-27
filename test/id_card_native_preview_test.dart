import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/id_card_manifest.dart';
import '../lib/id_card_native_preview.dart';

void main() {
  final template=IdCardManifest.fromJson({
    'id':'test-native','version':1,'canvasWidth':100,'canvasHeight':60,
    'printWidthMm':85.6,'printHeightMm':51.36,'regions':[
      {'key':'name','side':'front','kind':'text','x':2,'y':2,'width':90,'height':20,'fontSize':12},
      {'key':'backText','side':'back','kind':'text','x':2,'y':2,'width':90,'height':20,'fontSize':12},
    ],
  });
  testWidgets('native preview switches sides and exports only on explicit download', (tester) async {
    var count=0;
    await tester.pumpWidget(MaterialApp(home:NativeIdCardPreview(template:template,
      data:const {'name':'Fictional person','backText':'Back details'},
      onDownload:() async {count++;})));
    await tester.pumpAndSettle();
    expect(find.text('Fictional person'),findsOneWidget);
    expect(find.text('Back details'),findsOneWidget);
    expect(count,0);
    await tester.tap(find.text('Front only'));
    await tester.pumpAndSettle();
    expect(find.text('Back details'),findsNothing);
    expect(count,0);
    await tester.ensureVisible(find.text('Download full PDF'));
    await tester.tap(find.text('Download full PDF'));
    await tester.pumpAndSettle();
    expect(count,1);
  });
  testWidgets('front-only print uses a 300 DPI image without requesting PDF', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1000);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    var downloads = 0;
    Completer<List<int>>? printed;
    var printCalls = 0;
    await tester.pumpWidget(MaterialApp(home: NativeIdCardPreview(
      template: template,
      data: const {'name': 'Synthetic person', 'backText': 'Back details'},
      onDownload: () async { downloads++; },
      onPrint: (pages) async {
        printCalls++;
        printed?.complete([pages.length, pages.single.width, pages.single.height]);
      },
    )));
    await tester.tap(find.text('Front only'));
    await tester.pumpAndSettle();
    expect(printCalls, 0);
    final printButton = tester.widget<OutlinedButton>(
      find.ancestor(
        of: find.text('Print'),
        matching: find.byWidgetPredicate((widget) => widget is OutlinedButton),
      ),
    );
    final result = await tester.runAsync(() {
      final completion = printed = Completer<List<int>>();
      printButton.onPressed!();
      return completion.future.timeout(const Duration(seconds: 15), onTimeout: () => []);
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Print failed'), findsNothing);
    expect(result, [1, 1012, 607]);
    expect(downloads, 0);
  });

  testWidgets('production print callback receives the selected side without screenshot capture', (tester) async {
    final sides=<bool>[];
    await tester.pumpWidget(MaterialApp(home:NativeIdCardPreview(template:template,
      data:const {'name':'Synthetic person','backText':'Back details'},
      onPrintDocument:(frontOnly) async { sides.add(frontOnly); })));
    await tester.tap(find.text('Front only'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Print'));
    await tester.tap(find.text('Print'));
    await tester.pumpAndSettle();
    expect(sides,[true]);
    await tester.ensureVisible(find.text('Front + back'));
    await tester.tap(find.text('Front + back'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Print'));
    await tester.tap(find.text('Print'));
    await tester.pumpAndSettle();
    expect(sides,[true,false]);
  });
  testWidgets('Green Blue Modern only invokes export on Download ID Card', (tester) async {
    final frontOnly = IdCardManifest.fromJson({
      'id':'student-green-blue-modern-v1','version':1,'canvasWidth':100,'canvasHeight':60,
      'printWidthMm':85.6,'printHeightMm':51.36,
      'regions':[{'key':'name','side':'front','kind':'text','x':2,'y':2,'width':90,'height':20,'fontSize':12}],
    });
    var downloads = 0, prints = 0;
    await tester.pumpWidget(MaterialApp(home:NativeIdCardPreview(template:frontOnly,
      data:const {'name':'Synthetic student'}, onDownload:() async { downloads++; },
      onPrintDocument:(_) async { prints++; })));
    await tester.pumpAndSettle();
    expect(downloads,0); expect(prints,0);
    expect(find.text('Print'),findsNothing);
    await tester.ensureVisible(find.text('Download ID Card'));
    await tester.tap(find.text('Download ID Card'));
    await tester.pumpAndSettle();
    expect(downloads,1); expect(prints,0);
  });
  testWidgets('a front-only manifest renders without a back-side selector', (tester) async {
    final frontOnly = IdCardManifest.fromJson({
      'id': 'test-front-only', 'version': 1, 'canvasWidth': 100, 'canvasHeight': 60,
      'printWidthMm': 85.6, 'printHeightMm': 51.36,
      'regions': [
        {'key': 'name', 'side': 'front', 'kind': 'text',
         'x': 2, 'y': 2, 'width': 90, 'height': 20, 'fontSize': 12},
      ],
    });
    await tester.pumpWidget(MaterialApp(home: NativeIdCardPreview(
      template: frontOnly, data: const {'name': 'Synthetic student'},
    )));
    expect(frontOnly.hasBack, isFalse);
    expect(find.text('Synthetic student'), findsOneWidget);
    expect(find.text('Front + back'), findsNothing);
  });

}

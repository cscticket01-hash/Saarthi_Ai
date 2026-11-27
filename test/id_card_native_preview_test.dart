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
  testWidgets('native preview shows front left and back right, exports only on explicit download', (tester) async {
    var count=0;
    await tester.pumpWidget(MaterialApp(home:NativeIdCardPreview(template:template,
      data:const {'name':'Fictional person','backText':'Back details'},
      onDownload:() async {count++;})));
    await tester.pumpAndSettle();
    expect(find.text('Fictional person'),findsOneWidget);
    expect(find.text('Back details'),findsOneWidget);
    expect(count,0);
    expect(find.text('Front only'), findsNothing);
    expect(find.text('Front + back'), findsNothing);
    final front = tester.getRect(find.byKey(const ValueKey('id-card-front')));
    final back = tester.getRect(find.byKey(const ValueKey('id-card-back')));
    expect(front.right, lessThan(back.left));
    expect(front.top, back.top);
    expect(front.size, back.size);
    expect(count,0);
    await tester.ensureVisible(find.text('Download full PDF'));
    await tester.tap(find.text('Download full PDF'));
    await tester.pumpAndSettle();
    expect(count,1);
  });
  testWidgets('two-sided print uses two 300 DPI images without requesting PDF', (tester) async {
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
        printed?.complete([pages.length, pages.first.width, pages.first.height,
          pages.last.width, pages.last.height]);
      },
    )));
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
    expect(result, [2, 1012, 607, 1012, 607]);
    expect(downloads, 0);
  });

  testWidgets('production print callback receives both sides without screenshot capture', (tester) async {
    final sides=<bool>[];
    await tester.pumpWidget(MaterialApp(home:NativeIdCardPreview(template:template,
      data:const {'name':'Synthetic person','backText':'Back details'},
      onPrintDocument:(frontOnly) async { sides.add(frontOnly); })));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Print'));
    await tester.tap(find.text('Print'));
    await tester.pumpAndSettle();
    expect(sides,[false]);
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
    final printed = <bool>[];
    await tester.pumpWidget(MaterialApp(home: NativeIdCardPreview(
      template: frontOnly, data: const {'name': 'Synthetic student'},
      onPrintDocument: (frontOnly) async { printed.add(frontOnly); },
    )));
    await tester.pumpAndSettle();
    expect(frontOnly.hasBack, isFalse);
    expect(find.text('Synthetic student'), findsOneWidget);
    expect(find.text('Front + back'), findsNothing);
    expect(find.text('Front only'), findsNothing);
    expect(find.byKey(const ValueKey('id-card-back')), findsNothing);
    final card = tester.getRect(find.byKey(const ValueKey('id-card-front')));
    final body = tester.getRect(find.byType(ListView));
    expect(card.center.dx, closeTo(body.center.dx, 0.01));
    await tester.ensureVisible(find.text('Print'));
    await tester.tap(find.text('Print'));
    await tester.pumpAndSettle();
    expect(printed, [true]);
  });

  testWidgets('narrow preview keeps equal sides in one row and actions below', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(350, 650);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(MaterialApp(home: NativeIdCardPreview(
      template: template, data: const {'name': 'Synthetic', 'backText': 'Details'},
      onPrintDocument: (_) async {}, onDownload: () async {},
    )));
    await tester.pumpAndSettle();
    final front = tester.getRect(find.byKey(const ValueKey('id-card-front')));
    final back = tester.getRect(find.byKey(const ValueKey('id-card-back')));
    expect(front.right, lessThan(back.left));
    expect(front.size, back.size);
    expect(back.right, lessThanOrEqualTo(350));
    expect(tester.getTopLeft(find.text('Print')).dy, greaterThan(back.bottom));
    expect(tester.getTopLeft(find.text('Download full PDF')).dy,
        greaterThan(tester.getTopLeft(find.text('Print')).dy));
    expect(tester.takeException(), isNull);
  });

}

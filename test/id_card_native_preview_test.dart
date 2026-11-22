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
}

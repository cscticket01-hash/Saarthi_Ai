import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_device_management.dart';

void main() {
  final own = 'a' * 64, other = 'b' * 64;
  Map<String,dynamic> response({bool revoked = false}) => {'success':true,'serverTime':1792363200000,'devices':[
    {'deviceIdentity':own,'name':'School Office PC','status':'active','current':true,'activity':'recently_seen','lastSeenAt':1792363200000},
    {'deviceIdentity':other,'name':'Accounts PC','status':revoked ? 'revoked':'active','current':false,'activity':revoked ? 'revoked':'unknown','lastSeenAt':1792359600000},
  ]};
  Future<void> close(WidgetTester tester) async => tester.pumpWidget(const SizedBox());
  testWidgets('verified counts, current-PC protection and real revoke readback', (tester) async {
    var revoked = false, reads = 0, writes = 0;
    await tester.pumpWidget(MaterialApp(home:WindowsDeviceManagement(request:(action,body) async {
      if(action=='managed/device/revoke') {
        expect(body['targetDeviceIdentity'],other);
        writes++; revoked=true;
        return {'success':true,'device':{'deviceIdentity':other,'status':'revoked'}};
      }
      reads++; return response(revoked:revoked);
    })));
    await tester.pumpAndSettle();
    expect(find.text('Authorized PCs: 2 / 5   |   Recently active: 1'),findsOneWidget);
    expect(find.text('This PC'),findsOneWidget);
    expect(find.text('Revoke'),findsOneWidget);
    await tester.tap(find.text('Revoke')); await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton,'Revoke')); await tester.pumpAndSettle();
    expect(writes,1); expect(reads,2);
    expect(find.text('Authorized PCs: 1 / 5   |   Recently active: 1'),findsOneWidget);
    await close(tester);
  });
  testWidgets('disabled server shows unknown counts, not fake devices', (tester) async {
    await tester.pumpWidget(MaterialApp(home:WindowsDeviceManagement(request:(a,b) async => throw StateError('DEVICE_ROLLOUT_DISABLED'))));
    await tester.pumpAndSettle();
    expect(find.textContaining('Authorized PCs: — / 5'),findsOneWidget);
    expect(find.textContaining('DEVICE_ROLLOUT_DISABLED'),findsOneWidget);
    expect(find.text('Revoke'),findsNothing);
    await close(tester);
  });
  testWidgets('duplicate identities cannot authorize actions', (tester) async {
    final invalid=response();
    (invalid['devices'] as List)[1]['deviceIdentity']=own;
    await tester.pumpWidget(MaterialApp(home:WindowsDeviceManagement(request:(a,b) async => invalid)));
    await tester.pumpAndSettle();
    expect(find.textContaining('Invalid device response'),findsOneWidget);
    expect(find.text('Revoke'),findsNothing);
    await close(tester);
  });
  testWidgets('native page renders desktop and narrow high-DPI layout', (tester) async {
    await tester.runAsync(() async {
      final font=File('C:/Windows/Fonts/segoeui.ttf');
      if(await font.exists()) {
        final loader=FontLoader('Segoe UI')..addFont(Future.value(ByteData.sublistView(await font.readAsBytes())));
        await loader.load();
      }
      final icons=FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    tester.view.devicePixelRatio=1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key=GlobalKey();
    for(final size in [const Size(1100,650),const Size(430,850)]) {
      tester.view.physicalSize=size;
      await tester.pumpWidget(MaterialApp(debugShowCheckedModeBanner:false,theme:ThemeData.dark().copyWith(textTheme:ThemeData.dark().textTheme.apply(fontFamily:'Segoe UI')),home:MediaQuery(data:MediaQueryData(size:size,textScaler:TextScaler.linear(size.width<700?1.5:1)),child:RepaintBoundary(key:key,child:WindowsDeviceManagement(request:(a,b)async=>response())))));
      await tester.pumpAndSettle();
      expect(tester.takeException(),isNull);
      final boundary=key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image=await boundary.toImage();
        final bytes=await image.toByteData(format:ui.ImageByteFormat.png);
        final file=File('build/device-preview/devices-${size.width.toInt()}.png');
        await file.parent.create(recursive:true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      await close(tester);
    }
  });
}

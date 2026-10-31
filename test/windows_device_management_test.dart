import 'dart:io';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_device_management.dart';
import '../lib/windows_device_directory_cache.dart';
import '../lib/windows_connect/windows_network_connection.dart';

void main() {
  setUp(()=>SharedPreferences.setMockInitialValues({}));
  test('connection classifier never invents WiFi/LAN or leaks adapter data',(){
    expect(WindowsNetworkConnection.classifyRoute('WiFi\r\n'),'WiFi');
    expect(WindowsNetworkConnection.classifyRoute('LAN'),'LAN');
    expect(WindowsNetworkConnection.classifyRoute('VPN'),isNull);
    expect(WindowsNetworkConnection.classifyRoute('My-WiFi-SSID'),isNull);
    expect(WindowsNetworkConnection.classifyRoute(''),isNull);
  });
  test('Windows route probe classifies physical Wi-Fi/LAN without guessing virtual adapters', () {
    final script=WindowsNetworkConnection.windowsRouteProbe;
    expect(script,contains("Get-NetRoute -DestinationPrefix '0.0.0.0/0'"));
    expect(script,contains("Get-NetRoute -DestinationPrefix '::/0'"));
    expect(script,contains("Get-NetAdapter -InterfaceIndex"));
    expect(script,contains("NdisPhysicalMedium"));
    expect(script,contains("Win32_NetworkAdapter"));
    expect(script,contains("PhysicalAdapter"));
    expect(script,contains("WireGuard|OpenVPN"));
    expect(script,contains("'WiFi'; exit 0"));
    expect(script,contains("'LAN'; exit 0"));
    expect(WindowsNetworkConnection.classifyRoute('WiFi\\nLAN'),isNull);
  });
  final own = 'a' * 64, other = 'b' * 64;
  Map<String,dynamic> response({bool revoked = false}) => {'success':true,'serverTime':1792363200000,'devices':[
    {'deviceIdentity':own,'name':'School Office PC','status':'active','current':true,'activity':'recently_seen','lastSeenAt':1792363200000,'connectionType':'WiFi','connectionSeenAt':1792363200000},
    {'deviceIdentity':other,'name':'Accounts PC','status':revoked ? 'revoked':'active','current':false,'activity':revoked ? 'revoked':'unknown','lastSeenAt':1792359600000,'connectionType':'LAN','connectionSeenAt':1792359600000},
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
    expect(find.text('Connectivity'),findsOneWidget);
    expect(find.text('Wi-Fi'),findsOneWidget);
    expect(find.text('LAN'),findsOneWidget);
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
    expect(find.textContaining('Device management is not enabled on this server'),findsOneWidget);
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
  test('directory cache is account/server scoped and never stores proof secrets',() async {
    final profile=<String,dynamic>{'managed':true,'endpoint':'https://school.example/school-cloud','schoolId':'vs-'+'a'*32,'uid':'A'};
    final scope=WindowsDeviceDirectoryCache.scope(profile)!;
    expect(scope,isNot(WindowsDeviceDirectoryCache.scope({...profile,'uid':'B'})));
    expect(scope,isNot(WindowsDeviceDirectoryCache.scope({...profile,'endpoint':'https://other.example/school-cloud'})));
    expect(scope,isNot(WindowsDeviceDirectoryCache.scope({...profile,'schoolId':'vs-'+'b'*32})));
    final rows=WindowsDeviceDirectoryCache.validate(response()['devices']);
    rows.first['credential']='must-not-save';
    await WindowsDeviceDirectoryCache.write(scope,rows);
    final saved=await WindowsDeviceDirectoryCache.read(scope);
    expect(saved.length,2);
    expect(saved.first['connectionType'],'WiFi');
    expect(saved.last['connectionType'],'LAN');
    final prefs=await SharedPreferences.getInstance();
    expect(prefs.getString(prefs.getKeys().single),isNot(contains('must-not-save')));
    expect(await WindowsDeviceDirectoryCache.read('different-scope'),isEmpty);
  });
  testWidgets('background read preserves keyed rows, ordering and loading-free layout', (tester) async {
    var reads=0;
    final pending=Completer<Map<String,dynamic>>();
    final actions=<String>[];
    await tester.pumpWidget(MaterialApp(home:WindowsDeviceManagement(request:(action,body) async {
      actions.add(action); reads++;
      return reads==1 ? response() : pending.future;
    })));
    await tester.pumpAndSettle();
    final row=find.byKey(ValueKey('device-$own'));
    final element=tester.element(row);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(reads,2);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton,'Revoke')).onPressed,isNotNull);
    expect(find.byType(LinearProgressIndicator),findsNothing);
    expect(identical(element,tester.element(row)),isTrue);
    final changed=response();
    final list=changed['devices'] as List;
    list.first['activity']='unknown';
    changed['devices']=list.reversed.toList();
    pending.complete(changed);
    await tester.pumpAndSettle();
    expect(identical(element,tester.element(row)),isTrue);
    expect(tester.getTopLeft(row).dy,lessThan(tester.getTopLeft(find.byKey(ValueKey('device-$other'))).dy));
    expect(find.text('Recently active'),findsNothing);
    expect(actions,everyElement('managed/device/list'));
    await close(tester);
  });
  testWidgets('old background response cannot undo a successful revoke', (tester) async {
    var reads=0,revoked=false;
    final delayed=Completer<Map<String,dynamic>>();
    await tester.pumpWidget(MaterialApp(home:WindowsDeviceManagement(request:(action,body) async {
      if(action=='managed/device/revoke') {
        revoked=true;
        return {'success':true,'device':{'deviceIdentity':other,'status':'revoked'}};
      }
      reads++;
      return reads==2 ? delayed.future : response(revoked:revoked);
    })));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.tap(find.text('Revoke')); await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton,'Revoke')); await tester.pumpAndSettle();
    expect(find.text('Authorized PCs: 1 / 5   |   Recently active: 1'),findsOneWidget);
    delayed.complete(response()); await tester.pumpAndSettle();
    expect(find.text('Authorized PCs: 1 / 5   |   Recently active: 1'),findsOneWidget);
    expect(find.text('Revoked'),findsOneWidget);
    await close(tester);
  });
  testWidgets('saved devices survive unavailable refresh with gray lights and disabled revoke', (tester) async {
    const scope='school-A';
    await WindowsDeviceDirectoryCache.write(scope,WindowsDeviceDirectoryCache.validate(response()['devices']));
    final pending=Completer<Map<String,dynamic>>();
    await tester.pumpWidget(MaterialApp(home:WindowsDeviceManagement(cacheScope:()async=>scope,request:(a,b)=>pending.future)));
    await tester.pumpAndSettle();
    expect(find.text('School Office PC'),findsOneWidget);
    expect(find.text('Recently active'),findsNothing);
    expect(find.textContaining('Saved device list'),findsOneWidget);
    expect(find.text('Wi-Fi'),findsOneWidget);
    expect(find.byType(LinearProgressIndicator),findsNothing);
    final revoke=tester.widget<TextButton>(find.widgetWithText(TextButton,'Revoke'));
    expect(revoke.onPressed,isNull);
    pending.completeError(StateError('DEVICE_ROLLOUT_DISABLED'));
    await tester.pumpAndSettle();
    expect(find.text('School Office PC'),findsOneWidget);
    expect(find.textContaining('Authorized PCs: 2 / 5'),findsOneWidget);
    expect(find.textContaining('Device management is not enabled'),findsOneWidget);
    final light=tester.widget<Icon>(find.byKey(ValueKey('activity-$own')));
    expect(light.color,const Color(0xff9caac0));
    await close(tester);
  });
  testWidgets('enrollment-only list shows real devices but cannot send an unenforced revoke', (tester) async {
    final actions=<String>[];
    await tester.pumpWidget(MaterialApp(home:WindowsDeviceManagement(request:(a,b)async {
      actions.add(a);return {...response(),'canRevoke':false};
    })));
    await tester.pumpAndSettle();
    expect(find.text('School Office PC'),findsOneWidget);
    expect(find.text('Recently active'),findsOneWidget);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton,'Revoke')).onPressed,isNull);
    expect(find.textContaining('Device enrollment is active'),findsOneWidget);
    expect(actions,['managed/device/list']);
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

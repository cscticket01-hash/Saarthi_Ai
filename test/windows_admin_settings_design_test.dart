import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../lib/windows_admin_settings_design.dart';
import '../lib/main_dashboard_screen_windows.dart' show AdminSettingsScreen;
import '../lib/windows_local_auth.dart' as local;

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });
  testWidgets('approved settings actions and month selector remain reachable at desktop and high DPI', (tester) async {
    final actions=<String>[];
    for (final spec in [(const Size(1280, 900),1.0),(const Size(600,900),1.5),(const Size(360,800),2.0)]) {
      await tester.binding.setSurfaceSize(spec.$1);
      await tester.pumpWidget(MaterialApp(builder:(context,child)=>MediaQuery(
        data:MediaQuery.of(context).copyWith(textScaler:TextScaler.linear(spec.$2)),child:child!),
        home:WindowsAdminSettingsLayout(email:'school@example.com',name:'school@example.com',
          avatar:const Center(child:Text('S')),authenticated:true,year:'2026–27',month:1,loadingYear:false,
          onMonthChanged:(value)=>actions.add('month-$value'),onDevices:()=>actions.add('devices'),
          onSchool:()=>actions.add('school'),onPasswords:()=>actions.add('passwords'),onAdvanced:()=>actions.add('advanced'))));
      await tester.pumpAndSettle();
      expect(find.text('Student Import Sheet'),findsNothing);
      expect(find.text('school@example.com'),findsOneWidget);
      if (spec.$1.width >= 960 && spec.$1.height >= 830 && spec.$2 == 1.0) {
        expect(find.byType(SingleChildScrollView), findsNothing);
        expect(tester.getTopLeft(find.text('Device Management')).dx, greaterThan(0));
        expect(tester.getBottomRight(find.text('Open Advanced Settings')).dy,
            lessThan(spec.$1.height));
      }
      for(final entry in {'Device Management':'devices','School Settings':'school',
          'Open Password Management':'passwords','Open Advanced Settings':'advanced'}.entries) {
        await tester.ensureVisible(find.text(entry.key)); await tester.pumpAndSettle();
        await tester.tap(find.text(entry.key));await tester.pumpAndSettle();
        expect(actions.last,entry.value);
      }
      await tester.ensureVisible(find.byType(DropdownButton<int>));await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButton<int>));await tester.pumpAndSettle();
      await tester.tap(find.text('April').last);await tester.pumpAndSettle();
      expect(actions.last,'month-4');expect(tester.takeException(),isNull);
      await tester.pumpWidget(const SizedBox());
    }
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('actual Admin Settings renders the approved page with real account binding and device route', (tester) async {
    await tester.runAsync(() async {
      await (FontLoader('Segoe UI')..addFont(Future.value(ByteData.sublistView(
        await File('C:/Windows/Fonts/segoeui.ttf').readAsBytes())))).load();
      await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    local.FirebaseAuth.instance.useManagedIdentity('admin@school.example');
    addTearDown(()=>tester.binding.setSurfaceSize(null));
    for(final spec in [('desktop',const Size(1280,900),1.0),('compact',const Size(360,800),1.5)]) {
      await tester.binding.setSurfaceSize(spec.$2);
      final key=GlobalKey();
      await tester.pumpWidget(MaterialApp(theme:ThemeData(brightness:Brightness.dark,fontFamily:'Segoe UI'),
        builder:(context,child)=>MediaQuery(data:MediaQuery.of(context).copyWith(textScaler:TextScaler.linear(spec.$3)),child:child!),
        routes:{'/admin/device-management':(_)=>const Scaffold(body:Text('Verified device route'))},
        home:RepaintBoundary(key:key,child:const AdminSettingsScreen())));
      await tester.pumpAndSettle();
      expect(find.text('Student Import Sheet'),findsNothing);
      expect(find.text('admin@school.example'),findsOneWidget);
      expect(find.text('Authenticated'),findsOneWidget);
      expect(tester.takeException(),isNull);
      await tester.runAsync(() async {
        final image=await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
        final bytes=(await image.toByteData(format:ui.ImageByteFormat.png))!.buffer.asUint8List();
        final file=File('build/admin-settings-preview/admin-settings-${spec.$1}.png');
        await file.parent.create(recursive:true);await file.writeAsBytes(bytes);
        final encoded=base64Encode(bytes);
        for(var start=0;start<encoded.length;start+=16000) {
          print('ADMIN_SETTINGS_PNG_${spec.$1}:$start:${encoded.substring(start,(start+16000).clamp(0,encoded.length))}');
        }
        image.dispose();
      });
      if(spec.$1=='desktop') {
        expect(tester.getBottomRight(find.text('Open Advanced Settings')).dy,lessThan(900));
        await tester.tap(find.text('Device Management'));await tester.pumpAndSettle();
        expect(find.text('Verified device route'),findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());await tester.pumpAndSettle();
    }
  });
}

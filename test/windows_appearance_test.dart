import 'package:flutter/services.dart';

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_appearance.dart';
import '../lib/windows_local_firestore.dart' as local;
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_staff_payroll.dart';
import '../lib/windows_document_templates.dart';
import '../lib/windows_connection_center.dart';
import '../lib/windows_sync_engine.dart';
import '../lib/windows_platform_client.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/main_dashboard_screen_windows.dart' show AdminDashboardScreen, AdminAnalyticsScreen, SettingsScreen, SchoolSettingsScreen, AdminSettingsScreen, FeesCollectionScreen, FeeCollectionSettingsScreen, TeachersDirectoryScreen, AddTeacherScreen, AllStudentsListScreen, WindowsSchoolExpensesScreen, ExamCenterScreen, AdvancedSettingsScreen, WindowsAttendanceScreen;
import '../lib/windows_settings_panel.dart';

Widget app(Widget home, {GlobalKey<NavigatorState>? navigatorKey}) =>
    ValueListenableBuilder<ThemeMode>(
      valueListenable: WindowsAppearance.mode,
      builder: (_, mode, __) => MaterialApp(
        navigatorKey: navigatorKey,
        themeMode: mode,
        theme: WindowsAppearance.theme(Brightness.light),
        darkTheme: WindowsAppearance.theme(Brightness.dark),
        home: home,
      ),
    );
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db=local.FirebaseFirestore.instance;
  setUp(()=>FlutterSecureStorage.setMockInitialValues({}));
  tearDown(() {
    WindowsAppearance.mode.value = ThemeMode.dark;
  });
  test('extreme developer RGB values keep text and controls readable in both modes', () {
    for(final rgb in [Colors.black,Colors.white,Colors.yellow,Colors.blue,Colors.red,Colors.green]) {
      WindowsAppearance.applyBrand({'schemaVersion':1,'red':(rgb.r*255).round(),'green':(rgb.g*255).round(),'blue':(rgb.b*255).round(),'revision':'test'},persist:false);
      for(final mode in [ThemeMode.dark,ThemeMode.light]) {
        WindowsAppearance.mode.value=mode;
        final scheme=WindowsAppearance.theme(mode==ThemeMode.dark?Brightness.dark:Brightness.light).colorScheme;
        expect(WindowsAppearance.resolve(scheme.primary),scheme.primary, reason:'Generated RGB brand must survive legacy role mapping');
        expect(WindowsAppearance.contrast(scheme.primary,scheme.onPrimary),greaterThanOrEqualTo(4.5));
        expect(WindowsAppearance.contrast(scheme.onSurface,scheme.surface),greaterThanOrEqualTo(4.5));
        for(final old in [Colors.white38,Colors.purpleAccent,Colors.blueAccent,Colors.redAccent,Colors.orangeAccent,Colors.greenAccent]) {
          expect(WindowsAppearance.contrast(WindowsAppearance.foreground(old),WindowsAppearance.surface),greaterThanOrEqualTo(4.5));
        }
      }
    }
    WindowsAppearance.applyBrand({'schemaVersion':1,'red':0,'green':140,'blue':120,'revision':'default'},persist:false);
  });
  test(
    'device preference survives restart, rapid toggles and corrupt file',
    () async {
      final dir = await Directory.systemTemp.createTemp('appearance-test-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/preference.json');
      await Future.wait([
        WindowsAppearance.select(ThemeMode.light, file: file),
        WindowsAppearance.select(ThemeMode.dark, file: file),
        WindowsAppearance.select(ThemeMode.light, file: file),
      ]);
      WindowsAppearance.mode.value = ThemeMode.dark;
      await WindowsAppearance.restore(file: file);
      expect(WindowsAppearance.mode.value, ThemeMode.light);
      expect(dir.listSync().length, 1);
      await file.writeAsString('broken');
      WindowsAppearance.mode.value = ThemeMode.dark;
      await WindowsAppearance.restore(file: file);
      expect(WindowsAppearance.mode.value, ThemeMode.dark);
    },
  );
  testWidgets('Windows route atlas retains visible content in both modes', (tester) async {
    final originalErrorHandler=FlutterError.onError;
    FlutterError.onError=(details){FlutterError.dumpErrorToConsole(details,forceReport:true);originalErrorHandler?.call(details);};
    addTearDown(()=>FlutterError.onError=originalErrorHandler);
    addTearDown(() {WindowsSyncEngine.instance.dispose();WindowsPlatformClient.instance.dispose();tester.view.resetPhysicalSize();tester.view.resetDevicePixelRatio();});
    await tester.runAsync(() async {
      debugPrint('THEME_ATLAS loading fonts');
      await (FontLoader('Segoe UI')..addFont(Platform.isWindows
        ? Future.value(ByteData.sublistView(await File('C:/Windows/Fonts/segoeui.ttf').readAsBytes()))
        : rootBundle.load('assets/id_card_regular.ttf'))).load();
      await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      await WindowsRuntimeFlags.setLocalStorageEnabled(true);
      debugPrint('THEME_ATLAS initializing local services');
      await WindowsConnectionCenter.initialize();
      debugPrint('THEME_ATLAS local services ready');
      await db.collection('school_config').doc('school_profile_cache').set({'schoolName':'Synthetic Theme School','principalName':'Principal'});
      await db.collection('teachers_directory').doc('theme-teacher').set({'name':'Synthetic Teacher','teacherId':'T-1','subject':'Mathematics','status':'Active','phone':'0000000000','fatherName':'Synthetic Father'});
      await db.collection('students_directory').doc('theme-student').set({'name':'Synthetic Student','class':'1','rollNo':1,'parentName':'Synthetic Parent'});
    });
    debugPrint('THEME_ATLAS fixture ready');
    final screens=<String,Widget>{
      'dashboard':const AdminDashboardScreen(),'analytics':const AdminAnalyticsScreen(),'settings':const SettingsScreen(),'school':const SchoolSettingsScreen(),'admin':const AdminSettingsScreen(),
      'fees':const FeesCollectionScreen(),'fee-settings':const FeeCollectionSettingsScreen(),
      'teachers':const TeachersDirectoryScreen(),'add-teacher':const AddTeacherScreen(),
      'students':const AllStudentsListScreen(),'expenses':const WindowsSchoolExpensesScreen(),
      'exams':const ExamCenterScreen(),'advanced':const AdvancedSettingsScreen(),
      'attendance':const WindowsAttendanceScreen(),'salary':const StaffSalaryScreen(),'templates':SchoolDocumentTemplatesScreen(thumbnail:(_,__) async=>(await rootBundle.load('assets/school_logo.png')).buffer.asUint8List()),
    };
    for(final size in [const Size(1440,1000),const Size(1024,768)]) {
      tester.view.physicalSize=size;tester.view.devicePixelRatio=1;
      for(final mode in [ThemeMode.dark,ThemeMode.light]) {
        WindowsAppearance.mode.value=mode;
        for(final entry in screens.entries) {
          debugPrint('THEME_ATLAS ${entry.key} ${mode.name} ${size.width.toInt()}');
          final key=GlobalKey();
          await tester.runAsync(() async {
            await tester.pumpWidget(app(RepaintBoundary(key:key,child:entry.value)));
            await Future<void>.delayed(const Duration(milliseconds:100));
            // Fees mounts two nested disk-backed streams after its UID lookup.
            // Subscribe those streams in the real event loop, not the fake clock.
            if(entry.key=='fees')for(var i=0;i<8;i++) {
              await tester.pump();
              await Future<void>.delayed(const Duration(milliseconds:80));
            }
          });
          for(var i=0;i<24;i++) {
            await tester.runAsync(()=>Future<void>.delayed(const Duration(milliseconds:30)));await tester.pump(const Duration(milliseconds:30));
            if(entry.key=='salary' && find.byKey(const ValueKey('salary-history')).evaluate().isNotEmpty)break;
          }
          if(entry.key=='fees') {
            expect(find.text('Payment Details'),findsOneWidget,reason:'Review the loaded fee form, not a loading spinner');
          }
          if(entry.key=='students') {
            final add=find.ancestor(of:find.text('Add Student'),matching:find.byWidgetPredicate((w)=>w is TextButton));
            final button=tester.widget<TextButton>(add);
            expect(button.onPressed,isNotNull);
            expect(WindowsAppearance.contrast(button.style!.foregroundColor!.resolve({})!,button.style!.backgroundColor!.resolve({})!),greaterThanOrEqualTo(4.5));
          }
          if(entry.key=='salary') {
            expect(find.byKey(const ValueKey('salary-history')),findsOneWidget);
            // Exercise the enabled bulk action as well as the initial disabled state.
            await tester.tap(find.byType(Checkbox).last);await tester.pumpAndSettle();
            final actionFinder=find.ancestor(of:find.text('Mark Selected as Paid'),matching:find.byWidgetPredicate((w)=>w is FilledButton));
            final action=tester.widget<FilledButton>(actionFinder);
            expect(action.onPressed,isNotNull);
            final palette=Theme.of(tester.element(actionFinder)).colorScheme;
            final bg=action.style?.backgroundColor?.resolve({})??palette.primary;
            final fg=action.style?.foregroundColor?.resolve({})??palette.onPrimary;
            expect(WindowsAppearance.contrast(fg,bg),greaterThanOrEqualTo(4.5));
          }
          if(entry.key=='teachers')expect(find.text('Synthetic Teacher'),findsOneWidget);
          expect(tester.takeException(),isNull,reason:'${entry.key} ${mode.name} $size');
          if(Platform.isWindows||Platform.environment['SAARTHI_THEME_ATLAS']=='true') await tester.runAsync(() async {
            final image=await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
            final bytes=await image.toByteData(format:ui.ImageByteFormat.png);
            final file=File('build/appearance-preview/atlas-${entry.key}-${mode.name}-${size.width.toInt()}.png');
            await file.parent.create(recursive:true);await file.writeAsBytes(bytes!.buffer.asUint8List());image.dispose();
          });
          await tester.pumpWidget(const SizedBox());await tester.pump();
        }
      }
    }
    tester.view.resetPhysicalSize();tester.view.resetDevicePixelRatio();
    await tester.runAsync(()=>WindowsRuntimeFlags.setLocalStorageEnabled(false));
  });
  testWidgets(
    'Settings has Appearance above Update in both modes without overflow',
    (tester) async {
      if (Platform.isWindows) {
        await tester.runAsync(() async {
          await (FontLoader('Segoe UI')..addFont(
                Future.value(
                  ByteData.sublistView(
                    await File('C:/Windows/Fonts/segoeui.ttf').readAsBytes(),
                  ),
                ),
              ))
              .load();
          await (FontLoader('MaterialIcons')
                ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
              .load();
        });
      }
      for (final size in [const Size(1280, 800), const Size(360, 800)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        for (final mode in [ThemeMode.dark, ThemeMode.light]) {
          WindowsAppearance.mode.value = mode;
          final renderKey = GlobalKey();
          await tester.pumpWidget(
            app(RepaintBoundary(key: renderKey, child: const SettingsScreen())),
          );
          await tester.pumpAndSettle();
          expect(
            tester.getTopLeft(find.byType(WindowsAppearanceCard)).dy,
            lessThan(tester.getTopLeft(find.byType(WindowsAppUpdateCard)).dy),
          );
          expect(find.text('Dark Mode'), findsOneWidget);
          expect(find.text('Light Mode'), findsOneWidget);
          final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
          expect(
            scaffold.backgroundColor,
            WindowsAppearance.background(const Color(0xFF0B141A)),
          );
          expect(tester.takeException(), isNull);
          if (Platform.isWindows) {
            await tester.runAsync(() async {
              final image =
                  await (renderKey.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File(
                'build/appearance-preview/settings-${mode.name}-${size.width.toInt()}.png',
              );
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
        }
      }
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    },
  );
  testWidgets('open route, edited form and dialog survive a live mode change', (
    tester,
  ) async {
    final nav = GlobalKey<NavigatorState>();
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      app(const Scaffold(body: Text('Home')), navigatorKey: nav),
    );
    nav.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(body: TextField(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Unsaved student draft');
    final route = ModalRoute.of(tester.element(find.byType(TextField)));
    showDialog<void>(
      context: tester.element(find.byType(TextField)),
      builder: (context) {
        WindowsAppearance.watch(context);
        return AlertDialog(
          backgroundColor: WindowsAppearance.resolve(const Color(0xFF172229)),
          title: Text(
            'Open dialog',
            style: TextStyle(color: WindowsAppearance.resolve(Colors.white)),
          ),
        );
      },
    );
    await tester.pumpAndSettle();
    WindowsAppearance.mode.value = ThemeMode.light;
    await tester.pumpAndSettle();
    expect(find.text('Open dialog'), findsOneWidget);
    expect(
      tester.widget<AlertDialog>(find.byType(AlertDialog)).backgroundColor,
      WindowsAppearance.resolve(const Color(0xFF172229)),
    );
    expect(controller.text, 'Unsaved student draft');
    nav.currentState!.pop();
    await tester.pumpAndSettle();
    expect(ModalRoute.of(tester.element(find.byType(TextField))), same(route));
    expect(
      Theme.of(tester.element(find.byType(TextField))).brightness,
      Brightness.light,
    );
    expect(tester.takeException(), isNull);
  });
}

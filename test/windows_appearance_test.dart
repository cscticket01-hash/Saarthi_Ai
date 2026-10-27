import 'package:flutter/services.dart';

import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_appearance.dart';
import '../lib/main_dashboard_screen_windows.dart' show SettingsScreen;
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
  tearDown(() {
    WindowsAppearance.mode.value = ThemeMode.dark;
  });
  test('extreme developer RGB values keep text and controls readable in both modes', () {
    for(final rgb in [Colors.black,Colors.white,Colors.yellow,Colors.blue,Colors.red,Colors.green]) {
      WindowsAppearance.applyBrand({'schemaVersion':1,'red':(rgb.r*255).round(),'green':(rgb.g*255).round(),'blue':(rgb.b*255).round(),'revision':'test'},persist:false);
      for(final mode in [ThemeMode.dark,ThemeMode.light]) {
        WindowsAppearance.mode.value=mode;
        final scheme=WindowsAppearance.theme(mode==ThemeMode.dark?Brightness.dark:Brightness.light).colorScheme;
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

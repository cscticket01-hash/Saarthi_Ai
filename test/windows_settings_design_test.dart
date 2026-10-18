import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/main_dashboard_screen_windows.dart' show SettingsScreen;
import '../lib/windows_settings_design.dart';
import '../lib/windows_update_service.dart';
import '../lib/windows_sync_engine.dart';
import '../lib/windows_sync_control_center.dart';
import '../lib/school_cloud_state.dart';

class _Routes extends NavigatorObserver {
  Route<dynamic>? latest;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) { latest = route; }
}

void main() {
  final engine = WindowsSyncEngine.instance;
  final originalUpdate = WindowsUpdateService.state.value;
  final originalDetails = engine.details.value;
  final originalState = engine.state.value;
  final originalTime = engine.lastSuccessfulSync;
  final originalError = engine.lastError;
  setUp(() {
    WindowsUpdateService.state.value = const WindowsUpdateRuntimeState(
      phase: WindowsUpdatePhase.upToDate, message: 'App already latest version par hai.');
    engine.lastSuccessfulSync = DateTime(2026, 10, 18, 22, 51, 38, 889, 664);
    engine.lastError = null;
    engine.details.value = {'pending': 0, 'needsAttention': 0};
    engine.state.value = SchoolCloudState.synced;
  });
  tearDown(() {
    WindowsUpdateService.state.value = originalUpdate;
    engine.details.value = originalDetails;
    engine.state.value = originalState;
    engine.lastSuccessfulSync = originalTime;
    engine.lastError = originalError;
  });

  testWidgets('actual Settings page renders responsive, DPI-scaled review PNGs without overflow', (tester) async {
    await tester.runAsync(() async {
      await (FontLoader('Segoe UI')..addFont(Future.value(ByteData.sublistView(
        await File('C:/Windows/Fonts/segoeui.ttf').readAsBytes())))).load();
      await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final spec in [
      ('wide', const Size(1672, 899), 1.0, 1.0),
      ('desktop', const Size(1280, 800), 1.0, 1.0),
      ('narrow', const Size(600, 900), 1.0, 1.0),
      ('dpi150', const Size(960, 800), 1.5, 1.5),
      ('compact', const Size(360, 800), 2.0, 1.5),
    ]) {
      await tester.binding.setSurfaceSize(spec.$2);
      final key = GlobalKey();
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(navigatorKey: navigator, theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Segoe UI',
          fontFamilyFallback: const ['Nirmala UI', 'Arial'], scaffoldBackgroundColor: const Color(0xFF0B141A)),
        builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(spec.$4)), child: child!),
        home: const Scaffold()));
      navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) =>
        RepaintBoundary(key: key, child: const SettingsScreen())));
      await tester.pumpAndSettle();
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.byType(WindowsSettingsCard), findsNWidgets(2));
      expect(find.text('Windows master app update • Current v$windowsAppVersion'), findsOneWidget);
      expect(find.text('Sync Status • Synced'), findsOneWidget);
      expect(tester.takeException(), isNull, reason: spec.$1);
      expect(tester.getSize(find.byType(WindowsSettingsBody)).height, spec.$2.height - kToolbarHeight);
      await tester.runAsync(() async {
        final image = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: spec.$3);
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
        final file = File('build/settings-preview/settings-${spec.$1}.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
        // Portable review evidence retrievable from CI logs as well as artifacts.
        if (spec.$1 == 'wide' || spec.$1 == 'compact') {
          final encoded = base64Encode(bytes);
          for (var start = 0; start < encoded.length; start += 16000) {
            final end = (start + 16000).clamp(0, encoded.length);
            print('SETTINGS_PNG_${spec.$1}:$start:${encoded.substring(start, end)}');
          }
        }
        image.dispose();
      });
      await tester.ensureVisible(find.text('Open Sync & Backup Control Center'));
      await tester.pumpAndSettle();
      expect(find.text('Open Sync & Backup Control Center').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('live notifiers preserve error, download progress and conditional install controls', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    WindowsUpdateService.state.value = const WindowsUpdateRuntimeState(
      phase: WindowsUpdatePhase.checking, message: 'Checking for updates...');
    await tester.pump();
    expect(find.text('Checking...'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton).first).onPressed, isNull);
    WindowsUpdateService.state.value = const WindowsUpdateRuntimeState(
      phase: WindowsUpdatePhase.error, message: 'Synthetic connection error');
    await tester.pump();
    expect(find.text('Synthetic connection error'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton).first).onPressed, isNotNull);
    const available = WindowsUpdateInfo(latestVersion: '999.0.0', downloadUrl: 'https://example.invalid/test.exe', fileName: 'test.exe', releaseNotes: 'Synthetic');
    WindowsUpdateService.state.value = const WindowsUpdateRuntimeState(
      phase: WindowsUpdatePhase.available, update: available);
    await tester.pump();
    expect(find.text('Download & Install'), findsOneWidget);
    WindowsUpdateService.state.value = const WindowsUpdateRuntimeState(
      phase: WindowsUpdatePhase.downloading, update: available, progress: .42);
    await tester.pump();
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, .42);
    expect(find.text('Downloading 42%'), findsOneWidget);
    engine.details.value = {'pending': 37, 'needsAttention': 0};
    engine.state.value = SchoolCloudState.syncing;
    await tester.pump();
    expect(find.text('Sync Status • Syncing 37 items...'), findsOneWidget);
    expect(find.text('37'), findsOneWidget);
    engine.state.value = SchoolCloudState.offline;
    await tester.pump();
    expect(find.text('Sync Status • Offline'), findsOneWidget);
    expect(tester.widgetList<WindowsSettingsCard>(find.byType(WindowsSettingsCard)).last.success, false);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Check for Update still calls the existing service and reports its errors', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await HttpOverrides.runZoned(() async {
      await tester.tap(find.text('Check for Update'));
      await tester.pump();
      expect(WindowsUpdateService.state.value.phase, WindowsUpdatePhase.error);
      expect(find.text('Synthetic update request reached'), findsOneWidget);
    }, createHttpClient: (_) => throw StateError('Synthetic update request reached'));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Sync button pushes the existing Control Center with its backup action', (tester) async {
    final routes = _Routes();
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(navigatorObservers: [routes], home: const SettingsScreen()));
    final source = routes.latest;
    await tester.tap(find.text('Open Sync & Backup Control Center'));
    expect(routes.latest, isNot(same(source)));
    final destination = (routes.latest! as MaterialPageRoute<void>).builder(
      tester.element(find.byType(SettingsScreen)));
    expect(destination, isA<WindowsSyncControlCenter>());
    expect((destination as WindowsSyncControlCenter).backupRequest, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('existing back navigation stays available', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(
      body: TextButton(onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => const SettingsScreen())), child: const Text('Open settings'))))));
    await tester.tap(find.text('Open settings')); await tester.pumpAndSettle();
    expect(find.byType(BackButton), findsOneWidget);
    await tester.tap(find.byType(BackButton)); await tester.pumpAndSettle();
    expect(find.text('Open settings'), findsOneWidget);
    expect(find.byType(SettingsScreen), findsNothing);
  });
}

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/developer_windows_theme.dart';
import '../lib/managed_developer_panel.dart';
import '../lib/windows_theme_presets.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'ReviewSans',
    )..addFont(rootBundle.load('assets/id_card_regular.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  Future<void> mount(
    WidgetTester tester,
    Size size,
    Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
    request, {
    GlobalKey? capture,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(useMaterial3: true).copyWith(
          textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'ReviewSans'),
        ),
        home: Scaffold(
          body: RepaintBoundary(
            key: capture,
            child: Row(
              children: [
                const SizedBox(
                  width: 230,
                  child: Center(child: Text('Vidya Saarthi')),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: DeveloperWindowsTheme(request: request),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Map<String, dynamic> initial() => {
    'schemaVersion': 1,
    'red': 0,
    'green': 140,
    'blue': 120,
    'revision': 'saved-1',
  };
  testWidgets(
    'all six preset selections are drafts; arrows change one themed screenshot; Save publishes once',
    (tester) async {
      final calls = <Map<String, dynamic>>[];
      await mount(tester, const Size(1440, 900), (action, body) async {
        calls.add({'action': action, ...body});
        return {
          'theme': action == 'theme/get'
              ? initial()
              : {...body['theme'] as Map, 'revision': 'saved-2'},
        };
      });
      for (final preset in windowsThemePresets) {
        expect(File(preset.image).existsSync(), isTrue);
        for (final page in ['dashboard', 'students', 'fees', 'settings'])
          expect(
            File('assets/theme_preview_${preset.id}_$page.webp').existsSync(),
            isTrue,
          );
        await tester.tap(find.byKey(ValueKey('theme-preset-${preset.id}')));
        await tester.pumpAndSettle();
        expect(
          calls.length,
          1,
          reason: 'Selecting a picture must never publish',
        );
        final image = tester.widget<Image>(
          find.byKey(const ValueKey('theme-preview-image')),
        );
        expect(
          (image.image as AssetImage).assetName,
          'assets/theme_preview_${preset.id}_dashboard.webp',
        );
      }
      expect(find.text('Unsaved selection'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('theme-next')));
      await tester.pumpAndSettle();
      expect(find.text('Student Records  •  2 / 4'), findsOneWidget);
      expect(
        (tester
                    .widget<Image>(
                      find.byKey(const ValueKey('theme-preview-image')),
                    )
                    .image
                as AssetImage)
            .assetName,
        'assets/theme_preview_emerald-gold_students.webp',
      );
      await tester.tap(find.byKey(const ValueKey('theme-previous')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('theme-previous')));
      await tester.pumpAndSettle();
      expect(find.text('Settings  •  4 / 4'), findsOneWidget);
      expect(calls.length, 1);
      await tester.tap(find.byKey(const ValueKey('theme-save')));
      await tester.pumpAndSettle();
      expect(calls.length, 2);
      expect(calls.last['action'], 'theme/save');
      expect((calls.last['theme'] as Map)['presetId'], 'emerald-gold');
      expect((calls.last['theme'] as Map)['expectedRevision'], 'saved-1');
      expect(find.text('Saved theme'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'RGB and HEX validation, quick colours and Reset retain explicit Save',
    (tester) async {
      final calls = <String>[];
      await mount(tester, const Size(1366, 650), (action, body) async {
        calls.add(action);
        return {
          'theme': action == 'theme/get'
              ? initial()
              : {...body['theme'] as Map, 'revision': 'saved-2'},
        };
      });
      for (final name in ['Teal', 'Ocean', 'Violet', 'Amber', 'Rose'])
        expect(find.text(name), findsOneWidget);
      await tester.tap(find.text('Violet'));
      await tester.pumpAndSettle();
      expect(calls.length, 1);
      await tester.enterText(find.byKey(const ValueKey('theme-rgb-0')), '256');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('theme-save')))
            .onPressed,
        isNull,
      );
      await tester.enterText(find.byKey(const ValueKey('theme-rgb-0')), '100');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save Theme'));
      await tester.pumpAndSettle();
      expect(calls.length, 2);
      await tester.enterText(find.byKey(const ValueKey('theme-hex')), 'bad');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const ValueKey('theme-save')))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Reset'));
      await tester.pumpAndSettle();
      expect(find.text('Saved theme'), findsOneWidget);
    },
  );
  testWidgets(
    'entire workspace fits desktop and laptop viewports without scrolling or clipped controls',
    (tester) async {
      for (final size in [
        const Size(1920, 910),
        const Size(1440, 800),
        const Size(1366, 650),
        const Size(1280, 600),
      ]) {
        final key = GlobalKey();
        await mount(
          tester,
          size,
          (action, body) async => {'theme': initial()},
          capture: key,
        );
        await tester.tap(find.byKey(const ValueKey('theme-preset-mint-light')));
        await tester.pumpAndSettle();
        expect(find.byType(ListView), findsNothing);
        expect(tester.getSize(find.text('Reset')).height, lessThan(24));
        expect(tester.getSize(find.text('Save Theme')).height, lessThan(24));
        for (final name in [
          'theme-save',
          'theme-next',
          'theme-previous',
          'theme-hex',
          'theme-rgb-2',
        ]) {
          final rect = tester.getRect(find.byKey(ValueKey(name)));
          expect(rect.left, greaterThanOrEqualTo(230));
          expect(rect.right, lessThanOrEqualTo(size.width));
          expect(rect.top, greaterThanOrEqualTo(0));
          expect(rect.bottom, lessThanOrEqualTo(size.height));
        }
        expect(tester.takeException(), isNull, reason: 'No overflow at $size');
        await tester.runAsync(() async {
          final image =
              await (key.currentContext!.findRenderObject()
                      as RenderRepaintBoundary)
                  .toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          final f = File(
            'build/theme-layout-review/compact-${size.width.toInt()}x${size.height.toInt()}.png',
          );
          await f.parent.create(recursive: true);
          await f.writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
  testWidgets('failed Save retains selected draft for retry', (tester) async {
    await mount(tester, const Size(1440, 800), (action, body) async {
      if (action == 'theme/save') throw StateError('conflict');
      return {'theme': initial()};
    });
    await tester.tap(find.byKey(const ValueKey('theme-preset-electric-blue')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save Theme'));
    await tester.pumpAndSettle();
    expect(find.text('Unsaved selection'), findsOneWidget);
    expect(find.textContaining('Theme was not confirmed'), findsOneWidget);
    expect(find.text('Electric Blue • sample app screens'), findsOneWidget);
  });
  testWidgets(
    'school password action is in school row and validates before submitting',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ManagedDeveloperPanel(
                schools: [
                  {
                    'id': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                    'name': 'Demo school',
                    'managed': true,
                    'loginEmail': 'demo@school.example',
                  },
                ],
                refresh: () async {},
                legacyDelete: (_) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Change School Password'));
      await tester.pumpAndSettle();
      expect(find.text('Change school login password'), findsOneWidget);
      expect(find.text('demo@school.example'), findsWidgets);
      await tester.enterText(
        find.byKey(const ValueKey('school-new-password')),
        'short',
      );
      await tester.enterText(
        find.byKey(const ValueKey('school-confirm-password')),
        'different',
      );
      await tester.tap(find.text('Change password'));
      await tester.pumpAndSettle();
      expect(
        find.text('Use 12–128 characters and matching passwords.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Change school login password'), findsNothing);
    },
  );
}

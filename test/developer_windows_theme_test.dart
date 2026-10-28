import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/developer_windows_theme.dart';
import '../lib/managed_developer_panel.dart';

void main() {
  testWidgets(
    'presets and custom RGB remain draft until explicit Save, retaining revision',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DeveloperWindowsTheme(
                request: (action, body) async {
                  calls.add({'action': action, ...body});
                  return {
                    'success': true,
                    'theme': action == 'theme/get'
                        ? {
                            'schemaVersion': 1,
                            'red': 0,
                            'green': 140,
                            'blue': 120,
                            'revision': 'saved-1',
                          }
                        : {...body['theme'] as Map, 'revision': 'saved-2'},
                  };
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(calls.length, 1);
      for (final name in ['Teal', 'Ocean', 'Violet', 'Amber', 'Rose'])
        expect(find.text(name), findsOneWidget);
      await tester.tap(find.text('Violet'));
      await tester.pumpAndSettle();
      expect(calls.length, 1);
      expect(find.textContaining('Unsaved colour'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('theme-rgb-0')), '256');
      await tester.pumpAndSettle();
      final save = find.widgetWithText(FilledButton, 'Save Windows Theme');
      expect(tester.widget<FilledButton>(save).onPressed, isNull);
      await tester.enterText(find.byKey(const ValueKey('theme-rgb-0')), '100');
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save Windows Theme'));
      await tester.tap(find.text('Save Windows Theme'));
      await tester.pumpAndSettle();
      expect(calls.length, 2);
      expect((calls.last['theme'] as Map)['red'], 100);
      expect((calls.last['theme'] as Map)['expectedRevision'], 'saved-1');
      expect(find.textContaining('Saved theme •'), findsOneWidget);
      expect(find.text('Change School Password'), findsNothing);
    },
  );
  testWidgets(
    'six image presets publish immediately and gallery contains four static app screenshots',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <Map<String, dynamic>>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: DeveloperWindowsTheme(
                request: (action, body) async {
                  calls.add({'action': action, ...body});
                  return {
                    'theme': action == 'theme/get'
                        ? {
                            'schemaVersion': 1,
                            'red': 0,
                            'green': 140,
                            'blue': 120,
                            'revision': 'base',
                          }
                        : {...body['theme'] as Map, 'revision': 'preset-saved'},
                  };
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final name in [
        'Neon Teal',
        'Electric Blue',
        'Mint Light',
        'Sunset Ember',
        'Aurora Violet',
        'Emerald Gold',
      ])
        expect(find.text(name), findsOneWidget);
      final screenshots = find.byWidgetPredicate(
        (w) =>
            w is Image &&
            w.image is AssetImage &&
            (w.image as AssetImage).assetName.startsWith(
              'assets/app_screenshot_',
            ),
      );
      expect(screenshots, findsNWidgets(4));
      expect(find.text('Live Windows Preview'), findsNothing);
      await tester.tap(find.text('Emerald Gold'));
      await tester.pumpAndSettle();
      expect(calls.length, 2);
      expect((calls.last['theme'] as Map)['presetId'], 'emerald-gold');
      expect((calls.last['theme'] as Map)['expectedRevision'], 'base');
      expect(find.text('Saved theme • no unpublished changes'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
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

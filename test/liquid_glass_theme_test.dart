import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/liquid_glass_theme.dart';
import '../lib/windows_appearance.dart';
import '../lib/windows_theme_presets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android Liquid Glass uses translucent cards and native dark navigation', () {
    final theme = mobileLiquidGlassTheme();
    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, Colors.transparent);
    expect(theme.cardTheme.color!.a, lessThan(1));
    expect(theme.navigationBarTheme.backgroundColor, isNotNull);
    expect(theme.colorScheme.onSurface.computeLuminance(), greaterThan(.75));
  });

  test('published Windows glass ID remains compatible with existing schools', () {
    final old = WindowsAppearance.brandData;
    addTearDown(() => WindowsAppearance.applyBrand(old, persist: false));
    final glass = windowsThemePreset('midnight-glass')!;
    expect(glass.name, 'Liquid Glass');
    WindowsAppearance.applyBrand({
      'schemaVersion': 1,
      'red': (glass.seed.r * 255).round(),
      'green': (glass.seed.g * 255).round(),
      'blue': (glass.seed.b * 255).round(),
      'presetId': glass.id,
      'revision': 'live-test',
    }, persist: false);
    expect(WindowsAppearance.presetId, 'midnight-glass');
    expect(WindowsAppearance.theme(Brightness.dark).scaffoldBackgroundColor,
        Colors.transparent);
    expect(WindowsAppearance.theme(Brightness.dark).cardTheme.color!.a,
        lessThan(1));
    expect(WindowsAppearance.brandRevision, 'live-test');
  });

  testWidgets('glass panels contain original controls and preserve semantics',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LiquidGlassPanel(
          child: TextButton(
            onPressed: () {},
            child: const Text('Open school records'),
          ),
        ),
      ),
    ));
    expect(find.text('Open school records'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byType(TextButton), findsOneWidget);
  });

  testWidgets('Windows frosted surface preserves controls and opt-out',
      (tester) async {
    var clicked = 0;
    Widget harness({required bool glass}) => MaterialApp(
          home: Scaffold(
            body: LiquidGlassSurface(
              enabled: glass,
              radius: 19,
              child: TextButton(
                onPressed: () => clicked++,
                child: const Text('Open student records'),
              ),
            ),
          ),
        );

    await tester.pumpWidget(harness(glass: false));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('Open student records'), findsOneWidget);
    await tester.tap(find.text('Open student records'));
    expect(clicked, 1);

    await tester.pumpWidget(harness(glass: true));
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byType(ClipRRect), findsOneWidget);
    expect(find.text('Open student records'), findsOneWidget);
    await tester.tap(find.text('Open student records'));
    expect(clicked, 2);
  });

  testWidgets('reduced-motion glass backdrop remains usable',
      (tester) async {
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: MaterialApp(
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: LiquidGlassBackdrop(child: const Text('School dashboard')),
        ),
      ),
    ));
    expect(find.text('School dashboard'), findsOneWidget);
  });
}

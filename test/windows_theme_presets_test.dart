import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_appearance.dart';
import '../lib/windows_theme_presets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'all supplied presets change native surfaces and persist their identity',
    () async {
      final dir = await Directory.systemTemp.createTemp('preset-test-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/appearance.json');
      final original = WindowsAppearance.brandData;
      addTearDown(() => WindowsAppearance.applyBrand(original, persist: false));
      expect(windowsThemePresets.length, 6);
      for (final preset in windowsThemePresets) {
        expect(File(preset.image).existsSync(), isTrue);
        expect(File(preset.wave).existsSync(), isTrue);
        final data = {
          'schemaVersion': 1,
          'red': (preset.seed.r * 255).round(),
          'green': (preset.seed.g * 255).round(),
          'blue': (preset.seed.b * 255).round(),
          'revision': preset.id,
          'presetId': preset.id,
        };
        WindowsAppearance.applyBrand(data, persist: false);
        expect(WindowsAppearance.presetId, preset.id);
        expect(
          WindowsAppearance.mode.value,
          preset.light ? ThemeMode.light : ThemeMode.dark,
        );
        expect(
          WindowsAppearance.theme(Brightness.dark).colorScheme.surface,
          preset.darkSurface,
        );
        for (final brightness in Brightness.values) {
          final scheme = WindowsAppearance.theme(brightness).colorScheme;
          expect(
            WindowsAppearance.contrast(scheme.onSurface, scheme.surface),
            greaterThanOrEqualTo(4.5),
          );
          expect(
            WindowsAppearance.contrast(scheme.primary, scheme.onPrimary),
            greaterThanOrEqualTo(4.5),
          );
        }
        await WindowsAppearance.persist(file: file);
        WindowsAppearance.applyBrand({
          'schemaVersion': 1,
          'red': 0,
          'green': 140,
          'blue': 120,
          'revision': 'custom',
        }, persist: false);
        await WindowsAppearance.restore(file: file);
        expect(WindowsAppearance.presetId, preset.id);
        expect(WindowsAppearance.brandRevision, preset.id);
      }
    },
  );
  test(
    'same RGB custom switch still notifies native app to rebuild surfaces',
    () {
      final p = windowsThemePresets.first;
      final data = {
        'schemaVersion': 1,
        'red': (p.seed.r * 255).round(),
        'green': (p.seed.g * 255).round(),
        'blue': (p.seed.b * 255).round(),
        'revision': 'preset',
        'presetId': p.id,
      };
      WindowsAppearance.applyBrand(data, persist: false);
      final before = WindowsAppearance.changes.value;
      WindowsAppearance.applyBrand({
        ...data,
        'presetId': null,
        'revision': 'custom',
      }, persist: false);
      expect(WindowsAppearance.presetId, isNull);
      expect(WindowsAppearance.changes.value, greaterThan(before));
    },
  );
}

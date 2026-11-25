import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_appearance.dart';
import '../lib/windows_notice_action_menu.dart';
import '../lib/windows_ui_localization.dart';

void main() {
  testWidgets('notice menu stays next to trigger across window sizes and dismisses safely', (tester) async {
    final oldMode = WindowsAppearance.mode.value;
    addTearDown(() async {
      WindowsAppearance.mode.value = oldMode;
      await tester.binding.setSurfaceSize(null);
    });
    WindowsAppearance.mode.value = ThemeMode.dark;
    WindowsUiLanguage.change('en');
    final actions = <String>[];
    await tester.binding.setSurfaceSize(const Size(1650, 900));
    await tester.pumpWidget(MaterialApp(
      theme: WindowsAppearance.theme(Brightness.dark),
      home: Scaffold(body: Center(child: FractionallySizedBox(widthFactor: .76,
        child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          WindowsNoticeActionMenu(onSelected: actions.add),
        ]),
      ))),
    ));
    final anchor = find.byKey(WindowsNoticeActionMenu.anchorKey);
    final preview = find.widgetWithText(PopupMenuItem<String>, 'Preview');
    for (final size in [const Size(1650, 900), const Size(1080, 650)]) {
      await tester.binding.setSurfaceSize(size);
      await tester.pumpAndSettle();
      await tester.tap(anchor);
      await tester.pumpAndSettle();
      final buttonRect = tester.getRect(anchor);
      final menuRect = tester.getRect(preview);
      expect((menuRect.right - buttonRect.right).abs(), lessThan(12));
      expect(menuRect.top, greaterThanOrEqualTo(buttonRect.bottom));
      expect(menuRect.right, lessThanOrEqualTo(size.width));
      final material = find.ancestor(of: preview, matching: find.byType(Material)).first;
      final surface = tester.widget<Material>(material).color;
      expect(surface, isNotNull);
      expect(surface!.computeLuminance(), lessThan(.25));
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      expect(preview, findsNothing);
      expect(actions, isEmpty);
    }
    await tester.tap(anchor);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(PopupMenuItem<String>, 'Edit'));
    await tester.pumpAndSettle();
    expect(actions, ['edit']);
    expect(preview, findsNothing);
    expect(tester.takeException(), isNull);
  });
}

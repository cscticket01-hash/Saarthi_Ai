import 'package:flutter/material.dart' hide Text, InputDecoration;
import 'windows_ui_localization.dart';
import 'windows_app_reset.dart';
import 'windows_local_settings.dart';

class WindowsPreferencesReset {
  static const academicYearKey = 'vidya_saarthi_windows_academic_year_rollover_month_v1';
  static Future<void> reset() => WindowsAppReset.reset();

  static Future<void> confirmAndReset(BuildContext context) async {
    final password = TextEditingController();
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialog) => AlertDialog(
        title: const Text('Reset app settings'),
        content: SizedBox(width: 460, child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Remove app passwords, logins, Google Drive and Firebase links, licence activation and app preferences. School data, local files, Drive files and pending work are kept. Reconnect the same school to restore its data. The original trial date stays unchanged.'),
          const SizedBox(height: 16),
          if (WindowsLocalSecurity.configured) TextField(controller: password, obscureText: true,
            decoration: const InputDecoration(labelText: 'Current Local Password')),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () {
            if (WindowsLocalSecurity.configured && !WindowsLocalSecurity.verifyPassword(password.text)) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Current Settings Password galat hai.')));
              return;
            }
            Navigator.pop(ctx, true);
          }, child: const Text('Reset app settings'))],
      )));
    password.dispose();
    if (confirmed != true || !context.mounted) return;
    showDialog<void>(context: context, barrierDismissible: false, builder: (_) => const PopScope(
      canPop: false, child: AlertDialog(content: Row(children: [CircularProgressIndicator(), SizedBox(width: 20), Expanded(child: Text('Resetting app. Keeping school data safe…'))]))));
    try {
      await reset();
      if (!context.mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil('/first-run', (_) => false);
    } catch (e) {
      if (context.mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Reset failed: $e')));
      }
    }
  }
}

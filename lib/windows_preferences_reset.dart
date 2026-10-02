import 'package:flutter/material.dart' hide Text, InputDecoration;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'windows_ui_localization.dart';
import 'windows_local_firestore.dart';
import 'windows_local_settings.dart';

class WindowsPreferencesReset {
  static const academicYearKey = 'vidya_saarthi_windows_academic_year_rollover_month_v1';
  /// Whitelist reset: no database deletion, folder move, sign-out, secure-storage
  /// wipe, connection change, trial reset or loss of an in-memory offline store.
  static Future<void> reset() async {
    await FirebaseFirestore.instance.collection('school_settings').doc('document_templates').set({});
    await FirebaseFirestore.instance.collection('school_settings').doc('promotion_policy').set({'allowForcedPromotion': false});
    await const FlutterSecureStorage().write(key: academicYearKey, value: '1');
    WindowsUiLanguage.change('en');
  }

  static Future<void> confirmAndReset(BuildContext context) async {
    final password = TextEditingController();
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialog) => AlertDialog(
        title: const Text('Reset app settings'),
        content: SizedBox(width: 460, child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Restore language, academic-year preference, document templates and force-promotion settings to defaults. School records, offline work, backend links, passwords, storage location and licence/trial dates are preserved.'),
          const SizedBox(height: 16),
          TextField(controller: password, obscureText: true,
            decoration: const InputDecoration(labelText: 'Current Local Password')),
        ])),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () {
            if (!WindowsLocalSecurity.verifyPassword(password.text)) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Current Settings Password galat hai.')));
              return;
            }
            Navigator.pop(ctx, true);
          }, child: const Text('Reset app settings'))],
      )));
    password.dispose();
    if (confirmed != true || !context.mounted) return;
    try {
      await reset();
      if (!context.mounted) return;
      Navigator.of(context).pushNamedAndRemoveUntil('/dashboard', (_) => false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('App settings reset. School data and licence were preserved.')));
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Reset failed: $e')));
    }
  }
}

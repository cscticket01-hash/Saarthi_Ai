import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'windows_ui_localization.dart';
import 'windows_local_settings.dart';
import 'windows_local_session.dart';
import 'windows_local_auth.dart';
import 'windows_firebase_sync.dart';
import 'windows_sync_engine.dart';
import 'windows_connection_center.dart';
import 'windows_platform_client.dart';
import 'windows_license_gate.dart';
import 'windows_html_shim.dart' as html;

class WindowsAppReset {
  static bool _busy = false;
  /// No school database, pending outbox, media file or Drive resource is deleted.
  /// Preserve data folder/mode and immutable device/trial/denial evidence.
  static Future<void> reset() async {
    if (_busy) throw StateError('Reset is already running.');
    _busy = true;
    try {
      await WindowsSyncEngine.instance.pauseForAppReset();
      await WindowsConnectionCenter.finishInitialization();
      await WindowsPlatformClient.instance.resetAppActivation();
      await WindowsExternalConnections.save(googleScriptUrl: '', googleEmail: '', firebaseLink: '');
      await WindowsFirebaseRemote.disconnect();
      const secure = FlutterSecureStorage();
      final settings = await secure.readAll();
      for (final key in settings.keys.toList()) {
        if (key.startsWith('vidya_saarthi_windows_')) await secure.delete(key: key);
      }
      await WindowsLocalSecurity.clearAppLock();
      await FirebaseAuth.instance.signOut();
      await WindowsLocalSession.resetAppSession();
      await html.clearAppLoginSessions();
      WindowsUiLanguage.change('en');
      await WindowsPlatformClient.instance.clearLicenseSkipped();
      WindowsLicenseGate.reopenAfterReset();
      await WindowsConnectionCenter.initialize();
    } finally {
      WindowsPlatformClient.instance.resumeAfterAppReset();
      _busy = false;
    }
  }
}

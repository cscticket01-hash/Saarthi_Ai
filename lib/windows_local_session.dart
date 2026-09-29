import 'dart:convert';
import 'dart:io';

class WindowsLocalSession {
  WindowsLocalSession._();

  static bool _loggedOut = false;

  static File get _file {
    final base = Platform.environment['APPDATA'] ??
        Platform.environment['LOCALAPPDATA'];
    if (base == null || base.trim().isEmpty) {
      throw StateError('Windows application data folder unavailable.');
    }
    return File(
      '$base${Platform.pathSeparator}VidyaSaarthi${Platform.pathSeparator}local_session_v1.json',
    );
  }

  static bool get loggedOut => _loggedOut;

  static Future<void> initialize() async {
    try {
      if (!await _file.exists()) {
        _loggedOut = false;
        return;
      }
      final decoded = jsonDecode(await _file.readAsString());
      _loggedOut = decoded is Map && decoded['loggedOut'] == true;
    } catch (_) {
      _loggedOut = false;
    }
  }

  static Future<void> markLoggedIn() async {
    _loggedOut = false;
    await _write();
  }

  static Future<void> logout() async {
    _loggedOut = true;
    await _write();
  }

  static Future<void> _write() async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(
      jsonEncode({
        'loggedOut': _loggedOut,
        'updatedAt': DateTime.now().toIso8601String(),
      }),
      flush: true,
    );
  }
}

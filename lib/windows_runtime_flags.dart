import 'dart:convert';
import 'dart:io';

class WindowsRuntimeFlags {
  WindowsRuntimeFlags._();

  static File _file() {
    final appData = Platform.environment['APPDATA'] ?? Directory.current.path;
    return File('$appData${Platform.pathSeparator}VidyaSaarthi${Platform.pathSeparator}runtime_flags.json');
  }

  static Future<bool> localStorageEnabled() async {
    try {
      final file = _file();
      if (!await file.exists()) return true;
      final raw = jsonDecode(await file.readAsString());
      return raw is Map ? raw['localStorageEnabled'] != false : true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setLocalStorageEnabled(bool value) async {
    final file = _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({
      'localStorageEnabled': value,
      'updatedAt': DateTime.now().toIso8601String(),
    }), flush: true);
  }
}

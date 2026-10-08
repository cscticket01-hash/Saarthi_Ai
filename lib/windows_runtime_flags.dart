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

  static Future<Map<String, dynamic>> _readFlags() async {
    final file = _file();
    if (!await file.exists()) return {};
    final value = jsonDecode(await file.readAsString());
    if (value is! Map) throw const FormatException('Invalid storage preferences');
    return Map<String, dynamic>.from(value);
  }

  static Future<bool> durableSchoolProfile(String profile) async {
    final flags = await _readFlags();
    return (flags['durableSchoolProfiles'] as Map?)?[profile] == true;
  }

  static Future<void> setDurableSchoolProfile(String profile, bool enabled) async {
    final flags = await _readFlags();
    final profiles = Map<String, dynamic>.from(flags['durableSchoolProfiles'] as Map? ?? {});
    if (enabled) { profiles[profile] = true; } else { profiles.remove(profile); }
    final file = _file();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode({...flags, 'durableSchoolProfiles': profiles}), flush: true);
  }

  static Future<void> setLocalStorageEnabled(bool value) async {
    final file = _file();
    await file.parent.create(recursive: true);
    final existing = await _readFlags();
    await file.writeAsString(jsonEncode({
      ...existing,
      'localStorageEnabled': value,
      'updatedAt': DateTime.now().toIso8601String(),
    }), flush: true);
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class WindowsLocalSecurity {
  WindowsLocalSecurity._();

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  static const String _adminIdKey = 'vidya_saarthi_windows_admin_id_v1';
  static const String _adminPasswordKey =
      'vidya_saarthi_windows_admin_password_v1';

  static String? _adminId;
  static String? _adminPassword;

  static Future<void> initialize() async {
    _adminId = (await _secure.read(key: _adminIdKey))?.trim();
    _adminPassword = await _secure.read(key: _adminPasswordKey);

    if (_adminId != null && _adminId!.isEmpty) {
      _adminId = null;
    }

    if (_adminPassword != null && _adminPassword!.isEmpty) {
      _adminPassword = null;
    }
  }

  static bool get configured =>
      (_adminId?.isNotEmpty ?? false) &&
      (_adminPassword?.isNotEmpty ?? false);

  static String get adminId =>
      configured ? _adminId! : 'Local Administrator';

  static Future<void> create({
    required String adminId,
    required String password,
  }) async {
    if (configured) {
      throw StateError('Local Settings Lock already configured hai.');
    }

    await _writeCredentials(
      adminId: adminId,
      password: password,
    );
  }

  static Future<void> change({
    required String currentPassword,
    required String newAdminId,
    required String newPassword,
  }) async {
    if (!configured) {
      await _writeCredentials(
        adminId: newAdminId,
        password: newPassword,
      );
      return;
    }

    if (!verifyPassword(currentPassword)) {
      throw StateError('Current Settings Password galat hai.');
    }

    await _writeCredentials(
      adminId: newAdminId,
      password: newPassword,
    );
  }

  static Future<void> _writeCredentials({
    required String adminId,
    required String password,
  }) async {
    final cleanId = adminId.trim();

    if (cleanId.length < 3) {
      throw const FormatException(
        'Local Admin ID kam se kam 3 characters ka hona chahiye.',
      );
    }

    if (password.length < 6) {
      throw const FormatException(
        'Settings Password kam se kam 6 characters ka hona chahiye.',
      );
    }

    await _secure.write(
      key: _adminIdKey,
      value: cleanId,
    );

    await _secure.write(
      key: _adminPasswordKey,
      value: password,
    );

    _adminId = cleanId;
    _adminPassword = password;
  }

  static bool verify({
    required String adminId,
    required String password,
  }) {
    if (!configured) return false;

    return adminId.trim() == _adminId &&
        password == _adminPassword;
  }

  static bool verifyPassword(String password) {
    if (!configured) return false;
    return password == _adminPassword;
  }
}

class WindowsExternalConnections {
  WindowsExternalConnections._();

  static File get _file {
    final base =
        Platform.environment['APPDATA'] ??
        Platform.environment['LOCALAPPDATA'];

    if (base == null) {
      throw StateError(
        'Windows application data folder unavailable.',
      );
    }

    return File(
      '$base${Platform.pathSeparator}'
      'VidyaSaarthi${Platform.pathSeparator}'
      'windows_connections_v1.json',
    );
  }

  static Future<Map<String, dynamic>> load() async {
    try {
      if (!await _file.exists()) {
        return <String, dynamic>{};
      }

      final decoded = jsonDecode(
        await _file.readAsString(),
      );

      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}

    return <String, dynamic>{};
  }

  static Future<void> save({
    String? firebaseLink,
  }) async {
    final existing = await load();

    // Google Cloud Console ka separate Windows setting intentionally removed.
    existing.remove('googleCloudConsoleLink');
    existing.remove('googleCloudUpdatedAt');

    if (firebaseLink != null) {
      final value = firebaseLink.trim();

      if (value.isEmpty) {
        existing.remove('firebaseLink');
        existing.remove('firebaseUpdatedAt');
      } else {
        _validateFirebaseLink(value);
        existing['firebaseLink'] = value;
        existing['firebaseUpdatedAt'] =
            DateTime.now().millisecondsSinceEpoch;
      }
    }

    await _file.parent.create(recursive: true);
    final pending = File('${_file.path}.pending');
    await pending.writeAsString(jsonEncode(existing), flush: true);
    if (await _file.exists()) {
      await _file.delete();
    }
    await pending.rename(_file.path);
  }

  static Map<String, dynamic> decodeFirebaseLink(
    String input,
  ) {
    return _validateFirebaseLink(input.trim());
  }

  static Map<String, dynamic> _validateFirebaseLink(
    String value,
  ) {
    final uri = Uri.tryParse(value);

    if (uri == null ||
        uri.scheme != 'vidyasaarthi' ||
        uri.host != 'firebase') {
      throw const FormatException(
        'Valid vidyasaarthi://firebase?config= link daalein.',
      );
    }

    final encoded = uri.queryParameters['config'];

    if (encoded == null || encoded.trim().isEmpty) {
      throw const FormatException(
        'Firebase link me config missing hai.',
      );
    }

    dynamic decoded;

    try {
      decoded = jsonDecode(
        utf8.decode(
          base64Url.decode(
            base64Url.normalize(encoded),
          ),
        ),
      );
    } catch (_) {
      throw const FormatException(
        'Firebase config link decode nahi hua.',
      );
    }

    if (decoded is! Map) {
      throw const FormatException(
        'Firebase config invalid hai.',
      );
    }

    final config = Map<String, dynamic>.from(decoded);

    for (final key in const <String>[
      'apiKey',
      'appId',
      'messagingSenderId',
      'projectId',
    ]) {
      final value = config[key];

      if (value is! String || value.trim().isEmpty) {
        throw FormatException(
          'Firebase config me $key missing hai.',
        );
      }
    }

    if (config.containsKey('private_key') ||
        config.containsKey('client_email') ||
        config.containsKey('password')) {
      throw const FormatException(
        'Service-account/private key Firebase link me allowed nahi hai.',
      );
    }

    return config;
  }


}

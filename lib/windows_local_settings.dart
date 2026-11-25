import 'windows_connect/central_school_cloud.dart';
import 'windows_connect/managed_school_session.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'dart:io';

import 'windows_secure_storage.dart';

class WindowsLocalSecurity {
  WindowsLocalSecurity._();

  static const WindowsSecureStorage _secure = WindowsSecureStorage();

  static String _schoolSuffix='';
  static String get _adminIdKey => 'vidya_saarthi_windows_admin_id_v1$_schoolSuffix';
  static String get _adminPasswordKey =>
      'vidya_saarthi_windows_admin_password_v1$_schoolSuffix';

  static String? _adminId;
  static String? _adminPassword;
  static _AppLockRecoveryGrant? _recoveryGrant;
  static int _recoveryEpoch = 0;

  static Future<void> initialize() async {
    cancelAppLockRecovery();
    final saved=await CentralSchoolCloud.saved();
    _schoolSuffix=saved['managed']==true?'_${saved['schoolId']}':'';
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

  static Future<void> clearAppLock() async {
    cancelAppLockRecovery();
    await _secure.delete(key: _adminIdKey);
    await _secure.delete(key: _adminPasswordKey);
    _adminId = null;
    _adminPassword = null;
  }

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

  // Verification is scoped to the existing school account and active PC.
  // A typed School ID is never a credential and is never used to switch schools.
  static void cancelAppLockRecovery() {
    _recoveryEpoch++;
    _recoveryGrant = null;
  }

  static Future<void> verifySchoolForAppLockRecovery({
    required String schoolId,
  }) async {
    cancelAppLockRecovery();
    final epoch = _recoveryEpoch;
    final id = schoolId.trim();
    final saved = await CentralSchoolCloud.saved();
    if (!configured || !RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(id) ||
        saved['managed'] != true || saved['schoolId'] != id ||
        saved['uid'] is! String || (saved['uid'] as String).isEmpty ||
        _schoolSuffix != '_$id' || epoch != _recoveryEpoch) {
      throw StateError('Enter the registered School ID.');
    }
    final key = _adminPasswordKey;
    final currentPassword = _adminPassword;
    final elapsed = Stopwatch()..start();
    final result = await ManagedSchoolSession.callForSchool(id,
      'managed/app-lock/recovery/verify',
      {'recoverySchoolId': id});
    final current = await CentralSchoolCloud.saved();
    final token = result['approvalToken'];
    if (result['success'] != true || result['authorized'] != true ||
        result['schoolId'] != id || token is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(token) ||
        epoch != _recoveryEpoch || current['managed'] != true ||
        current['schoolId'] != id || current['uid'] != saved['uid'] ||
        _adminPasswordKey != key || _adminPassword != currentPassword ||
        elapsed.elapsed >= const Duration(minutes: 2)) {
      throw StateError('School verification failed or expired. Try again.');
    }
    _recoveryGrant = _AppLockRecoveryGrant(
      schoolId: id, uid: saved['uid'] as String, storageKey: key,
      previousPassword: currentPassword!, token: token, elapsed: elapsed);
  }

  static Future<void> recoverWithSchoolApproval({
    required String newPassword, required String confirmPassword,
  }) async {
    final grant = _recoveryGrant;
    if (newPassword != confirmPassword || newPassword.length < 6 ||
        newPassword.length > 128) {
      throw StateError('Enter matching App Lock passwords (6–128 characters).');
    }
    if (grant == null || !configured ||
        grant.elapsed.elapsed >= const Duration(minutes: 2) ||
        grant.storageKey != _adminPasswordKey ||
        grant.previousPassword != _adminPassword) {
      cancelAppLockRecovery();
      throw StateError('Verify School ID again.');
    }
    // Consume locally before awaiting the server. Never reuse an approval.
    cancelAppLockRecovery();
    final epoch = _recoveryEpoch;
    final before = await CentralSchoolCloud.saved();
    if (before['managed'] != true || before['schoolId'] != grant.schoolId ||
        before['uid'] != grant.uid || epoch != _recoveryEpoch) {
      throw StateError('School changed. Verify again.');
    }
    final result = await ManagedSchoolSession.callForSchool(grant.schoolId,
      'managed/app-lock/recovery/consume',
      {'recoverySchoolId': grant.schoolId, 'approvalToken': grant.token});
    final current = await CentralSchoolCloud.saved();
    if (result['success'] != true || result['authorized'] != true ||
        result['schoolId'] != grant.schoolId ||
        current['managed'] != true || current['schoolId'] != grant.schoolId ||
        current['uid'] != grant.uid || epoch != _recoveryEpoch ||
        grant.storageKey != _adminPasswordKey ||
        grant.previousPassword != _adminPassword || !configured) {
      throw StateError('Recovery authorization expired or school changed.');
    }
    // Only the local App Lock is changed, not Firebase or Admin Password.
    await _secure.write(key: grant.storageKey, value: newPassword);
    if (_adminPasswordKey == grant.storageKey && epoch == _recoveryEpoch) {
      _adminPassword = newPassword;
    }
  }

  static Future<void> _writeCredentials({
    required String adminId,
    required String password,
  }) async {
    cancelAppLockRecovery();
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
    final supplied = sha256.convert(utf8.encode(password)).bytes;
    final expected = sha256.convert(utf8.encode(_adminPassword!)).bytes;
    var difference = 0;
    for (var index = 0; index < expected.length; index++) {
      difference |= supplied[index] ^ expected[index];
    }
    return difference == 0;
  }
}

class _AppLockRecoveryGrant {
  _AppLockRecoveryGrant({
    required this.schoolId, required this.uid, required this.storageKey,
    required this.previousPassword, required this.token,
    required this.elapsed,
  });
  final String schoolId, uid, storageKey, previousPassword, token;
  final Stopwatch elapsed;
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
    String? googleScriptUrl,
    String? googleEmail,
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

    if (googleScriptUrl != null) {
      final value = googleScriptUrl.trim();

      if (value.isEmpty) {
        existing.remove('googleScriptUrl');
        existing.remove('googleEmail');
        existing.remove('googleUpdatedAt');
      } else {
        _validateGoogleScriptUrl(value);
        existing['googleScriptUrl'] = value;
        if (googleEmail != null) {
          existing['googleEmail'] = googleEmail.trim();
        }
        existing['googleUpdatedAt'] =
            DateTime.now().millisecondsSinceEpoch;
      }
    } else if (googleEmail != null) {
      final email = googleEmail.trim();
      if (email.isEmpty) {
        existing.remove('googleEmail');
      } else {
        existing['googleEmail'] = email;
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

  static Future<String> googleScriptUrl() async {
    final central = await CentralSchoolCloud.saved();
    if (central['managed']==true) return central['scriptUrl']?.toString()??'';
    if (central.isNotEmpty) return 'https://www.googleapis.com/drive/v3/files/${central['folderId']}';
    final data = await load();
    return data['googleScriptUrl']?.toString().trim() ?? '';
  }

  static Future<String> googleEmail() async {
    final central = await CentralSchoolCloud.saved();
    if (central.isNotEmpty) return central['email'];
    final data = await load();
    return data['googleEmail']?.toString().trim() ?? '';
  }

  static Map<String, dynamic> decodeFirebaseLink(
    String input,
  ) {
    return _validateFirebaseLink(input.trim());
  }

  static void validateGoogleScriptUrl(String input) {
    _validateGoogleScriptUrl(input.trim());
  }

  static void _validateGoogleScriptUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'script.google.com' ||
        !uri.path.contains('/macros/s/') ||
        !uri.path.endsWith('/exec')) {
      throw const FormatException(
        'Valid Google Apps Script /exec URL daalein.',
      );
    }
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
      final fieldValue = config[key];

      if (fieldValue is! String || fieldValue.trim().isEmpty) {
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

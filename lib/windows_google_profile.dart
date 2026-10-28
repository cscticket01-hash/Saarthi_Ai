import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'windows_secure_storage.dart';
import 'windows_profile_image_policy.dart';
import 'windows_connect/google_authorization.dart';

/// Separate from school credentials: connecting a photo never changes login,
/// Drive setup, password, Firebase tokens or the active school.
class WindowsGoogleProfileStore {
  WindowsGoogleProfileStore({
    Future<String?> Function(String)? read,
    Future<void> Function(String, String)? write,
  }) : _read = read ?? ((key) => const WindowsSecureStorage().read(key: key)),
       _write =
           write ??
           ((key, value) =>
               const WindowsSecureStorage().write(key: key, value: value));
  final Future<String?> Function(String) _read;
  final Future<void> Function(String, String) _write;

  String _key(String uid, String school) =>
      'vidya_saarthi_google_photo_${sha256.convert(utf8.encode(jsonEncode([uid, school])))}';

  Future<String> photo({
    required String uid,
    required String school,
    required String email,
  }) async {
    if (uid.isEmpty || school.isEmpty || email.trim().isEmpty) return '';
    try {
      final raw = await _read(_key(uid, school));
      if (raw == null) return '';
      final data = jsonDecode(raw);
      if (data is! Map ||
          data['uid'] != uid ||
          data['schoolId'] != school ||
          data['email'] != email.trim().toLowerCase() ||
          data['subject'] is! String ||
          (data['subject'] as String).isEmpty)
        return '';
      final source = data['photoUrl']?.toString() ?? '';
      return verifiedGoogleProfileImageUrl(source) ? source : '';
    } catch (_) {
      return '';
    }
  }

  Future<void> save(
    GoogleSetupAccount account, {
    required String uid,
    required String school,
    required String email,
    required Future<bool> Function() isCurrent,
  }) async {
    if (uid.isEmpty ||
        school.isEmpty ||
        email.trim().isEmpty ||
        account.email.trim().toLowerCase() != email.trim().toLowerCase()) {
      throw StateError(
        'Choose the same Gmail address as your signed-in admin account.',
      );
    }
    if (account.subject.isEmpty ||
        !verifiedGoogleProfileImageUrl(account.photoUrl)) {
      throw StateError(
        'Google did not return a profile photo for this account.',
      );
    }
    if (!await isCurrent())
      throw StateError(
        'Account changed. Open Settings for the current account.',
      );
    await _write(
      _key(uid, school),
      jsonEncode({
        'uid': uid,
        'schoolId': school,
        'email': email.trim().toLowerCase(),
        'subject': account.subject,
        'photoUrl': account.photoUrl,
      }),
    );
  }
}

import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;

import 'windows_local_firestore.dart';
import 'windows_local_settings.dart';
import 'windows_secure_storage.dart';

/// Per-profile administrator credential for legacy standalone schools.
/// Managed schools use the server-side school-wide credential instead.
/// A local credential is never a Firebase, Google or developer login.
class WindowsLocalAdminSecurity {
  WindowsLocalAdminSecurity._();

  static const _storage=WindowsSecureStorage();
  static const _prefix='local-admin-pbkdf2-sha256-v1';
  static const _legacyKey='vidya_saarthi_windows_section_password_v1_admin_section';

  static String _key() {
    final profile=FirebaseFirestore.instance.activeProfileId;
    if(profile.isEmpty)throw StateError('Open a school profile before configuring Admin Password.');
    return 'saarthi_local_admin_v1_${sha256.convert(utf8.encode(profile))}';
  }

  static Future<String?> _stored() async =>
      await _storage.read(key:_key()) ??
      await _storage.read(key:_legacyKey);

  static Future<bool> configured() async {
    final saved=await _stored();
    return saved!=null && saved.isNotEmpty;
  }

  static Future<String?> fingerprint() async {
    final saved=await _stored();
    if(saved==null)return null;
    return sha256.convert(utf8.encode(saved)).toString();
  }

  static void _policy(String password) {
    if(password.length<12||password.length>128||password!=password.trim())
      throw StateError('Admin Password must contain 12–128 characters without surrounding spaces.');
    if(WindowsLocalSecurity.verifyPassword(password))
      throw StateError('Admin Password must be different from App Lock.');
  }

  static Future<String> _encode(String password) async {
    final rng=Random.secure();
    final salt=base64Url.encode(List<int>.generate(16,(_)=>rng.nextInt(256)))
        .replaceAll('=','');
    final value=await compute(_deriveLocalAdminPassword,
        {'password':password,'salt':salt});
    return '$_prefix:$salt:$value';
  }

  static bool _fixedEquals(String a,String b) {
    if(a.length!=b.length)return false;
    var mismatch=0;
    for(var i=0;i<a.length;i++)mismatch|=a.codeUnitAt(i)^b.codeUnitAt(i);
    return mismatch==0;
  }

  static Future<bool> _check(String saved,String password) async {
    if(password.isEmpty||password.length>128)return false;
    final parts=saved.split(':');
    if(parts.length==3 && (_prefix==parts[0]||parts[0]=='pbkdf2-sha256-v1')) {
      if(!RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(parts[1])||
         !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(parts[2]))return false;
      final candidate=await compute(_deriveLocalAdminPassword,
          {'password':password,'salt':parts[1]});
      return _fixedEquals(candidate,parts[2]);
    }
    return _fixedEquals(saved,password);
  }

  static Future<void> verify(String password) async {
    final saved=await _stored();
    if(saved==null||!await _check(saved,password))
      throw StateError('Wrong Admin Password.');
    if(!saved.startsWith('$_prefix:')) {
      // Authenticate first; then migrate a historical local Admin-section
      // password into the new separate, per-profile hashed credential.
      await _storage.write(key:_key(),value:await _encode(password));
    }
  }

  static Future<void> enroll(String password) async {
    _policy(password);
    if(await configured())
      throw StateError('Admin Password is already configured.');
    await _storage.write(key:_key(),value:await _encode(password));
  }

  static Future<void> change(String currentPassword,String newPassword) async {
    await verify(currentPassword);
    _policy(newPassword);
    if(currentPassword==newPassword)
      throw StateError('Choose a different Admin Password.');
    await _storage.write(key:_key(),value:await _encode(newPassword));
  }
}

/// Isolate-safe PBKDF2-HMAC-SHA256, 120,000 rounds, 32-byte derived key.
String _deriveLocalAdminPassword(Map<String,String> input) {
  final key=utf8.encode(input['password']!);
  final salt=base64Url.decode(base64Url.normalize(input['salt']!));
  final hmac=Hmac(sha256,key);
  var block=hmac.convert([...salt,0,0,0,1]).bytes;
  final output=List<int>.from(block);
  for(var n=1;n<120000;n++) {
    block=hmac.convert(block).bytes;
    for(var i=0;i<output.length;i++)output[i]^=block[i];
  }
  return base64Url.encode(output).replaceAll('=','');
}

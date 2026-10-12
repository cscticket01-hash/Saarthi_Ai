import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'windows_secure_storage.dart';

typedef IdCardKeyProvider = Future<Uint8List> Function();

/// Existing plaintext is never silently trusted, overwritten or erased.
class IdCardLegacyPlaintextException extends FormatException {
  const IdCardLegacyPlaintextException()
      : super('Unprotected legacy ID storage requires explicit migration. Original file retained.');
}

/// AES-GCM envelopes bind bytes to school and purpose. Keys are held in the
/// existing OS credential store, not beside student/photo/QR files.
class IdCardLocalCipher {
  IdCardLocalCipher(this.schoolId, Uint8List key)
      : _key = Uint8List.fromList(key) {
    if (schoolId.trim().isEmpty || key.length != 32) {
      throw ArgumentError('School and 256-bit ID storage key required');
    }
  }
  final String schoolId;
  final Uint8List _key;
  Uint8List get keyBytes => Uint8List.fromList(_key);
  static Future<Uint8List> schoolKey(String schoolId) =>
      WindowsSecureStorage.run(() async {
        const storage = FlutterSecureStorage();
        final name = 'vidya_id_storage_v1_${sha256.convert(utf8.encode(schoolId))}';
        final old = await storage.read(key: name);
        if (old != null) {
          final bytes = base64Decode(old);
          if (bytes.length != 32) throw StateError('ID storage key requires recovery');
          return bytes;
        }
        final random = Random.secure();
        final bytes = Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
        await storage.write(key: name, value: base64Encode(bytes));
        if (await storage.read(key: name) != base64Encode(bytes)) {
          throw StateError('ID storage key could not be durably verified');
        }
        return bytes;
      });

  List<int> _aad(String purpose) => utf8.encode(jsonEncode([1, schoolId, purpose]));
  Future<Uint8List> seal(Uint8List bytes, String purpose) async {
    final box = await AesGcm.with256bits().encrypt(
      bytes, secretKey: SecretKey(_key), aad: _aad(purpose),
    );
    return Uint8List.fromList(utf8.encode(jsonEncode({
      'protectedIdStorage': 1,
      'nonce': base64Encode(box.nonce),
      'mac': base64Encode(box.mac.bytes),
      'ciphertext': base64Encode(box.cipherText),
    })));
  }

  Future<Uint8List> open(Uint8List encoded, String purpose, {required int maxBytes}) async {
    if (encoded.length > ((maxBytes + 16) * 4 ~/ 3) + 4096) {
      throw const FormatException('Protected ID file exceeds size budget');
    }
    try {
      final value = jsonDecode(utf8.decode(encoded));
      if (value is! Map || value['protectedIdStorage'] != 1) {
        throw const IdCardLegacyPlaintextException();
      }
      final nonce = base64Decode(value['nonce'] as String);
      final mac = base64Decode(value['mac'] as String);
      final body = base64Decode(value['ciphertext'] as String);
      if (nonce.length != 12 || mac.length != 16 || body.length > maxBytes) {
        throw const FormatException('Invalid protected ID envelope');
      }
      return Uint8List.fromList(await AesGcm.with256bits().decrypt(
        SecretBox(body, nonce: nonce, mac: Mac(mac)),
        secretKey: SecretKey(_key), aad: _aad(purpose),
      ));
    } on IdCardLegacyPlaintextException {
      rethrow;
    } catch (_) {
      throw const FormatException('Protected ID storage authentication failed');
    }
  }
}

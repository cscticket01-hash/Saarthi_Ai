import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Shared immutable card identity policy. No platform storage dependencies.
class IdCardIdentity {
  static const greenBlueId = 'student-green-blue-modern-v1';
  static const greenBlueSha256 = '08912d18ce48222ac150f0b3bd3189270ad96534e7764d243d8456d8d243e2b9';
  static bool isApprovedGreenBlueArtwork(Uint8List bytes) =>
      bytes.length == 337769 && sha256.convert(bytes).toString() == greenBlueSha256;
  static bool isGlobalId(String id)=>RegExp(r'^gid-[a-f0-9]{32}$').hasMatch(id);
}

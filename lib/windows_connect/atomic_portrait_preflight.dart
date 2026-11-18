import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

import '../document_processing_engine.dart';
import '../school_image_input.dart';

/// Preflight for the existing TEST atomic photo lane, not a new compressor,
/// file store or sync queue. This delegates to the single school portrait
/// compressor and never modifies/deletes the original local photo.
class PreparedAtomicPortrait {
  const PreparedAtomicPortrait({
    required this.bytes,
    required this.mime,
    required this.sha256,
    required this.sourceBytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final String mime;
  final String sha256;
  final int sourceBytes;
  final int width;
  final int height;
}

class AtomicPortraitPreflight {
  const AtomicPortraitPreflight._();

  static const int maxBytes = DocumentProcessingEngine.portraitTarget;

  /// Verify the exact *encoded* bytes to be staged. File extension and
  /// declared MIME are never proof of image identity or validity.
  static void verifyStagedBytes(Uint8List bytes, String mime) {
    if (bytes.length < 12 || bytes.length > maxBytes) {
      throw const FormatException('Atomic portrait exceeds the 40 KiB bound.');
    }
    SchoolImageInput.validate(bytes);
    final jpeg = bytes[0] == 0xff &&
        bytes[1] == 0xd8 &&
        bytes[bytes.length - 2] == 0xff &&
        bytes.last == 0xd9;
    const pngMagic = <int>[137, 80, 78, 71, 13, 10, 26, 10];
    final png = bytes.length >= 8 &&
        List.generate(8, (i) => bytes[i]).join(',') == pngMagic.join(',');
    final webp = bytes.length >= 12 &&
        String.fromCharCodes(bytes.sublist(0, 4)) == 'RIFF' &&
        String.fromCharCodes(bytes.sublist(8, 12)) == 'WEBP';
    if (!((mime == 'image/jpeg' && jpeg) ||
        (mime == 'image/png' && png) ||
        (mime == 'image/webp' && webp))) {
      throw const FormatException('Atomic portrait MIME and bytes differ.');
    }
    try {
      final decoder = img.findDecoderForData(bytes);
      final header = decoder?.startDecode(bytes);
      if (header == null ||
          header.width <= 0 ||
          header.height <= 0 ||
          header.width * header.height > 20000000 ||
          decoder!.numFrames() != 1 ||
          decoder.decodeFrame(0) == null) {
        throw const FormatException('Atomic portrait is not a valid single-frame image.');
      }
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Atomic portrait cannot be safely decoded.');
    }
  }

  /// Run off the UI isolate for large sources. An impossible quality/size
  /// target is a failure, never a silently degraded image or fabricated ACK.
  static PreparedAtomicPortrait prepare(Uint8List source) {
    final outcome = DocumentProcessingEngine.portraitUpload({'bytes': source});
    final encoded = outcome['optimized'];
    final mime = outcome['mimeType'];
    if (outcome['targetMet'] != true ||
        encoded is! Uint8List ||
        mime is! String ||
        outcome['width'] is! int ||
        outcome['height'] is! int) {
      throw const FormatException('Portrait has no verified 40 KiB output.');
    }
    verifyStagedBytes(encoded, mime);
    return PreparedAtomicPortrait(
      bytes: encoded,
      mime: mime,
      sha256: sha256.convert(encoded).toString(),
      sourceBytes: source.length,
      width: outcome['width'] as int,
      height: outcome['height'] as int,
    );
  }
}

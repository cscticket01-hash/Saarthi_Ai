import 'dart:typed_data';

/// Checks container bounds before an image decoder sees truncated input.
/// Shared by the existing document and ID engines; it is not a new processor.
class SchoolImageInput {
  static void validate(Uint8List bytes) {
    if (bytes.length < 12 || bytes.length > 50 * 1024 * 1024) {
      throw const FormatException('Image is empty, truncated or too large.');
    }
    const png = [137, 80, 78, 71, 13, 10, 26, 10];
    if (List.generate(8, (i) => bytes[i]).join(',') == png.join(',')) {
      final data = ByteData.sublistView(bytes);
      var offset = 8, chunks = 0;
      var header = false, pixels = false;
      while (offset + 12 <= bytes.length && chunks++ < 100000) {
        final length = data.getUint32(offset);
        if (length > bytes.length - offset - 12) {
          throw const FormatException('Truncated PNG chunk.');
        }
        final kind = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));
        if (!header) {
          if (kind != 'IHDR' || length != 13) throw const FormatException('Invalid PNG header.');
          final width = data.getUint32(offset + 8), height = data.getUint32(offset + 12);
          if (width == 0 || height == 0 || width * height > 20000000) {
            throw const FormatException('Image exceeds decoded safety limit.');
          }
          header = true;
        }
        if (kind == 'IDAT' && length > 0) pixels = true;
        offset += length + 12;
        if (kind == 'IEND') {
          if (length != 0 || !pixels || offset != bytes.length) throw const FormatException('Invalid PNG end.');
          return;
        }
      }
      throw const FormatException('PNG is incomplete.');
    }
    if (bytes[0] == 255 && bytes[1] == 216 &&
        (bytes[bytes.length - 2] != 255 || bytes.last != 217)) {
      throw const FormatException('JPEG is incomplete.');
    }
  }
}

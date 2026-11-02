import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../lib/document_processing_engine.dart';

void main() {
  test('TemplateForge artwork uses the same compression engine with exact pixels', () {
    final source = img.Image(width: 320, height: 440, numChannels: 4);
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        final onLine = y % 37 < 2 || x % 29 < 2;
        source.setPixelRgba(x, y, onLine ? 30 : 255,
            onLine ? 55 : 255, onLine ? 90 : 255,
            x < 8 ? 0 : 255);
      }
    }
    // Deliberately uncompressed PNG to prove that lossless optimization runs.
    final bytes = Uint8List.fromList(img.encodePng(source, level: 0));
    final before = Uint8List.fromList(bytes);
    final result = DocumentProcessingEngine.templateArtworkUpload({'bytes': bytes});
    final output = result['optimized'] as Uint8List;
    expect(bytes, before, reason: 'The source must remain immutable');
    expect(output.length, lessThan(bytes.length));
    expect(result['lossless'], true);
    expect(result['pixelsVerified'], true);
    expect(result['mimeType'], 'image/png');
    final decoded = img.decodePng(output)!;
    expect(decoded.width, source.width);
    expect(decoded.height, source.height);
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        final a = source.getPixel(x, y), b = decoded.getPixel(x, y);
        expect([b.r, b.g, b.b, b.a], [a.r, a.g, a.b, a.a]);
      }
    }
  });

  test('incompressible or complex school art is retained without JPEG fallback', () {
    final source = img.Image(width: 90, height: 110, numChannels: 4);
    final rng = math.Random(1234);
    for (final pixel in source) {
      pixel.r = rng.nextInt(256);
      pixel.g = rng.nextInt(256);
      pixel.b = rng.nextInt(256);
      pixel.a = rng.nextInt(256);
    }
    final original = Uint8List.fromList(img.encodePng(source, level: 9));
    final result = DocumentProcessingEngine.templateArtworkUpload({'bytes': original});
    final optimized = result['optimized'] as Uint8List;
    expect(optimized.length, lessThanOrEqualTo(original.length));
    expect(img.decodePng(optimized), isNotNull);
    expect(result['lossless'], true);
    // No lossy JPEG substitution, even if it would make the file much smaller.
    expect(result['mimeType'], 'image/png');
  });

  test('unsafe or corrupt TemplateForge artwork cannot be published', () {
    expect(() => DocumentProcessingEngine.templateArtworkUpload({
      'bytes': Uint8List.fromList([1, 2, 3, 4])
    }), throwsFormatException);
    expect(() => DocumentProcessingEngine.templateArtworkUpload({
      'bytes': Uint8List(20 * 1024 * 1024 + 1)
    }), throwsFormatException);
  });
}

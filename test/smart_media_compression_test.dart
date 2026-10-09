import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../lib/document_processing_engine.dart';

void main() {
  test(
    'portrait target preserves aspect ratio and avoids document edge cropping',
    () {
      final source = img.Image(width: 1200, height: 600);
      img.fill(source, color: img.ColorRgb8(190, 210, 220));
      final bytes = Uint8List.fromList(img.encodePng(source)),
          copy = bytes.toList();
      final result = DocumentProcessingEngine.process({
        'bytes': bytes,
        'kind': 'portrait',
      });
      expect(result['targetBytes'], 30 * 1024);
      expect(result['targetMet'], true);
      expect(result['perspectiveCorrected'], false);
      expect(result['deskewDegrees'], 0);
      expect((result['width'] as int) / (result['height'] as int), 2);
      expect(bytes, copy);
      expect(result['highQuality'], isNotEmpty);
    },
  );
  test('complex portrait keeps quality floor when 30 KB cannot be met', () {
    final source = img.Image(width: 900, height: 1200);
    for (final p in source) {
      p.r = (p.x * 71 + p.y * 31) % 256;
      p.g = (p.x * 19 + p.y * 43) % 256;
      p.b = (p.x * 11 + p.y * 97) % 256;
    }
    final result = DocumentProcessingEngine.process({
      'bytes': Uint8List.fromList(img.encodePng(source)),
      'kind': 'portrait',
    });
    expect(result['quality'], greaterThanOrEqualTo(78));
    expect(result['height'], greaterThanOrEqualTo(640));
    expect(
      (result['width'] as int) / (result['height'] as int),
      closeTo(.75, .01),
    );
    expect(result['actualBytes'], greaterThan(30 * 1024));
    expect(result['targetMet'], false);
  });
  test('document target is best effort with retained original processing generation', () {
    final source = img.Image(width: 400, height: 600);
    img.fill(source, color: img.ColorRgb8(255, 255, 255));
    final result = DocumentProcessingEngine.process({
      'bytes': Uint8List.fromList(img.encodePng(source)),
    });
    expect(result['targetBytes'], 50 * 1024);
    expect(result['highQuality'], isNotEmpty);
    expect(result['quality'], greaterThanOrEqualTo(78));
  });
}

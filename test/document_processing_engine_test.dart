import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../lib/document_processing_engine.dart';

void main() {
  test('quality floor wins over an impossible byte target; original bytes remain unchanged', () {
    final image = img.Image(width: 600, height: 800);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (var y = 80; y < 700; y += 24)
      img.drawLine(
        image,
        x1: 40,
        y1: y,
        x2: 540,
        y2: y,
        color: img.ColorRgb8(20, 20, 20),
        thickness: 2,
      );
    final bytes = Uint8List.fromList(img.encodePng(image)),
        original = List<int>.from(img.encodePng(image));
    final result = DocumentProcessingEngine.process({
      'bytes': bytes,
      'targetBytes': 1,
    });
    expect(bytes, original);
    expect(result['targetMet'], false);
    expect(result['actualBytes'], (result['optimized'] as Uint8List).length);
    final decoded = img.decodeJpg(result['optimized'] as Uint8List)!;
    expect(decoded.width, 600);
    expect(decoded.height, 800);
    expect(result['perspectiveCorrected'], false);
    expect(decoded.getPixel(200, 200).r, greaterThan(230));
  });
  test(
    'confident paper boundary is cropped; ambiguous scans retain full content',
    () {
      final image = img.Image(width: 600, height: 800);
      img.fill(image, color: img.ColorRgb8(50, 50, 50));
      img.fillRect(
        image,
        x1: 40,
        y1: 60,
        x2: 560,
        y2: 740,
        color: img.ColorRgb8(255, 255, 255),
      );
      img.drawLine(
        image,
        x1: 100,
        y1: 200,
        x2: 500,
        y2: 200,
        color: img.ColorRgb8(0, 0, 0),
        thickness: 3,
      );
      final result = DocumentProcessingEngine.process({
        'bytes': Uint8List.fromList(img.encodePng(image)),
      });
      expect(result['perspectiveCorrected'], true);
      expect(result['width'], lessThan(600));
      expect(result['height'], lessThan(800));
    },
  );
  test(
    'invalid input is rejected rather than creating a pretend processed scan',
    () {
      expect(
        () => DocumentProcessingEngine.process({
          'bytes': Uint8List.fromList([1, 2, 3]),
        }),
        throwsFormatException,
      );
    },
  );
}

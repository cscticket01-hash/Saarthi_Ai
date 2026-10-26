import 'dart:typed_data';
import 'dart:math' as math;

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
      expect(result['targetBytes'], 40 * 1024);
      expect(result['targetMet'], true);
      expect(result['perspectiveCorrected'], false);
      expect(result['deskewDegrees'], 0);
      expect((result['width'] as int) / (result['height'] as int), 2);
      expect(bytes, copy);
      expect(result['highQuality'], isNotEmpty);
    },
  );
  test('complex ID portrait meets 40 KB with bounded adaptive resize', () {
    final source = img.Image(width: 900, height: 1200);
    final random=math.Random(40);
    for (final p in source) {
      p.r = random.nextInt(256);
      p.g = random.nextInt(256);
      p.b = random.nextInt(256);
    }
    final bytes = Uint8List.fromList(img.encodePng(source));
    final before = Uint8List.fromList(bytes);
    final result = DocumentProcessingEngine.process({
      'bytes': bytes,
      'kind': 'portrait',
    });
    expect(bytes, before);
    expect(result['originalBytes'],greaterThan(40*1024));
    expect(result['sourceRetained'],false);
    expect(result['height'],lessThan(source.height));
    expect(result['attemptedJpegQuality'], greaterThanOrEqualTo(78));
    if (result['sourceRetained'] == true) {
      expect(result['quality'], isNull);
      expect(result['actualBytes'], lessThanOrEqualTo(bytes.length));
      final retained = img.decodeImage(result['optimized'] as Uint8List)!;
      expect(retained.width, source.width);
      expect(retained.height, source.height);
      // Lossless PNG fallback retains actual source pixels, not a smaller
      // thumbnail substituted to pass the byte target.
      expect(retained.getPixel(123, 321).r, source.getPixel(123, 321).r);
      expect(retained.getPixel(123, 321).g, source.getPixel(123, 321).g);
      expect(retained.getPixel(123, 321).b, source.getPixel(123, 321).b);
    } else {
      expect(result['quality'], greaterThanOrEqualTo(78));
    }
    expect(result['height'], greaterThanOrEqualTo(256));
    expect(
      (result['width'] as int) / (result['height'] as int),
      closeTo(.75, .01),
    );
    expect(result['actualBytes'], lessThanOrEqualTo(40 * 1024));
    expect((result['optimized'] as Uint8List).length,result['actualBytes']);
    expect(img.decodeImage(result['optimized'] as Uint8List),isNotNull);
    expect(result['targetMet'], true);
  });
  test('small ID photos remain below the target without padding or upscaling', () {
    final source=img.Image(width:120,height:160);
    img.fill(source,color:img.ColorRgb8(180,160,140));
    final bytes=Uint8List.fromList(img.encodeJpg(source,quality:82));
    final copy=Uint8List.fromList(bytes);
    final result=DocumentProcessingEngine.process({'bytes':bytes,'kind':'portrait'});
    expect(result['targetBytes'],40*1024);
    expect(result['actualBytes'],lessThanOrEqualTo(bytes.length));
    expect(result['targetMet'],true);
    expect(result['width'],120);expect(result['height'],160);
    expect(bytes,copy);
  });
  test('an impossible portrait budget reports unmet instead of destroying quality', () {
    final source=img.Image(width:400,height:600);
    img.fill(source,color:img.ColorRgb8(160,130,110));
    final bytes=Uint8List.fromList(img.encodePng(source));
    final result=DocumentProcessingEngine.process({'bytes':bytes,'kind':'portrait','targetBytes':32});
    expect(result['targetMet'],false);
    expect(result['actualBytes'],greaterThan(32));
    expect(result['attemptedJpegQuality'],greaterThanOrEqualTo(78));
    expect(img.decodeImage(result['optimized'] as Uint8List),isNotNull);
    expect(result['highQuality'],isNotEmpty);
  });
  test('document target is best effort with retained original processing generation', () {
    final source = img.Image(width: 400, height: 600);
    img.fill(source, color: img.ColorRgb8(255, 255, 255));
    final result = DocumentProcessingEngine.process({
      'bytes': Uint8List.fromList(img.encodePng(source)),
    });
    expect(result['targetBytes'], 80 * 1024);
    expect(result['highQuality'], isNotEmpty);
    expect(result['attemptedJpegQuality'], greaterThanOrEqualTo(78));
    if (result['sourceRetained'] != true) {
      expect(result['quality'], greaterThanOrEqualTo(78));
    }
  });
}

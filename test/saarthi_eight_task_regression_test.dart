import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import '../lib/document_processing_engine.dart';
import '../lib/windows_person_fields.dart';

void main() {
  test('manual date adds separators and postal PIN is exactly six digits', () {
    final formatter = SaarthiDateInputFormatter();
    TextEditingValue input(String s) => TextEditingValue(text: s, selection: TextSelection.collapsed(offset: s.length));
    expect(formatter.formatEditUpdate(input('0'), input('02')).text, '02/');
    expect(formatter.formatEditUpdate(input('02/1'), input('02/12')).text, '02/12/');
    expect(formatter.formatEditUpdate(input(''), input('02122026')).text, '02/12/2026');
    expect(parsePersonBirthDate('31/02/2026'), isNull);
    expect(parsePersonBirthDate('29/02/2024'), isNotNull);
    expect(isValidPostalPin('788001'), isTrue);
    expect(isValidPostalPin('78800'), isFalse);
    expect(isValidPostalPin('78800a'), isFalse);
    expect(isValidPostalPin('7880010'), isFalse);
  });
  test('noisy cropped image obeys the actual 80 KB encoded ceiling', () {
    final raster = img.Image(width: 1000, height: 800);
    final random = Random(42);
    for (var y = 0; y < raster.height; y++) {
      for (var x = 0; x < raster.width; x++) {
        raster.setPixelRgb(x, y, random.nextInt(256), random.nextInt(256), random.nextInt(256));
      }
    }
    final source = Uint8List.fromList(img.encodePng(raster));
    final original = Uint8List.fromList(source);
    final r = DocumentProcessingEngine.process({'bytes': source, 'strictPhotoLimit': true, 'manualEdit': [0.1, 0.1, 0.8, 0.7, 0]});
    expect(r['manualCrop'], true);
    expect(r['sourceRetained'], false);
    expect((r['optimized'] as Uint8List).length, lessThanOrEqualTo(80 * 1024));
    expect(r['targetMet'], true);
    expect(source, original);
  });
}

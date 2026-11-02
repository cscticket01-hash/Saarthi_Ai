import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../lib/document_processing_engine.dart';
import '../lib/school_media_budgets.dart';

void main() {
  test('ID, report card, fee and expenses have exact binary KB budgets', () {
    expect(SchoolMediaBudgets.idCard, 85 * 1024);
    expect(SchoolMediaBudgets.reportCard, 150 * 1024);
    expect(SchoolMediaBudgets.receipt, 30 * 1024);
    expect(SchoolMediaBudgets.branding, 30 * 1024);
    for (final kind in ['studentId', 'teacherId', 'otherStaffId', 'idCard',
      'reportCard', 'marksheet', 'receipt', 'feeReceipt', 'expenseReceipt', 'expenses']) {
      final size = SchoolMediaBudgets.pdfLimit(kind)!;
      final exact = Uint8List(size);
      expect(identical(SchoolMediaBudgets.enforcePdf(kind, exact), exact), true);
      expect(() => SchoolMediaBudgets.enforcePdf(kind, Uint8List(size + 1)),
        throwsA(isA<FormatException>()));
    }
    // Bulk-print sheets are not a single ID; source PDFs are never truncated.
    expect(SchoolMediaBudgets.pdfLimit('bulkIdCards'), null);
  });

  test('logo and opaque school seal use actual compressed <=30 KB bytes', () {
    final image = img.Image(width: 900, height: 720);
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        image.setPixelRgb(x, y, (x * 7 + y) % 256,
          (y * 5 + x) % 256, (x + y * 9) % 256);
      }
    }
    final original = Uint8List.fromList(img.encodePng(image));
    final sourceCopy = Uint8List.fromList(original);
    final result = DocumentProcessingEngine.brandingUpload({'bytes': original});
    final encoded = result['optimized'] as Uint8List;
    expect(encoded.length, lessThanOrEqualTo(30 * 1024));
    expect(result['targetBytes'], 30 * 1024);
    expect(result['targetMet'], true);
    expect(img.decodeImage(encoded), isNotNull);
    expect(original, sourceCopy, reason: 'never rewrite school original');
  });

  test('signature transparency and stamp edges survive 30 KB compression', () {
    final image = img.Image(width: 700, height: 500, numChannels: 4);
    img.fill(image, color: img.ColorRgba8(0, 0, 0, 0));
    for (var y = 165; y < 345; y++) {
      for (var x = 140; x < 575; x++) {
        if ((x - y).abs() < 11 || (x + y) % 115 < 8) {
          image.setPixelRgba(x, y, 24, 45, 150, 245);
        }
      }
    }
    final result = DocumentProcessingEngine.brandingUpload({
      'bytes': Uint8List.fromList(img.encodePng(image)),
    });
    final output = result['optimized'] as Uint8List;
    expect(output.length, lessThanOrEqualTo(30 * 1024));
    expect(result['mimeType'], 'image/png');
    expect(result['transparencyPreserved'], true);
    final decoded = img.decodePng(output)!;
    expect(decoded.getPixel(0, 0).a.toInt(), 0);
    expect(decoded.getPixel(decoded.width ~/ 2, decoded.height ~/ 2).a.toInt(),
      greaterThan(0));
  });

  test('unsafe 30 KB high-entropy transparent image fails rather than destroying ink', () {
    final pixels = img.Image(width: 320, height: 320, numChannels: 4);
    final random = math.Random(17);
    for (final p in pixels) {
      p.r = random.nextInt(255);
      p.g = random.nextInt(255);
      p.b = random.nextInt(255);
      p.a = random.nextInt(255);
    }
    final original = Uint8List.fromList(img.encodePng(pixels));
    expect(() => DocumentProcessingEngine.brandingUpload({'bytes': original}),
      throwsA(isA<FormatException>()));
  });
}

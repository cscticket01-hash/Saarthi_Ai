import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../lib/document_processing_engine.dart';
import '../lib/school_media_budgets.dart';
import '../lib/id_card_layout.dart';

void main() {
  test('PDF preflight rejects truncated render output before publishing', () {
    final correct = Uint8List.fromList(utf8.encode(
      '%PDF-1.7\n1 0 obj <</Type /Catalog>> endobj\n%%EOF\n'));
    expect(identical(SchoolMediaBudgets.verifyGeneratedPdf('receipt', correct),
      correct), isTrue);
    final truncated = Uint8List.fromList(
      utf8.encode('%PDF-1.7\n1 0 obj <</Type /Catalog>> endobj'));
    expect(() => SchoolMediaBudgets.verifyGeneratedPdf('receipt', truncated),
      throwsFormatException);
    expect(() => SchoolMediaBudgets.verifyGeneratedPdf(
      'idCard', Uint8List.fromList(utf8.encode('not a PDF %%EOF'))),
      throwsFormatException);
    final oversized = Uint8List(30 * 1024 + 1);
    oversized.setRange(0, 5, utf8.encode('%PDF-'));
    oversized.setRange(oversized.length - 5, oversized.length,
      utf8.encode('%%EOF'));
    expect(() => SchoolMediaBudgets.verifyGeneratedPdf('receipt', oversized),
      throwsFormatException);
  });

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

  test('ID PDF portrait photo is print-resolution JPEG, with transparent ink as PNG', () {
    final portrait = img.Image(width: 1200, height: 1500);
    for (var y = 0; y < portrait.height; y++) {
      for (var x = 0; x < portrait.width; x++) {
        portrait.setPixelRgb(x, y, (x + y * 3) % 256,
          (x * 5 + y) % 256, (x + y * 7) % 256);
      }
    }
    final face = IdCardLayout.preparePdfImage(
      Uint8List.fromList(img.encodeJpg(portrait, quality: 94)),
      aspect: .8, cover: true,
    );
    expect(face.sublist(0, 2), [0xff, 0xd8]);
    expect(img.decodeJpg(face), isNotNull);
    expect(img.decodeJpg(face)!.height, lessThanOrEqualTo(480));

    final stamp = img.Image(width: 200, height: 200, numChannels: 4);
    img.fill(stamp, color: img.ColorRgba8(0, 0, 0, 0));
    for (var p = 20; p < 180; p++) {
      stamp.setPixelRgba(p, p, 10, 20, 100, 255);
    }
    final ink = IdCardLayout.preparePdfImage(
      Uint8List.fromList(img.encodePng(stamp)), aspect: 1,
    );
    expect(ink.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
    expect(img.decodePng(ink)!.getPixel(0, 0).a.toInt(), 0);
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

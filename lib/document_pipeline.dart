import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'document_processing_engine.dart';

class DocumentPipeline {
  static Future<Map<String, dynamic>> process(
    Uint8List bytes,
    String mime,
  ) async {
    if (mime != 'application/pdf') {
      final result = await compute(DocumentProcessingEngine.process, {
        'bytes': bytes,
      });
      return {...result, 'mimeType': 'image/jpeg'};
    }
    if (bytes.length > DocumentProcessingEngine.sourceLimit)
      throw const FormatException('PDF exceeds source safety limit.');
    final pages = <Map<String, dynamic>>[];
    var pixels = 0;
    await for (final page in Printing.raster(bytes, dpi: 150)) {
      pixels += page.width * page.height;
      if (pages.length >= 20 || pixels > 40000000)
        throw const FormatException(
          'PDF exceeds 20 pages / 40 megapixel processing safety limit.',
        );
      pages.add({
        'bytes': await page.toPng(),
        'width': page.width,
        'height': page.height,
      });
    }
    if (pages.isEmpty)
      throw const FormatException('PDF has no readable pages.');
    final optimized = pw.Document(), high = pw.Document();
    for (final page in pages) {
      final result = await compute(DocumentProcessingEngine.process, {
        'bytes': page['bytes'],
        'targetBytes': DocumentProcessingEngine.setTarget ~/ 8 ~/ pages.length,
      });
      final format = PdfPageFormat(
        (page['width'] as int) * 72 / 150,
        (page['height'] as int) * 72 / 150,
      );
      void add(pw.Document doc, Uint8List image) => doc.addPage(
        pw.Page(
          pageFormat: format,
          margin: pw.EdgeInsets.zero,
          build: (_) => pw.Image(pw.MemoryImage(image), fit: pw.BoxFit.contain),
        ),
      );
      add(optimized, result['optimized'] as Uint8List);
      add(high, result['highQuality'] as Uint8List);
    }
    final output = await optimized.save();
    return {
      'optimized': output,
      'highQuality': await high.save(),
      'mimeType': 'application/pdf',
      'actualBytes': output.length,
      'targetMet': output.length <= DocumentProcessingEngine.setTarget ~/ 8,
      'cleanupStatus': '${pages.length} pages processed; original PDF retained',
    };
  }
}

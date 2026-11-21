import 'dart:convert';

import 'document_image_worker.dart';

import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'document_processing_engine.dart';

class DocumentPipeline {
  static const int maxScanPages = 8;
  static const int scanPageImageBudget = 500 * 1024;
  static String? _key;
  static Future<Map<String, dynamic>>? _prepared;
  static Map<String, dynamic> _copy(Map<String, dynamic> result) => {
    for (final e in result.entries)
      e.key: e.value is Uint8List
          ? Uint8List.fromList(e.value as Uint8List)
          : e.value,
  };
  static Future<Map<String, dynamic>> _image(
    Map<String, dynamic> input,
    String scope,
  ) => kIsWeb
      ? compute(DocumentProcessingEngine.process, input)
      : DocumentImageWorker.instance.process(input, scope: scope);
  static Future<Map<String, dynamic>> process(
    Uint8List bytes,
    String mime, {
    String scope = '',
  }) {
    final key = jsonEncode([scope, mime, sha256.convert(bytes).toString()]);
    if (_key == key && _prepared != null) return _prepared!.then(_copy);
    _key = key;
    late final Future<Map<String, dynamic>> future;
    future = _process(Uint8List.fromList(bytes), mime, scope).catchError((
      Object error,
      StackTrace stack,
    ) {
      if (_key == key && identical(_prepared, future)) {
        _key = null;
        _prepared = null;
      }
      Error.throwWithStackTrace(error, stack);
    });
    _prepared = future;
    return future.then(_copy);
  }

  static Future<Map<String, dynamic>> _process(
    Uint8List bytes,
    String mime,
    String scope,
  ) async {
    if (mime != 'application/pdf') {
      final result = await _image({'bytes': bytes}, scope);
      return result;
    }
    if (bytes.length > DocumentProcessingEngine.sourceLimit)
      throw const FormatException('PDF exceeds source safety limit.');
    if (bytes.length < 12 ||
        String.fromCharCodes(bytes.take(5)) != '%PDF-' ||
        !String.fromCharCodes(
          bytes.skip(bytes.length > 2048 ? bytes.length - 2048 : 0),
        ).contains('%%EOF')) {
      throw const FormatException('PDF is malformed or truncated.');
    }
    final pages = <Map<String, dynamic>>[];
    var pixels = 0;
    await for (final page in Printing.raster(bytes, dpi: 150)) {
      pixels += page.width * page.height;
      if (pages.length >= maxScanPages || pixels > 40000000)
        throw const FormatException(
          'PDF exceeds 8 pages / 40 megapixel processing safety limit.',
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
    final perPageBudget = (scanPageImageBudget ~/ pages.length)
        .clamp(1, DocumentProcessingEngine.photoTarget);
    var encodedImageBytes = 0;
    for (final page in pages) {
      final result = await _image({
        'bytes': page['bytes'],
        'targetBytes': perPageBudget,
      }, scope);
      encodedImageBytes += (result['optimized'] as Uint8List).length;
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
    // Do not sacrifice readable fine print just to claim a byte target.
    if (encodedImageBytes > scanPageImageBudget) {
      throw FormatException('Scan page images total $encodedImageBytes bytes, over the 500 KB safe limit. Original retained.');
    }
    final processedOutput = await optimized.save();
    // Preserve the usable original PDF when rasterization expands its vector
    // content. This avoids uploading a larger, lower fidelity substitute.
    final sourceRetained = processedOutput.length > bytes.length;
    final output = sourceRetained ? Uint8List.fromList(bytes) : processedOutput;
    return {
      'optimized': output,
      'sourceRetained': sourceRetained,
      'highQuality': await high.save(),
      'mimeType': 'application/pdf',
      'actualBytes': output.length,
      'originalBytes': bytes.length,
      'targetBytes': scanPageImageBudget,
      'optimizedPageImageBytes': encodedImageBytes,
      'savingsPercent': 100 * (1 - output.length / bytes.length),
      'pageCount': pages.length,
      'targetMet': encodedImageBytes <= scanPageImageBudget,
      'cleanupStatus': sourceRetained
          ? 'Original PDF retained: processed encoding would enlarge upload'
          : '${pages.length} pages processed; original PDF retained',
    };
  }
}

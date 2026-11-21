import 'dart:convert';

import 'document_image_worker.dart';

import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'document_processing_engine.dart';
import 'school_image_input.dart';

class DocumentPipeline {
  static const int maxScanPages = 8;
  static const int scanPageImageBudget = 500 * 1024;
  static int pageImageTargetFor(int pageCount) {
    if (pageCount < 1 || pageCount > maxScanPages) {
      throw RangeError.range(pageCount, 1, maxScanPages, 'pageCount');
    }
    // PDF scans share the full document budget, not the single-photo target.
    // Reserve a small amount for PDF object/page wrapper bytes.
    return ((scanPageImageBudget - 4096) ~/ pageCount).clamp(1, scanPageImageBudget).toInt();
  }
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
  /// The existing file-picker can select JPG/PNG and PDF files together.
  /// Combine them into a source PDF for the existing preview, local original
  /// retention, processing and Cloudflare-first save path. No new UI is needed.
  static Future<Uint8List> combineSources(
    List<Map<String, dynamic>> sources, {
    String scope = '',
  }) async {
    if (sources.isEmpty || sources.length > maxScanPages) {
      throw const FormatException('Smart Scan allows 1 to 8 pages total.');
    }
    final pdf = pw.Document();
    var count = 0, totalBytes = 0, pixels = 0;

    void addPage(Uint8List encoded, int width, int height) {
      if (count >= maxScanPages) {
        throw const FormatException(
          'Smart Scan allows maximum 8 pages across PDFs and images.',
        );
      }
      pixels += width * height;
      if (width <= 0 || height <= 0 || pixels > 40000000) {
        throw const FormatException('Scan exceeds safe pixel limit.');
      }
      pdf.addPage(pw.Page(
        pageFormat: PdfPageFormat(width * 72 / 150, height * 72 / 150),
        margin: pw.EdgeInsets.zero,
        build: (_) =>
            pw.Image(pw.MemoryImage(encoded), fit: pw.BoxFit.contain),
      ));
      count++;
    }

    for (final entry in sources) {
      final bytes = entry['bytes'];
      final mime = entry['mime'];
      if (bytes is! Uint8List || bytes.isEmpty) {
        throw const FormatException('Selected file is empty.');
      }
      totalBytes += bytes.length;
      if (totalBytes > DocumentProcessingEngine.sourceLimit) {
        throw const FormatException('Combined source exceeds 50 MB.');
      }
      if (mime == 'application/pdf') {
        _validatePdf(bytes);
        var inPdf = 0;
        await for (final page in Printing.raster(bytes, dpi: 150)) {
          if (count >= maxScanPages) {
            throw const FormatException(
              'Smart Scan allows maximum 8 pages across PDFs and images.',
            );
          }
          addPage(await page.toPng(), page.width, page.height);
          inPdf++;
        }
        if (inPdf == 0) {
          throw const FormatException('PDF has no readable pages.');
        }
      } else if (mime == 'image/png' || mime == 'image/jpeg') {
        SchoolImageInput.validate(bytes);
        // Reuse the existing image processor for orientation and text quality.
        final result = await _image({'bytes': bytes}, scope);
        addPage(result['highQuality'] as Uint8List,
            result['width'] as int, result['height'] as int);
      } else {
        throw const FormatException('Select JPG, JPEG, PNG or PDF.');
      }
    }

    if (count == 0) throw const FormatException('Scan has no pages.');
    final output = await pdf.save();
    if (output.length > DocumentProcessingEngine.sourceLimit) {
      throw const FormatException('Combined PDF exceeds 50 MB.');
    }
    return output;
  }

  static void _validatePdf(Uint8List bytes) {
    if (bytes.length > DocumentProcessingEngine.sourceLimit) {
      throw const FormatException('PDF exceeds source safety limit.');
    }
    if (bytes.length < 12 ||
        String.fromCharCodes(bytes.take(5)) != '%PDF-' ||
        !String.fromCharCodes(
          bytes.skip(bytes.length > 2048 ? bytes.length - 2048 : 0),
        ).contains('%%EOF')) {
      throw const FormatException('PDF is malformed or truncated.');
    }
  }

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
      if (!{'image/jpeg', 'image/png'}.contains(mime)) {
        throw const FormatException('Select JPG, JPEG, PNG or PDF.');
      }
      final result = await _image({'bytes': bytes}, scope);
      if ((result['optimized'] as Uint8List).length > scanPageImageBudget) {
        throw const FormatException(
          'The readable scan exceeds 500 KB. Original unchanged.',
        );
      }
      return {...result, 'pageCount': 1};
    }
    _validatePdf(bytes);
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
    final optimized = pw.Document();
    // Keep the original PDF as the full-quality copy. A second PDF containing
    // large 94-quality JPEG rasters doubles encoding/memory without improving
    // fidelity over the original source.
    var encodedImageBytes = 0;
    var cleanedPages = 0;
    // Spend the remaining budget across unprocessed pages. A simple text
    // page leaves room for the harder pages instead of wasting its share.
    for (var index = 0; index < pages.length; index++) {
      final page = pages[index];
      final remaining = scanPageImageBudget - 4096 - encodedImageBytes;
      final target = (remaining ~/ (pages.length - index))
          .clamp(1, scanPageImageBudget).toInt();
      final result = await _image({
        'bytes': page['bytes'],
        'targetBytes': target,
      }, scope);
      encodedImageBytes += (result['optimized'] as Uint8List).length;
      if (result['sourceRetained'] != true &&
          (result['perspectiveCorrected'] == true ||
              ((result['deskewDegrees'] as num?) ?? 0).abs() >= 0.5)) {
        cleanedPages++;
      }
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
    }
    // Never reject an already-small original PDF just because converting it
    // to scan JPEGs increased its size. The untouched source remains readable.
    // This is explicitly a no-crop fallback, not a successful optimization.
    if (encodedImageBytes > scanPageImageBudget) {
      if (bytes.length <= scanPageImageBudget) {
        return {
          'optimized': Uint8List.fromList(bytes),
          'sourceRetained': true,
          'highQuality': Uint8List.fromList(bytes),
          'mimeType': 'application/pdf',
          'actualBytes': bytes.length,
          'originalBytes': bytes.length,
          'targetBytes': scanPageImageBudget,
          'optimizedPageImageBytes': encodedImageBytes,
          'savingsPercent': 0.0,
          'pageCount': pages.length,
          'targetMet': true,
          'cleanupStatus':
              'Original PDF retained: processing could not meet the 500 KB scan budget without reducing readability; auto-crop not applied',
        };
      }
      throw FormatException(
        'The ${pages.length}-page scan needs $encodedImageBytes bytes after '
        'quality-safe processing, above the 500 KB scan budget. '
        'Your original is unchanged. Try a clearer scan or fewer pages.',
      );
    }
    final processedOutput = await optimized.save();
    // Preserve the usable original PDF when rasterization expands its vector
    // content. This avoids uploading a larger, lower fidelity substitute.
    final sourceRetained = bytes.length <= scanPageImageBudget &&
        (processedOutput.length > scanPageImageBudget ||
            (cleanedPages == 0 && processedOutput.length > bytes.length));
    final output = sourceRetained ? Uint8List.fromList(bytes) : processedOutput;
    if (output.length > scanPageImageBudget) {
      throw FormatException(
        'The readable PDF is ${output.length} bytes including its page wrapper; '
        'the limit is 500 KB. Original unchanged.',
      );
    }
    return {
      'optimized': output,
      'sourceRetained': sourceRetained,
      'highQuality': Uint8List.fromList(bytes),
      'mimeType': 'application/pdf',
      'actualBytes': output.length,
      'originalBytes': bytes.length,
      'targetBytes': scanPageImageBudget,
      'optimizedPageImageBytes': encodedImageBytes,
      'savingsPercent': 100 * (1 - output.length / bytes.length),
      'pageCount': pages.length,
      'targetMet': output.length <= scanPageImageBudget,
      'cleanupStatus': sourceRetained
          ? 'Original PDF retained: optimized encoding would enlarge upload or exceed 500 KB; crop not applied'
          : '${pages.length} pages processed; $cleanedPages pages corrected; original PDF retained',
    };
  }
}

import 'dart:convert';

import 'document_image_worker.dart';

import 'package:crypto/crypto.dart';

import 'package:flutter/foundation.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'document_processing_engine.dart';
import 'school_image_input.dart';
import 'document_scan_osd_stub.dart'
    if (dart.library.io) 'windows_template_forge_ocr.dart';
import 'package:image/image.dart' as img;

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
  static String? _pdfSourceKey;
  static Future<List<Map<String,dynamic>>>? _pdfSource;
  static void clearPdfSource(String scope) {
    if (_pdfSourceKey != null && (jsonDecode(_pdfSourceKey!) as List).first == scope) {
      _pdfSourceKey = null; _pdfSource = null;
    }
  }
  static Future<List<Map<String,dynamic>>> _sourcePages(Uint8List bytes, String scope) {
    _validatePdf(bytes);
    final key = _sourceKey(scope, bytes);
    if (_pdfSourceKey == key && _pdfSource != null) return _pdfSource!;
    _pdfSourceKey = key;
    late final Future<List<Map<String,dynamic>>> pending;
    pending = (() async {
    final pages = <Map<String, dynamic>>[];
    final combined = _combinedKey == _sourceKey(scope, bytes) ? _combinedPages : null;
    clearCombinedPreparation(scope);
    if (combined != null) {
      pages.addAll(combined);
    } else {
      var pixels = 0;
      await for (final page in Printing.raster(bytes, dpi: 150)) {
        pixels += page.width * page.height;
        if (pages.length >= maxScanPages || pixels > 40000000) {
          throw const FormatException(
            'PDF exceeds 8 pages / 40 megapixel processing safety limit.',
          );
        }
        pages.add({
          'bytes': await page.toPng(),
          'width': page.width,
          'height': page.height,
        });
      }
    }
    if (pages.isEmpty)
      throw const FormatException('PDF has no readable pages.');

      return pages;
    })().catchError((Object error, StackTrace stack) {
      if (identical(_pdfSource,pending)) { _pdfSourceKey=null; _pdfSource=null; }
      Error.throwWithStackTrace(error,stack);
    });
    _pdfSource = pending;
    return pending;
  }
  /// Render display-only page previews. These bytes are never used for saving.
  /// Low DPI keeps normal, already-small PDFs out of the compression pipeline.
  static Future<List<Uint8List>> _previewPdfPages(Uint8List bytes) async {
    _validatePdf(bytes);
    final previews=<Uint8List>[];
    var pixels=0;
    await for(final page in Printing.raster(bytes,dpi:60).take(maxScanPages+1)){
      pixels+=page.width*page.height;
      if(previews.length>=maxScanPages||pixels>40000000){
        throw const FormatException('PDF exceeds 8 pages / 40 megapixel preview limit.');
      }
      previews.add(await page.toPng());
    }
    if(previews.isEmpty)throw const FormatException('PDF has no readable pages.');
    return previews;
  }

  static Future<Uint8List> editThumbnail(Uint8List thumbnail, Map<String,dynamic> edits,
      {required String scope}) async {
    final result = await _image({'bytes':thumbnail,
      ...checkedEdits(edits), 'targetBytes':256*1024},scope);
    return result['optimized'] as Uint8List;
  }
  static String? _combinedKey;
  static List<Map<String, dynamic>>? _combinedPages;
  static String _sourceKey(String scope, Uint8List bytes) =>
      jsonEncode([scope, sha256.convert(bytes).toString()]);
  static void clearCombinedPreparation(String scope) {
    if (_combinedKey != null && (jsonDecode(_combinedKey!) as List).first == scope) {
      _combinedKey = null;
      _combinedPages = null;
    }
  }
  static Map<String, dynamic> _copy(Map<String, dynamic> result) => {
    for (final e in result.entries)
      e.key: e.value is Uint8List
          ? Uint8List.fromList(e.value as Uint8List)
          : e.value is List<Uint8List>
              ? (e.value as List<Uint8List>).map(Uint8List.fromList).toList()
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
    final rasterPages = <Map<String, dynamic>>[];
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
      rasterPages.add({'bytes': encoded, 'width': width, 'height': height});
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
        // Assemble an import container without sharpening or compressing
        // each image twice. The main pipeline processes the PDF pages once.
        final result = await compute(_importImage, bytes);
        addPage(result['bytes'] as Uint8List,
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
    // The exact combined source and school own the already-rasterized pages.
    // Do not rasterize the freshly generated PDF a second time on upload.
    if (scope.isNotEmpty) {
      _combinedKey = _sourceKey(scope, output);
      _combinedPages = rasterPages;
    }
    return output;
  }

  static Map<String, dynamic> _importImage(Uint8List bytes) {
    SchoolImageInput.validate(bytes);
    final decoder = img.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null || info.width <= 0 || info.height <= 0 ||
        info.width * info.height > 20000000 || decoder!.numFrames() != 1) {
      throw const FormatException('Unsupported scan image.');
    }
    final decoded = decoder!.decodeFrame(0);
    if (decoded == null) throw const FormatException('Could not decode scan.');
    final image = img.bakeOrientation(decoded);
    image.exif = img.ExifData();
    image.textData = null;
    image.iccProfile = null;
    return {'bytes': Uint8List.fromList(img.encodePng(image, level: 1)),
      'width': image.width, 'height': image.height};
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

  // Only declarative editor settings are accepted by the backend. Never
  // trust a caller-supplied encoded result or path as the saved generation.
  static Map<String, dynamic> checkedEdits(Map<String, dynamic>? input) {
    if (input == null || input.isEmpty) return {};
    if (input.containsKey('pdfPages')) {
      if (input.length != 1 || input['pdfPages'] is! List) {
        throw const FormatException('Invalid PDF page plan.');
      }
      final plan = input['pdfPages'] as List;
      if (plan.isEmpty || plan.length > maxScanPages) {
        throw const FormatException('Keep between 1 and 8 pages.');
      }
      final seen = <int>{};
      final out = <Map<String,dynamic>>[];
      for (final row in plan) {
        if (row is! Map || row.length != 2 || row['index'] is! int ||
            row['edits'] is! Map) throw const FormatException('Invalid PDF page edit.');
        final index = row['index'] as int;
        if (index < 0 || index >= maxScanPages || !seen.add(index)) {
          throw const FormatException('Duplicate or invalid PDF page.');
        }
        final edit = Map<String,dynamic>.from(row['edits'] as Map);
        if (edit.containsKey('pdfPages')) throw const FormatException('Nested PDF plans are not allowed.');
        out.add({'index':index,'edits':checkedEdits(edit)});
      }
      return {'pdfPages':out};
    }
    if (input.keys.any((key) => !{
      'manualEdit','manualCorners','scanFilter','brightness','contrast',
    }.contains(key))) {
      throw const FormatException('Unknown scan edit setting.');
    }
    return Map<String, dynamic>.from(jsonDecode(jsonEncode(input)) as Map);
  }

  /// Editor thumbnails use the same EXIF-normalized coordinates as the worker.
  static Uint8List editorImage(Uint8List bytes) {
    SchoolImageInput.validate(bytes);
    final decoder = img.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null || info.width * info.height > 20000000 ||
        decoder!.numFrames() != 1) {
      throw const FormatException('Invalid scan image.');
    }
    final decoded = decoder!.decodeFrame(0);
    if (decoded == null) throw const FormatException('Could not decode scan.');
    final image = img.bakeOrientation(decoded);
    final raster = image.width > 900 || image.height > 900
        ? img.copyResize(image,
          width: image.width >= image.height ? 900 : null,
          height: image.height > image.width ? 900 : null,
          interpolation: img.Interpolation.average)
        : image;
    return Uint8List.fromList(img.encodePng(raster, level: 1));
  }

  static Future<Map<String, dynamic>> process(
    Uint8List bytes,
    String mime, {
    String scope = '',
    Map<String, dynamic>? edits,
  }) {
    final options = checkedEdits(edits);
    final key = jsonEncode([scope, mime, sha256.convert(bytes).toString(), options]);
    if (_key == key && _prepared != null) return _prepared!.then(_copy);
    _key = key;
    late final Future<Map<String, dynamic>> future;
    final stopwatch = Stopwatch()..start();
    future = _process(Uint8List.fromList(bytes), mime, scope, options).then((result) {
      stopwatch.stop();
      return <String, dynamic>{
        ...result,
        'processingMillis': stopwatch.elapsedMilliseconds,
      };
    }).catchError((
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
    Map<String, dynamic> options,
  ) async {
    if (mime != 'application/pdf') {
      if (options.containsKey('pdfPages') || !{'image/jpeg', 'image/png'}.contains(mime)) {
        throw const FormatException('Select JPG, JPEG, PNG or PDF.');
      }
      final rotation = options.containsKey('manualEdit')
          ? 0 : await TemplateForgeOfflineOcr.scanRotation(bytes);
      final result = await _image({
        'bytes': bytes,
        'autoRotation': rotation,
        ...options,
      }, scope);
      if ((result['optimized'] as Uint8List).length > scanPageImageBudget) {
        throw const FormatException(
          'The readable scan exceeds 500 KB. Original unchanged.',
        );
      }
      return {...result, 'pageCount': 1};
    }
    if (options.isNotEmpty) {
      throw const FormatException('PDF files are uploaded as-is; page editing is not supported.');
    }
    _validatePdf(bytes);
    // Normal PDFs are immutable: count/render for preview only, and retain
    // the exact source bytes. No OCR, image cleanup, crop or recompression.
    if (bytes.length <= scanPageImageBudget) {
      final previews=await _previewPdfPages(bytes);
      return {
        'optimized':Uint8List.fromList(bytes),
        'highQuality':Uint8List.fromList(bytes),
        'sourceRetained':true,
        'mimeType':'application/pdf',
        'actualBytes':bytes.length,
        'originalBytes':bytes.length,
        'targetBytes':scanPageImageBudget,
        'pageCount':previews.length,
        'previewPages':previews,
        'targetMet':true,
        'qualityGuard':'original-pdf-retained',
        'cleanupStatus':'Original PDF retained; compression not required.',
      };
    }
    // Only PDFs above the 500 KB inventory limit enter this compression path.
    // Rasterization is for compression only; no OCR, auto-crop, deskew or edits.
    final originals = await _sourcePages(bytes, scope);
    final optimized = pw.Document();
    var encodedImageBytes=0;
    var needsQualityReview=false;
    final previewPages=<Uint8List>[];
    for(var index=0;index<originals.length;index++){
      final page=originals[index];
      final remaining=scanPageImageBudget-4096-encodedImageBytes;
      final target=(remaining~/(originals.length-index)).clamp(1,scanPageImageBudget).toInt();
      final result=await _image({
        'bytes':page['bytes'] as Uint8List,
        'targetBytes':target,
        'kind':'pdfCompression',
      },scope);
      final outputPage=result['optimized'] as Uint8List;
      encodedImageBytes+=outputPage.length;
      previewPages.add(outputPage);
      if(result['qualityGuard']=='review-required')needsQualityReview=true;
      final format=PdfPageFormat(
        (result['width'] as int)*72/150,
        (result['height'] as int)*72/150,
      );
      optimized.addPage(pw.Page(
        pageFormat:format,margin:pw.EdgeInsets.zero,
        build:(_)=>pw.Image(pw.MemoryImage(outputPage),fit:pw.BoxFit.contain),
      ));
    }
    if(encodedImageBytes>scanPageImageBudget){
      throw FormatException(
        'The ${originals.length}-page PDF cannot be compressed below 500 KB without risking readability. Original unchanged.',
      );
    }
    final output=await optimized.save();
    if(output.length>scanPageImageBudget){
      throw FormatException(
        'Compressed PDF is ${output.length} bytes; the limit is 500 KB. Original unchanged.',
      );
    }
    return {
      'optimized':Uint8List.fromList(output),
      'highQuality':Uint8List.fromList(bytes),
      'sourceRetained':false,
      'mimeType':'application/pdf',
      'actualBytes':output.length,
      'originalBytes':bytes.length,
      'targetBytes':scanPageImageBudget,
      'pageCount':originals.length,
      'previewPages':previewPages,
      'targetMet':true,
      'qualityGuard':needsQualityReview?'review-required':'pixel-check-passed',
      'cleanupStatus':'PDF exceeded 500 KB; compression completed.',
    };
  }
}

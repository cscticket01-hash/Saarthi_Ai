import 'dart:convert';

import 'package:image/image.dart' as img;
import 'package:crypto/crypto.dart';
import 'package:zxing2/qrcode.dart' as zx;
import 'package:printing/printing.dart';

import 'school_qr_link.dart';

import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'school_media_budgets.dart';
import 'school_pdf_media.dart';
import 'id_card_manifest.dart';
import 'id_card_layout.dart';
import 'id_card_indic_text.dart';

/// Template metadata is the only source of placement/fit instructions.
class IdCardEngine {
  static String compactQr(String value) {
    if (value.startsWith('{')) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map && decoded['managed'] == true)
          return SchoolLink.encodeCompact(Map<String, dynamic>.from(decoded));
      } on FormatException {
        rethrow;
      }
    }
    return value;
  }

  static String decodeFinalRaster(Uint8List bytes) {
    final image = img.decodeImage(bytes);
    if (image == null) throw const FormatException('Invalid final ID raster.');

    String? scan(img.Image candidate) {
      final pixels = Int32List(candidate.width * candidate.height);
      for (final p in candidate) {
        pixels[p.y * candidate.width + p.x] =
            (p.r.toInt() << 16) | (p.g.toInt() << 8) | p.b.toInt();
      }
      try {
        return zx.QRCodeReader()
            .decode(
              zx.BinaryBitmap(
                zx.HybridBinarizer(
                  zx.RGBLuminanceSource(
                    candidate.width,
                    candidate.height,
                    pixels,
                  ),
                ),
              ),
            )
            .text;
      } catch (_) {
        return null;
      }
    }

    // A printed ID contains two composed faces. The full-page finder can
    // miss a small, otherwise valid QR even when an independent scanner reads
    // the exact final 300-DPI PDF. Keep the original scan first, then use
    // bounded, overlapping views of the same decoded raster. Never substitute
    // source QR data for actual printed pixels.
    final whole = scan(image);
    if (whole != null) return whole;
    final longEdge = image.width > image.height ? image.width : image.height;
    if (longEdge > 1400) {
      final reduced = img.copyResize(
        image,
        width: (image.width * 1400 / longEdge).round(),
        height: (image.height * 1400 / longEdge).round(),
        interpolation: img.Interpolation.nearest,
      );
      final result = scan(reduced);
      if (result != null) return result;
    }
    for (final columns in [2, 3]) {
      for (var column = 0; column < columns; column++) {
        final marginX = image.width ~/ (columns * 8);
        final x0 = (column * image.width ~/ columns - marginX)
            .clamp(0, image.width - 1).toInt();
        final x1 = ((column + 1) * image.width ~/ columns + marginX)
            .clamp(x0 + 1, image.width).toInt();
        for (var row = 0; row < 2; row++) {
          final marginY = image.height ~/ 16;
          final y0 = (row * image.height ~/ 2 - marginY)
              .clamp(0, image.height - 1).toInt();
          final y1 = ((row + 1) * image.height ~/ 2 + marginY)
              .clamp(y0 + 1, image.height).toInt();
          final tile = img.copyCrop(
            image,
            x: x0,
            y: y0,
            width: x1 - x0,
            height: y1 - y0,
          );
          final result = scan(tile);
          if (result != null) return result;
        }
      }
    }
    throw const FormatException(
      'Final printed ID QR cannot be decoded at 300 DPI.',
    );
  }

  static Future<void> verifyExport(Uint8List pdf, String expected) async {
    var pages = 0;
    await for (final page in Printing.raster(pdf, dpi: 300)) {
      pages++;
      try {
        if (decodeFinalRaster(await page.toPng()) == compactQr(expected))
          return;
      } catch (_) {}
    }
    throw FormatException(
      'Final ID QR failed independent decode on $pages pages. Regenerate the card before printing.',
    );
  }

  static Map<String,dynamic> normalizedInput(IdCardManifest template,Map<String,dynamic> data) {
    if(template.id == 'student-maroon-gold-v1') {
      String first(List<String> keys) {
        for(final key in keys) {
          final value=data[key]?.toString().trim()??'';
          if(value.isNotEmpty)return value;
        }
        return '';
      }
      data={...data,
        'name':first(['name','studentName']),
        'class':[first(['studentClass','class']), if(first(['section']).isNotEmpty) first(['section'])].where((v)=>v.isNotEmpty).join(' / '),
        'rollNo':first(['rollNo','roll']),
        'studentUid':first(['studentUid','studentId']),
        'session':first(['academicSession','session','academicYear']),
        'parentName':first(['parentName','fatherName']),
        'contact':first(['parentContact','contact','phone']),
        'address':first(['streetAddress','address']),
        'pinCode':first(['pinCode','pin','pincode']),
      };
    }
    return data;
  }

  static Future<PreparedIdCard> prepare(
    IdCardManifest template,
    Map<String, dynamic> data, {
    Map<String, Uint8List> images = const {},
    String qr = '',
    Map<String, Uint8List> backgrounds = const {},
    pw.Font? font,
    int printMediaStage = 0,
  }) async {
    data = normalizedInput(template,data);
    qr = compactQr(qr);
    for (final r in template.regions) {
      if (r.isRequired &&
          (r.kind == 'image'
              ? images[r.key] == null
              : r.kind == 'qr'
              ? qr.isEmpty
              : (data[r.key]?.toString().trim().isEmpty ?? true)))
        throw FormatException('Required ID field missing: ${r.key}');
    }
    // Flutter shapes Indic combining marks using HarfBuzz before PDF placement.
    // Only Indic fields become images; other text stays in searchable PDF text.
    final shapedText = <String, Uint8List>{};
    for (final region in template.regions.where((r) => r.kind == 'text')) {
      final value = '${region.label}${data[region.key] ?? ''}';
      final rendered = await IdCardIndicText.rasterize(
        value,
        width: region.width - 2 * region.padding,
        height: region.height - 2 * region.padding,
        fontSize: region.fontSize,
        minFontSize: region.minFontSize,
        maxLines: region.maxLines,
        align: region.align,
        color: 0xFF000000 | int.parse(region.textColor.substring(1),radix:16),
      );
      if (rendered != null) {
        shapedText['${region.side}:${region.key}'] = rendered;
      }
    }
    return PreparedIdCard._(
      template,
      Map.unmodifiable(data),
      Map.unmodifiable(images),
      qr,
      Map.unmodifiable(backgrounds),
      Map.unmodifiable(shapedText),
      font ?? await loadFont(),
      printMediaStage,
    );
  }

  static Future<pw.Font> loadFont() async =>
      pw.Font.ttf(await rootBundle.load('assets/id_card_regular.ttf'));

  static Future<Uint8List> render(IdCardManifest template, Map<String,dynamic> data, {Map<String,Uint8List> images=const {},String qr='',Map<String,Uint8List> backgrounds=const {}}) => _render(template,data,images:images,qr:qr,backgrounds:backgrounds);

  /// A standard non-embedded PDF font is safe only for the glyphs that will
  /// actually be written as vector text. Indic fields are already shaped into
  /// lossless PNGs; other input metadata must not block a compact font retry.
  /// Never replace a font when any remaining vector glyph needs Unicode.
  static bool canUseCompactPdfFont(PreparedIdCard prepared) {
    for (final region in prepared.template.regions) {
      if (region.kind != 'text') continue;
      if (prepared.shapedText.containsKey('${region.side}:${region.key}')) {
        continue;
      }
      final text = '${region.label}${prepared.data[region.key] ?? ''}';
      final ascii = text.runes.every((code) =>
          code == 9 || code == 10 || code == 13 ||
          (code >= 32 && code <= 126));
      if (!ascii) return false;
    }
    return true;
  }

  static Future<Uint8List> _render(
    IdCardManifest template,
    Map<String, dynamic> data, {
    Map<String, Uint8List> images = const {},
    String qr = '',
    Map<String, Uint8List> backgrounds = const {},
    bool useCompactVectorFont = false,
    bool compactBitmapAssets = false,
  }) async {
    // Embed school-owned source backgrounds at their actual CR80 print size.
    // This is bitmap-only optimization; the original image assets, vector
    // QR, Indic text shaping and layout geometry remain unchanged.
    final optimizedBackgrounds = <String, Uint8List>{
      for (final entry in backgrounds.entries)
        entry.key: SchoolPdfMedia.cardBackground(
          entry.value, widthMm: template.printWidth,
          heightMm: template.printHeight,
          jpegQuality: compactBitmapAssets ? 88 : 92),
    };
    final prepared = await prepare(
      template,
      data,
      images: images,
      qr: qr,
      backgrounds: optimizedBackgrounds,
      font: useCompactVectorFont ? pw.Font.helvetica() : null,
      printMediaStage: compactBitmapAssets ? 1 : 0,
    );
    final pdf = pw.Document(theme: pw.ThemeData.withFont(base: prepared.font));
    final width = template.printWidth * PdfPageFormat.mm;
    final height = template.printHeight * PdfPageFormat.mm;
    final gap = 8 * PdfPageFormat.mm;
    pw.Widget card(String name) => pw.SizedBox(
      width: width,
      height: height,
      child: pw.FittedBox(
        fit: pw.BoxFit.contain,
        child: prepared.buildSide(name),
      ),
    );
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(2 * width + gap, height),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Row(
          children: [
            card('front'),
            pw.SizedBox(width: gap),
            card('back'),
          ],
        ),
      ),
    );
    final output = await pdf.save();
    if (!useCompactVectorFont && output.length > SchoolMediaBudgets.idCard) {
      // Keep the original embedded font when it fits. When the PDF exceeds
      // 85 KiB, try a smaller core font only for actual vector ASCII fields.
      // Bengali/Assamese/Devanagari fields are preserved as shaped PNGs.
      // No QR, layout, source media or unsafe Unicode glyph is modified.
      if (canUseCompactPdfFont(prepared)) {
        return _render(template, data, images: images, qr: qr,
            backgrounds: backgrounds, useCompactVectorFont: true);
      }
    }
    if (!compactBitmapAssets && output.length > SchoolMediaBudgets.idCard) {
      // Second safe pass: 280 DPI and JPEG quality 84 only on small embedded
      // photo/branding bitmaps; all QR and text remain vector and the source
      // bytes are untouched. Unicode retains the original embedded font.
      return _render(template, data, images: images, qr: qr,
          backgrounds: backgrounds,
          useCompactVectorFont: useCompactVectorFont,
          compactBitmapAssets: true);
    }
    return SchoolMediaBudgets.verifyGeneratedPdf('idCard', output);
  }
}

/// Existing single-card artwork reused by isolated bulk imposition.
class PreparedIdCard {
  PreparedIdCard._(
    this.template,
    this.data,
    this.images,
    this.qr,
    this.backgrounds,
    this.shapedText,
    this.font,
    this.printMediaStage,
  );
  final IdCardManifest template;
  final Map<String, dynamic> data;
  final Map<String, Uint8List> images, backgrounds, shapedText;
  // Reuse identical JPEG/PNG objects across both sides of one generated ID.
  // The same school logo appears on front and back; duplicate PDF objects
  // increase byte size but add no print fidelity.
  final Map<String, pw.MemoryImage> _printImageCache = {};

  // QPDF/pdfcpu-style immutable PDF resource reuse, implemented in Dart:
  // identical encoded media on both faces must not consume two PDF objects.
  // Exact SHA-256 identity means no resampling or changes to printed pixels.
  pw.MemoryImage _cachedImage(Uint8List bytes) =>
      _printImageCache.putIfAbsent(
        sha256.convert(bytes).toString(),
        () => pw.MemoryImage(bytes),
      );

  final String qr;
  final pw.Font font;
  final int printMediaStage;
  pw.Widget buildSide(String name) => pw.SizedBox(
    width: template.width,
    height: template.height,
    child: pw.Stack(
      children: [
        pw.Positioned.fill(child: pw.Container(color: PdfColors.white)),
        if (backgrounds[name] != null)
          pw.Positioned.fill(
            child: pw.Image(
              _cachedImage(backgrounds[name]!),
              fit: pw.BoxFit.contain,
            ),
          ),
        for (final r in template.regions.where((r) => r.side == name))
          pw.Positioned(
            left: r.x,
            top: r.y,
            child: pw.SizedBox(
              width: r.width,
              height: r.height,
              child: pw.Padding(
                padding: pw.EdgeInsets.all(r.padding),
                child: pw.ClipRect(
                  child: r.kind == 'image'
                      ? images[r.key] == null
                            ? pw.SizedBox()
                            : IdCardLayout.image(
                                images[r.key]!,
                                cover: r.fit == 'cover',
                                focusX: r.focusX,
                                focusY: r.focusY,
                                imageCache: _printImageCache,
                                printDpi: printMediaStage == 0 ? 300 : 280,
                                jpegQuality: printMediaStage == 0 ? 88 : 84,
                              )
                      : r.kind == 'qr'
                      ? qr.isEmpty
                            ? pw.SizedBox()
                            : IdCardLayout.qr(
                                qr,
                                millimetresPerUnit:
                                    template.printWidth / template.width,
                              )
                      : shapedText['${r.side}:${r.key}'] != null
                      ? pw.Image(
                          _cachedImage(shapedText['${r.side}:${r.key}']!),
                          fit: pw.BoxFit.fill,
                        )
                      : IdCardLayout.text(
                          '${r.label}${data[r.key] ?? ''}',
                          font: font,
                          color: PdfColor.fromHex(r.textColor),
                          fontSize: r.fontSize,
                          minFontSize: r.minFontSize,
                          wrap: r.wrap,
                          maxLines: r.maxLines,
                          overflow: r.overflow,
                          align: r.align == 'center'
                              ? pw.TextAlign.center
                              : r.align == 'right'
                              ? pw.TextAlign.right
                              : pw.TextAlign.left,
                        ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

import 'dart:convert';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart' as zx;
import 'package:printing/printing.dart';

import 'school_qr_link.dart';

import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

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
    final pixels = Int32List(image.width * image.height);
    for (final p in image)
      pixels[p.y * image.width + p.x] =
          (p.r.toInt() << 16) | (p.g.toInt() << 8) | p.b.toInt();
    return zx.QRCodeReader()
        .decode(
          zx.BinaryBitmap(
            zx.HybridBinarizer(
              zx.RGBLuminanceSource(image.width, image.height, pixels),
            ),
          ),
        )
        .text;
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

  static Future<PreparedIdCard> prepare(
    IdCardManifest template,
    Map<String, dynamic> data, {
    Map<String, Uint8List> images = const {},
    String qr = '',
    Map<String, Uint8List> backgrounds = const {},
    pw.Font? font,
  }) async {
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
        'class':first(['studentClass','class']),
        'rollNo':first(['rollNo','roll']),
        'studentUid':first(['studentUid','studentId']),
        'session':first(['academicSession','session','academicYear']),
        'parentName':first(['parentName','fatherName']),
        'contact':first(['parentContact','contact','phone']),
        'address':first(['streetAddress','address']),
        'pinCode':first(['pinCode','pin','pincode']),
      };
    }
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
    );
  }

  static Future<pw.Font> loadFont() async =>
      pw.Font.ttf(await rootBundle.load('assets/id_card_regular.ttf'));

  static Future<Uint8List> render(IdCardManifest template, Map<String,dynamic> data, {Map<String,Uint8List> images=const {},String qr='',Map<String,Uint8List> backgrounds=const {}}) => _render(template,data,images:images,qr:qr,backgrounds:backgrounds);

  static Future<Uint8List> _render(
    IdCardManifest template,
    Map<String, dynamic> data, {
    Map<String, Uint8List> images = const {},
    String qr = '',
    Map<String, Uint8List> backgrounds = const {},
  }) async {
    final prepared = await prepare(
      template,
      data,
      images: images,
      qr: qr,
      backgrounds: backgrounds,
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
    return pdf.save();
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
  );
  final IdCardManifest template;
  final Map<String, dynamic> data;
  final Map<String, Uint8List> images, backgrounds, shapedText;
  final String qr;
  final pw.Font font;
  pw.Widget buildSide(String name) => pw.SizedBox(
    width: template.width,
    height: template.height,
    child: pw.Stack(
      children: [
        pw.Positioned.fill(child: pw.Container(color: PdfColors.white)),
        if (backgrounds[name] != null)
          pw.Positioned.fill(
            child: pw.Image(
              pw.MemoryImage(backgrounds[name]!),
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
                          pw.MemoryImage(shapedText['${r.side}:${r.key}']!),
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

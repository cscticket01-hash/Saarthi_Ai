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

/// Template metadata is the only source of placement/fit instructions.
class IdCardEngine {
  static String compactQr(String value) {
    if(value.startsWith('{')) {
      try {final decoded=jsonDecode(value);if(decoded is Map && decoded['managed']==true)
        return SchoolLink.encodeCompact(Map<String,dynamic>.from(decoded));} on FormatException {rethrow;}
    }
    return value;
  }
  static String decodeFinalRaster(Uint8List bytes) {
    final image=img.decodeImage(bytes);
    if(image==null)throw const FormatException('Invalid final ID raster.');
    final pixels=Int32List(image.width*image.height);
    for(final p in image)pixels[p.y*image.width+p.x]=(p.r.toInt()<<16)|(p.g.toInt()<<8)|p.b.toInt();
    return zx.QRCodeReader().decode(zx.BinaryBitmap(zx.HybridBinarizer(zx.RGBLuminanceSource(image.width,image.height,pixels)))).text;
  }
  static Future<void> verifyExport(Uint8List pdf,String expected) async {
    var pages=0;
    await for(final page in Printing.raster(pdf,dpi:300)) {
      pages++;
      try {if(decodeFinalRaster(await page.toPng())==compactQr(expected))return;} catch (_) {}
    }
    throw FormatException('Final ID QR failed independent decode on $pages pages. Regenerate the card before printing.');
  }

  static Future<Uint8List> render(
    IdCardManifest template,
    Map<String, dynamic> data, {
    Map<String, Uint8List> images = const {},
    String qr = '',
    Map<String, Uint8List> backgrounds = const {},
  }) async {
    qr=compactQr(qr);
    for(final r in template.regions){
      if(r.isRequired && (r.kind=='image'?images[r.key]==null:r.kind=='qr'?qr.isEmpty:(data[r.key]?.toString().trim().isEmpty??true)))throw FormatException('Required ID field missing: ${r.key}');
    }
    final regular = pw.Font.ttf(
      await rootBundle.load('assets/id_card_regular.ttf'),
    );
    final pdf = pw.Document(theme: pw.ThemeData.withFont(base: regular));
    pw.Widget side(String name) => pw.SizedBox(
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
                child: pw.Padding(padding:pw.EdgeInsets.all(r.padding),child: pw.ClipRect(
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
                      : IdCardLayout.text(
                          '${r.label}${data[r.key] ?? ''}',
                          font: regular,
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
                )),
              ),
            ),
        ],
      ),
    );
    final width = template.printWidth * PdfPageFormat.mm;
    final height = template.printHeight * PdfPageFormat.mm;
    final gap = 8 * PdfPageFormat.mm;
    pw.Widget card(String name) => pw.SizedBox(
      width: width,
      height: height,
      child: pw.FittedBox(fit: pw.BoxFit.contain, child: side(name)),
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

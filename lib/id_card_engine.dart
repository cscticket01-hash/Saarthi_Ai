import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'id_card_manifest.dart';
import 'id_card_layout.dart';

/// Template metadata is the only source of placement/fit instructions.
class IdCardEngine {
  static Future<Uint8List> render(
    IdCardManifest template,
    Map<String, dynamic> data, {
    Map<String, Uint8List> images = const {},
    String qr = '',
    Map<String, Uint8List> backgrounds = const {},
  }) async {
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
                ),
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

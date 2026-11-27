import 'school_media_budgets.dart';
import 'school_pdf_media.dart';
import 'windows_maroon_marksheet.dart';
import 'id_card_engine.dart';
import 'id_card_layout.dart';
import 'windows_id_pair.dart';
import 'teacher_reference_layout.dart';

import 'dart:typed_data';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

// Windows-only reference artwork, redrawn as vectors. No reference JPEG,
// sample identity, signature, barcode or watermark is embedded.
const windowsReferenceDocumentNames = <String, List<String>>{
  'teacherId': [
    'Green Angular • Portrait',
    'Gold & Teal • Portrait',
    'Cyan Ribbon • Landscape',
    'Navy & Red • Portrait',
  ],
  'reportCard': [
    'Maroon & Gold • Progress Report',
  ],
  'receipt': ['School Receipt • Reference'],
};
int windowsReferenceDocumentIndex(String kind, dynamic value) {
  final count = windowsReferenceDocumentNames[kind]?.length ?? 1;
  return value is num &&
          value.isFinite &&
          value.toInt() >= 0 &&
          value.toInt() < count
      ? value.toInt()
      : 0;
}

int? windowsReferenceTermNumber(Map<String, dynamic> data) {
  if (data['isFinal'] == true) return null;
  final explicit = int.tryParse(data['quarter']?.toString() ?? '');
  if (explicit != null && explicit >= 1 && explicit <= 4) return explicit;
  final name =
      (data['term'] ?? data['examName'] ?? '').toString().toLowerCase();
  final match = RegExp(r'\b(?:term|quarter|semester|q)\s*[-:]?\s*([1-4])\b')
      .firstMatch(name);
  return match == null ? null : int.parse(match.group(1)!);
}

// Trim blank signature margins for printing only; stored branding is untouched.
Future<Uint8List?> _signatureInk(Uint8List? bytes, {bool white = false}) async {
  if (bytes == null) return null;
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  final image = frame.image;
  try {
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (raw == null) return bytes;
    final pixels = Uint8List.fromList(raw.buffer.asUint8List());
    var left = image.width, top = image.height, right = -1, bottom = -1;
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final n = (y * image.width + x) * 4;
        final darkness = 255 - (pixels[n] + pixels[n + 1] + pixels[n + 2]) ~/ 3;
        if (darkness > 20 && pixels[n + 3] > 20) {
          if (x < left) left = x;
          if (x > right) right = x;
          if (y < top) top = y;
          if (y > bottom) bottom = y;
        }
        if (darkness < 20) pixels[n + 3] = 0;
        if (white) pixels[n] = pixels[n + 1] = pixels[n + 2] = 255;
      }
    }
    if (right < left || bottom < top) return null;
    final width = right - left + 1, height = bottom - top + 1;
    final cropped = Uint8List(width * height * 4);
    for (var y = 0; y < height; y++) {
      final start = ((top + y) * image.width + left) * 4;
      cropped.setRange(y * width * 4, (y + 1) * width * 4, pixels, start);
    }
    final ready = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      cropped,
      width,
      height,
      ui.PixelFormat.rgba8888,
      ready.complete,
    );
    final printed = await ready.future;
    try {
      final png = await printed.toByteData(format: ui.ImageByteFormat.png);
      return png?.buffer.asUint8List() ?? bytes;
    } finally {
      printed.dispose();
    }
  } finally {
    image.dispose();
    codec.dispose();
  }
}

// Public document API cannot accept cached/unauthenticated compressed images.
// Only the private recursive renderer can reuse its own validated media.
Future<Uint8List> renderWindowsReferenceDocument({
  required String kind,
  required int template,
  required Map<String, dynamic> data,
  String qr = '',
  Uint8List? photo,
  Uint8List? logo,
  Uint8List? signature,
  Uint8List? seal,
  int printPass = 0,
  bool plain = false,
  bool printOnly = false,
}) => _renderWindowsReferenceDocument(
  kind: kind, template: template, data: data, qr: qr,
  photo: photo, logo: logo, signature: signature, seal: seal,
  printPass: printPass, plain: plain, printOnly:printOnly,
);

Future<Uint8List> _renderWindowsReferenceDocument({
  required String kind,
  required int template,
  required Map<String, dynamic> data,
  String qr = '',
  Uint8List? photo,
  Uint8List? logo,
  Uint8List? signature,
  Uint8List? seal,
  int printPass = 0,
  bool plain = false,
  bool printOnly = false,
  ({Uint8List? photo, Uint8List? logo, Uint8List? seal, Uint8List? signature})? preparedMedia,
}) async {
  if (printPass < 0 || printPass > 4) {
    throw const FormatException('Invalid ID print optimization stage.');
  }
  if (!windowsReferenceDocumentNames.containsKey(kind))
    throw ArgumentError.value(kind, 'kind');
  final i = windowsReferenceDocumentIndex(kind, template);
  // Compression can be expensive on an older school PC. Offload it to
  // isolates in bounded pairs; preserve exact PDF bytes and the immutable
  // source images. The existing sync/outbox owner is still serial.
  Future<Uint8List?> portraitForPrint(Uint8List? bytes) =>
      bytes == null ? Future<Uint8List?>.value(null)
          : compute(SchoolPdfMedia.portrait, bytes);
  Future<Uint8List?> brandingForPrint(
    Uint8List? bytes, int maxPrintEdge,
  ) => bytes == null ? Future<Uint8List?>.value(null)
      : compute(SchoolPdfMedia.brandingSized,
          {'bytes': bytes, 'maxPrintEdge': maxPrintEdge});
  late final Uint8List? embeddedPhoto, embeddedLogo, embeddedSeal, printSignature;
  if (preparedMedia != null) {
    // A size retry reuses the exact verified source of the previous pass.
    // Re-compressing unchanged media on every print-DPI attempt wastes CPU,
    // memory and time on low-end school PCs.
    embeddedPhoto = preparedMedia.photo;
    embeddedLogo = preparedMedia.logo;
    embeddedSeal = preparedMedia.seal;
    printSignature = preparedMedia.signature;
  } else {
    final visualPair = await Future.wait<Uint8List?>([
      portraitForPrint(photo), brandingForPrint(logo, kind == 'receipt' ? 120 : 256),
    ]);
    final signatureInk = await _signatureInk(signature, white: false);
    final brandingPair = await Future.wait<Uint8List?>([
      brandingForPrint(seal, kind == 'receipt' ? 144 : 256),
      brandingForPrint(signatureInk, kind == 'receipt' ? 192 : 256),
    ]);
    embeddedPhoto = visualPair[0];
    embeddedLogo = visualPair[1];
    embeddedSeal = brandingPair[0];
    printSignature = brandingPair[1];
  }
  String v(String key, [String fallback = '-']) {
    final raw = data[key]?.toString().trim() ?? '';
    return raw.isEmpty || raw == 'null' ? fallback : raw;
  }

  String first(List<String> keys, [String fallback = '-']) {
    for (final key in keys) {
      if (v(key, '').isNotEmpty) return v(key);
    }
    return fallback;
  }

  final school = first(['schoolName', 'nameOfSchool'], 'School name');
  final name = kind == 'teacherId'
      ? first(['name', 'teacherName'], 'Teacher name')
      : first(['studentName', 'name'], 'Student name');
  // Core PDF fonts need no embedded TTF program for ASCII school receipts.
  // This is a lossless PDF-byte optimization: text stays selectable vector
  // text and page measurements stay unchanged. Any non-ASCII record continues
  // using the bundled Unicode-capable school font rather than losing glyphs.
  bool isAscii(dynamic v) {
    if (v == null || v is num || v is bool || v is Uint8List) return true;
    if (v is String) return v.runes.every((r) => r <= 0x7f);
    if (v is Map) return v.entries.every(
      (entry) => isAscii(entry.key) && isAscii(entry.value));
    if (v is Iterable) return v.every(isAscii);
    return false;
  }
  final receiptCoreFonts = kind == 'receipt' && isAscii(data);
  final regular = receiptCoreFonts
      ? pw.Font.helvetica()
      : pw.Font.ttf(await rootBundle.load('assets/id_card_regular.ttf'));
  final bold = receiptCoreFonts
      ? pw.Font.helveticaBold()
      : pw.Font.ttf(await rootBundle.load('assets/id_card_bold.ttf'));
  final pdf = pw.Document(
    theme: pw.ThemeData.withFont(base: regular, bold: bold),
  );
  final imageCache = <String, pw.MemoryImage>{};
  final idRegions = <pw.Widget, List<double>>{};
  final idDecorations = <pw.Widget>{};
  pw.Widget at(double x, double y, double w, double h, pw.Widget child,
      {bool decorative = false}) {
    final widget = pw.Positioned(
      left: x,
      top: y,
      child: pw.SizedBox(width: w, height: h, child: child),
    );
    if (kind == 'teacherId') idRegions[widget] = [x, y, w, h];
    if (decorative) idDecorations.add(widget);
    return widget;
  }

  void validateIdSide(List<pw.Widget> widgets, double width, double height) {
    final regions = widgets
        .where((widget) =>
            idRegions.containsKey(widget) && !idDecorations.contains(widget))
        .map((w) => idRegions[w]!)
        .toList();
    for (var index = 0; index < regions.length; index++) {
      final r = regions[index];
      if ([r[0], r[1], r[2], r[3]].any((v) => !v.isFinite) ||
          r[0] < 0 ||
          r[1] < 0 ||
          r[2] <= 0 ||
          r[3] <= 0 ||
          r[0] + r[2] > width ||
          r[1] + r[3] > height)
        throw const FormatException('Staff ID region outside canvas.');
      for (final o in regions.skip(index + 1)) {
        if (r[0] < o[0] + o[2] &&
            o[0] < r[0] + r[2] &&
            r[1] < o[1] + o[3] &&
            o[1] < r[1] + r[3])
          throw FormatException(
            'Staff ID dynamic regions overlap: $r / $o. Select a validated manifest template.',
          );
      }
    }
  }

  pw.Widget label(
    String s, {
    double size = 11,
    PdfColor color = PdfColors.black,
    bool heavy = false,
    pw.TextAlign align = pw.TextAlign.left,
  }) =>
      s.trim().isEmpty
          ? pw.SizedBox(width: 1, height: 1)
          : kind == 'teacherId'
              ? IdCardLayout.text(
                  s,
                  font: heavy ? bold : regular,
                  fontSize: size,
                  color: color,
                  align: align,
                  wrap: true,
                  maxLines: 3,
                )
              : pw.FittedBox(
                  fit: pw.BoxFit.scaleDown,
                  alignment: align == pw.TextAlign.center
                      ? pw.Alignment.center
                      : pw.Alignment.centerLeft,
                  child: pw.Text(
                    s,
                    textAlign: align,
                    style: pw.TextStyle(
                      fontSize: size,
                      color: color,
                      fontWeight:
                          heavy ? pw.FontWeight.bold : pw.FontWeight.normal,
                    ),
                  ),
                );
  pw.Widget asset(Uint8List? bytes, String placeholder, {bool cover = false}) =>
      bytes == null
          ? (kind == 'teacherId' && !cover
              ? pw.SizedBox()
              : pw.Center(child: label(placeholder, size: 11, color: PdfColors.grey600)))
          : pw.ClipRect(
              child: kind == 'teacherId'
                  ? IdCardLayout.image(bytes, cover: cover, imageCache: imageCache,
                       printDpi: cover
                           ? [300, 280, 260, 240, 220][printPass]
                           : [250, 220, 220, 220, 220][printPass],
                       jpegQuality: cover
                           ? [88, 86, 84, 81, 78][printPass]
                           : [88, 88, 88, 86, 84][printPass])
                  : pw.Image(
                      pw.MemoryImage(bytes),
                      fit: cover ? pw.BoxFit.cover : pw.BoxFit.contain,
                    ),
            );
  pw.Widget qrCode(double size) => qr.isEmpty
      ? pw.SizedBox()
      : IdCardLayout.qr(
          IdCardEngine.compactQr(qr),
          millimetresPerUnit:
              kind == 'teacherId' ? (i == 2 ? 85.6 / 480 : 54 / 306) : null,
        );
  pw.Widget table(
    List<List<String>> rows, {
    List<double>? widths,
    PdfColor header = PdfColors.grey800,
    PdfColor ink = PdfColors.black,
    double font = 10,
    double rowHeight = 22,
    bool firstHeader = true,
  }) =>
      pw.Table(
        columnWidths: widths == null
            ? null
            : {
                for (var c = 0; c < widths.length; c++)
                  c: pw.FlexColumnWidth(widths[c]),
              },
        border: pw.TableBorder.all(color: ink, width: .5),
        children: [
          for (var r = 0; r < rows.length; r++)
            pw.TableRow(
              decoration: pw.BoxDecoration(
                color: r == 0 && firstHeader
                    ? header
                    : r.isEven
                        ? PdfColors.grey100
                        : PdfColors.white,
              ),
              children: [
                for (final cell in rows[r])
                  pw.Container(
                    height: rowHeight,
                    padding: const pw.EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: label(
                      cell,
                      size: font,
                      color: r == 0 && firstHeader ? PdfColors.white : ink,
                      heavy: r == 0 && firstHeader,
                    ),
                  ),
              ],
            ),
        ],
      );
  void page(double w, double h, List<pw.Widget> layers, {bool card = false}) {
    final format = card
        ? PdfPageFormat(
            (w == 480 ? 85.6 : 54) * PdfPageFormat.mm,
            (w == 480 ? 54 : 85.6) * PdfPageFormat.mm,
          )
        : PdfPageFormat(612, 792);
    pdf.addPage(
      pw.Page(
        pageFormat: format,
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.FittedBox(
          fit: pw.BoxFit.contain,
          child: pw.SizedBox(
            width: w,
            height: h,
            child: pw.Stack(children: layers),
          ),
        ),
      ),
    );
  }

  if (kind == 'teacherId') {
    final sides = buildTeacherReferenceLayers<pw.Widget>(
      i:i,data:data,embeddedPhoto:embeddedPhoto,embeddedLogo:embeddedLogo,printSignature:printSignature,
      position:(x,y,w,h,child,decorative)=>at(x,y,w,h,child,decorative:decorative),
      text:(s,size,color,heavy,align)=>label(s,size:size,color:color,heavy:heavy,align:align),
      image:(bytes,placeholder,cover)=>asset(bytes,placeholder,cover:cover),
      artwork:(svg,width,height)=>pw.SvgImage(svg:svg,width:width,height:height),
      circle:(child,color,width)=>pw.Container(
        decoration:pw.BoxDecoration(shape:pw.BoxShape.circle,border:pw.Border.all(color:color,width:width)),
        child:pw.ClipOval(child:child)),
      bordered:(child,color)=>pw.Container(
        decoration:pw.BoxDecoration(border:pw.Border.all(color:color)),child:child),
      badge:(child,color)=>pw.Container(
        decoration:pw.BoxDecoration(color:color,borderRadius:pw.BorderRadius.circular(15)),child:child),
      rotateSchool:(child)=>pw.Transform.rotateBox(angle:-1.5707963267948966,
        unconstrained:true,child:pw.SizedBox(width:190,height:20,child:child)),
      paragraph:(value,size,color,maxLines)=>IdCardLayout.text(value,font:regular,
        fontSize:size,color:color,wrap:true,maxLines:maxLines),
      grid:(rows,font,rowHeight,firstHeader)=>table(rows,font:font,rowHeight:rowHeight,firstHeader:firstHeader),
      qrCode:qrCode,
    );
    final front=sides.front, back=sides.back, w=sides.width,h=sides.height,landscape=sides.landscape;
    validateIdSide(front, w, h);
    validateIdSide(back, w, h);
    addIdCardPair(pdf, front, back, w, h, landscape: landscape);
  } else if (kind == 'reportCard') {
    return renderMaroonMarksheet(data, photo:embeddedPhoto,logo:embeddedLogo,signature:printSignature,seal:embeddedSeal,plain:plain,printOnly:printOnly);
  } else {
    final items = data['feeItems'] is Map
        ? Map<String, dynamic>.from(data['feeItems'])
        : <String, dynamic>{};
    final entries = items.entries.toList();
    final chunks = entries.isEmpty
        ? <List<MapEntry<String, dynamic>>>[[]]
        : <List<MapEntry<String, dynamic>>>[
            for (var start = 0; start < entries.length; start += 8)
              entries.sublist(start, (start + 8).clamp(0, entries.length)),
          ];
    for (final chunk in chunks) {
      final rows = <List<String>>[
        ['Qty', 'Description', 'Unit Price', 'Total'],
      ];
      for (final e in chunk)
        rows.add(['1', e.key, 'INR ${e.value}', 'INR ${e.value}']);
      if (items.isEmpty)
        rows.add([
          '1',
          'School fee',
          'INR ${first(['installmentAmount', 'amount', 'totalAmount'])}',
          'INR ${first(['installmentAmount', 'amount', 'totalAmount'])}',
        ]);
      while (rows.length < 9) rows.add(['', '', '', '']);
      final layers = <pw.Widget>[
        at(
          18,
          18,
          576,
          756,
          pw.Container(
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey400, width: .5),
            ),
          ),
        ),
        at(86, 78, 75, 39, asset(embeddedLogo, 'SCHOOL LOGO')),
        at(86, 126, 245, 24, label(school, size: 16, heavy: true)),
        at(
          86,
          156,
          245,
          28,
          label(first(['schoolAddress', 'address']), size: 10),
        ),
        at(
          86,
          189,
          245,
          15,
          label(first(['schoolContactNo', 'schoolEmail']), size: 10),
        ),
        at(349, 82, 205, 32, label('SCHOOL RECEIPT', size: 22, heavy: true)),
        at(
          349,
          127,
          198,
          17,
          label('Date: ${first(['dateText', 'date'])}', size: 10),
        ),
        at(349, 151, 198, 17, label('Receipt #: ${v('receiptNo')}', size: 10)),
        at(
          86,
          208,
          249,
          23,
          label('Student Information', size: 12, heavy: true),
        ),
        at(
          343,
          208,
          203,
          23,
          label('Payment Information', size: 12, heavy: true),
        ),
        at(
          86,
          236,
          251,
          88,
          table(
            [
              ['Name:', name],
              [
                'Class / Roll:',
                '${first(['studentClass', 'class'])} / ${first([
                      'rollNo',
                      'roll'
                    ])}',
              ],
              [
                'Phone:',
                first(['parentContact', 'contact']),
              ],
              [
                'Guardian:',
                first(['parentName', 'fatherName']),
              ],
            ],
            firstHeader: false,
            font: 10,
          ),
        ),
        at(
          343,
          236,
          203,
          88,
          table(
            [
              ['Mode:', v('paymentMode')],
              ['Month:', v('month')],
              ['Collected by:', v('collectedBy')],
              ['Status:', v('status')],
            ],
            firstHeader: false,
            font: 10,
          ),
        ),
        at(86, 340, 460, 22, label("Item's Detail", size: 12, heavy: true)),
        at(
          86,
          360,
          460,
          168,
          table(
            rows,
            widths: [.4, 3, 1.2, 1.2],
            header: PdfColors.black,
            font: 9,
            rowHeight: 18.6,
          ),
        ),
        at(
          385,
          528,
          161,
          75,
          table(
            [
              [
                'Sub Total:',
                first(['expectedAmount', 'totalAmount', 'amount']),
              ],
              [
                'Total Paid:',
                first(['totalPaid', 'totalAmount', 'amount']),
              ],
              ['Total Due:', v('balance', '0')],
              [
                'Amount Paid:',
                first(['installmentAmount', 'amount', 'totalAmount']),
              ],
            ],
            firstHeader: false,
            font: 9,
            rowHeight: 18.6,
          ),
        ),
        if (seal != null) at(285, 638, 60, 48, asset(embeddedSeal, '')),
        at(
          86,
          625,
          330,
          22,
          label('Authorized Title and Signature', size: 12, heavy: true),
        ),
        at(
          86,
          659,
          200,
          17,
          label('Title: ${v('collectedBy', 'Admin')}', size: 10),
        ),
        at(361, 638, 152, 39, asset(printSignature, 'Signature: __________')),
      ];
      if (chunks.length > 1)
        layers.add(
          at(
            250,
            748,
            210,
            12,
            label(
              'Page ${chunks.indexOf(chunk) + 1} of ${chunks.length}',
              size: 8,
            ),
          ),
        );
      page(612, 792, layers);
    }
  }
  final output = await pdf.save();
  if (!printOnly && kind == 'teacherId' &&
      output.length > SchoolMediaBudgets.idCard &&
      printPass < 4) {
    // Only the print-bitmap DPI changes; vector QR, text, dimensions and
    // school media source bytes stay identical. Fail safely if all print
    // variants still exceed the strict PDF budget.
    return _renderWindowsReferenceDocument(
      kind: kind, template: template, data: data, qr: qr,
      photo: photo, logo: logo, signature: signature, seal: seal,
      printPass: printPass + 1, plain: plain,
      preparedMedia: (photo: embeddedPhoto, logo: embeddedLogo,
          seal: embeddedSeal, signature: printSignature),
    );
  }
  return printOnly?SchoolMediaBudgets.verifyPrintPdf(output):SchoolMediaBudgets.verifyGeneratedPdf(kind, output);
}

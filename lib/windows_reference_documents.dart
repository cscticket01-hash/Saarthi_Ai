import 'windows_maroon_marksheet.dart';
import 'id_card_engine.dart';
import 'id_card_layout.dart';
import 'windows_id_pair.dart';

import 'dart:typed_data';
import 'dart:async';
import 'dart:ui' as ui;

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

String _svg(double w, double h, String art, [String background = '#ffffff']) =>
    '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" viewBox="0 0 $w $h"><rect width="$w" height="$h" fill="$background"/>$art</svg>';
String _teacherArt(int i, bool back) {
  if (i == 0)
    return _svg(
      306,
      486,
      back
          ? '<path fill="#32464e" d="M262 0H306V486L192 88Z M0 234L32 300L0 375Z"/><path fill="#85b63e" d="M267 0H306V486L298 486Z"/>'
          : '<path fill="#85b63e" d="M0 0H306V486L119 255Z"/><path fill="#32464e" d="M0 0H73L306 408V486L0 63Z"/><path fill="#a8d15c" d="M0 15L306 435V466L0 44Z"/><path fill="white" d="M0 294H288V395H0Z M0 395H178L232 486H0Z"/>',
    );
  if (i == 1)
    return _svg(
      306,
      486,
      back
          ? '<path fill="#002c37" d="M0 0H306V251Q284 118 0 134Z"/><rect y="465" width="306" height="21" fill="#cc993d"/>'
          : '<rect width="306" height="486" fill="#002c37"/><path fill="white" d="M0 0H306V49Q218 287 0 254Z"/><path fill="#cc993d" d="M0 0H79Q61 47 0 65Z"/>',
    );
  if (i == 2)
    return _svg(
      480,
      300,
      back
          ? '<path fill="#44afd3" d="M0 0H480V70H0Z"/><path fill="#302e30" d="M265 0H480V70H171Z"/>'
          : '<path fill="#302e30" d="M0 0H273L175 46H0Z M219 217H480V278H301Z"/><path fill="#44afd3" d="M0 47H173L166 54H0Z M0 228H216L299 284H480V300H0Z"/>',
    );
  return _svg(
    306,
    486,
    back
        ? '<rect width="306" height="80" fill="#0b1b37"/><path fill="#e50e2c" d="M213 0H306V80H249Z"/><rect y="464" width="306" height="22" fill="#0b1b37"/>'
        : '<rect width="306" height="220" fill="#0b1b37"/><path fill="#e50e2c" d="M188 0H306V111H240Z"/><path fill="#142c59" d="M0 174L306 130V220H0Z"/><rect y="220" width="306" height="266" fill="#eef0f9"/>',
  );
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

Future<Uint8List> renderWindowsReferenceDocument({
  required String kind,
  required int template,
  required Map<String, dynamic> data,
  String qr = '',
  Uint8List? photo,
  Uint8List? logo,
  Uint8List? signature,
  Uint8List? seal,
}) async {
  if (!windowsReferenceDocumentNames.containsKey(kind))
    throw ArgumentError.value(kind, 'kind');
  final i = windowsReferenceDocumentIndex(kind, template);
  final printSignature = await _signatureInk(
    signature,
    white: false,
  );
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
  final regular = pw.Font.ttf(
    await rootBundle.load('assets/id_card_regular.ttf'),
  );
  final bold = pw.Font.ttf(await rootBundle.load('assets/id_card_bold.ttf'));
  final pdf = pw.Document(
    theme: pw.ThemeData.withFont(base: regular, bold: bold),
  );
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
          ? pw.Center(
              child: label(placeholder, size: 11, color: PdfColors.grey600))
          : pw.ClipRect(
              child: kind == 'teacherId'
                  ? IdCardLayout.image(bytes, cover: cover)
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
    final landscape = i == 2,
        w = landscape ? 480.0 : 306.0,
        h = landscape ? 300.0 : 486.0;
    final ink = PdfColor.fromHex(
      i == 0
          ? '#32464e'
          : i == 1
              ? '#002c37'
              : i == 2
                  ? '#302e30'
                  : '#0b1b37',
    );
    final white = PdfColors.white;
    final front = <pw.Widget>[
      pw.SvgImage(svg: _teacherArt(i, false), width: w, height: h),
    ];
    final back = <pw.Widget>[
      pw.SvgImage(svg: _teacherArt(i, true), width: w, height: h),
    ];
    final id = first(['teacherId', 'id']);
    final details = [
      ['Name:', name],
      ['Qualification:', v('qualification')],
      ['ID Number:', id],
      [
        'Working Since:',
        first(['joiningDate', 'workingSince', 'dateOfJoining']),
      ],
    ];
    if (i == 0 || i == 1) {
      if (i == 0) {
        front.addAll([
          at(
            114,
            17,
            180,
            45,
            label(school, size: 21, color: white, heavy: true),
          ),
          at(
            65,
            81,
            157,
            157,
            pw.Container(
              decoration: pw.BoxDecoration(
                shape: pw.BoxShape.circle,
                border: pw.Border.all(color: white, width: 4),
              ),
              child: pw.ClipOval(child: asset(photo, 'PHOTO', cover: true)),
            ),
          ),
          at(23, 296, 264, 88, table(details, firstHeader: false, font: 11)),
          at(234, 76, 45, 45, asset(logo, 'LOGO')),
          at(
            12,
            403,
            245,
            58,
            label('TEACHER', size: 47, color: ink, heavy: true),
          ),
        ]);
      } else {
        front.addAll([
          at(49, 15, 172, 192, asset(photo, 'PHOTO', cover: true)),
          at(
            49,
            15,
            172,
            192,
            pw.SvgImage(
              svg:
                  '<svg xmlns="http://www.w3.org/2000/svg" width="172" height="192"><path fill="white" d="M0 0H86L0 44Z M86 0H172V44Z M0 146L86 192H0Z M86 192L172 146V192Z"/><path fill="none" stroke="black" stroke-width="4" d="M86 3L166 45Q169 48 169 56V136Q169 144 163 149L93 187Q86 191 79 187L9 149Q3 144 3 136V56Q3 48 9 44Z"/></svg>',
            ),
            decorative: true,
          ),
          at(
            42,
            261,
            236,
            58,
            label('TEACHER', size: 48, color: white, heavy: true),
          ),
          at(31, 335, 244, 88, table(details, firstHeader: false, font: 11)),
          at(35, 432, 45, 40, asset(logo, 'LOGO')),
          at(
            86,
            432,
            203,
            37,
            label(
              school,
              size: 17,
              color: PdfColor.fromHex('#cc993d'),
              heavy: true,
            ),
          ),
        ]);
      }
      if (i == 0)
        back.add(
          at(
            262,
            30,
            20,
            190,
            pw.Transform.rotateBox(
              angle: -1.5707963267948966,
              unconstrained: true,
              child: pw.SizedBox(
                width: 190,
                height: 20,
                child: label(school, size: 17, color: white, heavy: true),
              ),
            ),
          ),
        );
      back.addAll([
        if (i == 1)
          at(
            25,
            i == 0 ? 22 : 20,
            i == 0 ? 145 : 205,
            45,
            label(
              school,
              size: 18,
              color: i == 0 ? ink : PdfColor.fromHex('#cc993d'),
              heavy: true,
            ),
          ),
        at(
          23,
          i == 0 ? 99 : 158,
          i == 0 ? 165 : 210,
          28,
          label('Terms & Conditions', size: i == 0 ? 15 : 17, color: ink),
        ),
        at(
          30,
          i == 0 ? 137 : 198,
          i == 0 ? 150 : 202,
          i == 0 ? 90 : 76,
          IdCardLayout.text(
            first(
              ['idCardTerms'],
              'This card identifies a member of the school staff. Carry it while on duty. Return it to the school office if found. This card is not transferable.',
            ),
            font: regular,
            fontSize: i == 0 ? 8 : 10,
            color: ink,
            wrap: true,
            maxLines: 8,
          ),
        ),
        at(
          i == 1 ? 153 : 28,
          i == 1 ? 277 : 243,
          125,
          43,
          asset(printSignature, 'Signature not set'),
        ),
        at(
          i == 1 ? 153 : 40,
          i == 1 ? 321 : 286,
          125,
          17,
          label('Principal signature', size: 9, color: ink),
        ),
      ]);
      if (i == 1) back.add(at(30, 275, 88, 88, qrCode(80)));
      if (i == 0)
        back.addAll([
          at(171, 237, 66, 66, qrCode(58)),
          at(180, 19, 43, 43, asset(logo, 'LOGO')),
        ]);
      if (i == 1) back.add(at(236, 17, 54, 76, asset(logo, 'LOGO')));
      back.addAll([
        at(
          28,
          i == 1 ? 370 : 326,
          240,
          25,
          label(first(['schoolAddress', 'address']), size: 10, color: ink),
        ),
        at(
          28,
          i == 1 ? 395 : 351,
          240,
          17,
          label(first(['schoolEmail', 'email']), size: 10, color: ink),
        ),
        at(
          28,
          i == 1 ? 419 : 375,
          240,
          17,
          label(
            first(['schoolContactNo', 'contact', 'phone']),
            size: 10,
            color: ink,
          ),
        ),
      ]);
      if (i == 0)
        back.add(
          at(
            27,
            413,
            245,
            48,
            pw.BarcodeWidget(
              barcode: pw.Barcode.code128(),
              data: id == '-' ? 'TEACHER' : id,
              drawText: true,
            ),
          ),
        );
    } else if (i == 2) {
      front.addAll([
        at(45, 82, 228, 35, label(name, size: 22, color: ink, heavy: true)),
        at(
          45,
          117,
          220,
          19,
          label(
            v('designation', 'Teacher'),
            size: 13,
            color: PdfColor.fromHex('#44afd3'),
          ),
        ),
        at(
          49,
          147,
          216,
          72,
          table(
            [
              ['ID No.', id],
              [
                'Issue Date',
                v('issueDate', first(['joiningDate'])),
              ],
              [
                'Expiration',
                first(['validUntil', 'expiryDate']),
              ],
            ],
            firstHeader: false,
            font: 10,
          ),
        ),
        at(
          305,
          24,
          144,
          144,
          pw.Container(
            decoration: pw.BoxDecoration(border: pw.Border.all(color: ink)),
            child: asset(photo, 'PHOTO', cover: true),
          ),
        ),
        at(
          296,
          183,
          168,
          23,
          label(
            school,
            size: 18,
            color: PdfColor.fromHex('#44afd3'),
            heavy: true,
          ),
        ),
        at(335, 224, 114, 44, asset(logo, 'SCHOOL LOGO')),
        at(88, 221, 57, 57, qrCode(49)),
      ]);
      back.addAll([
        at(18, 12, 143, 46, asset(logo, 'SCHOOL LOGO')),
        at(
          254,
          14,
          211,
          44,
          label(school, size: 20, color: white, heavy: true),
        ),
        at(
          35,
          87,
          414,
          37,
          label(
            '${first(['schoolAddress', 'address'])}\n${first([
                  'schoolContactNo',
                  'contact',
                  'phone'
                ])} | ${first(['schoolEmail', 'email'])}',
            size: 11,
          ),
        ),
        at(
          181,
          124,
          264,
          48,
          pw.BarcodeWidget(
            barcode: pw.Barcode.code128(),
            data: id == '-' ? 'TEACHER' : id,
            drawText: true,
          ),
        ),
        at(35, 172, 397, 24, label('Terms & Conditions', size: 14)),
        at(
          47,
          202,
          381,
          41,
          IdCardLayout.text(
            first(
              ['idCardTerms'],
              'Carry this school ID while on duty. If found, return it to the school office. It is not transferable.',
            ),
            font: regular,
            fontSize: 10,
            wrap: true,
            maxLines: 3,
          ),
        ),
        at(35, 251, 143, 20, label('Principal signature', size: 10)),
        at(178, 248, 128, 43, asset(printSignature, 'Signature not set')),
      ]);
    } else {
      front.addAll([
        at(17, 19, 40, 40, asset(logo, 'LOGO')),
        at(63, 26, 155, 22, label(school, size: 15, color: white, heavy: true)),
        at(
          63,
          48,
          155,
          14,
          label('SCHOOL • TEACHER ID', size: 8, color: white),
        ),
        at(
          231,
          26,
          66,
          23,
          pw.Container(
            decoration: pw.BoxDecoration(
              color: white,
              borderRadius: pw.BorderRadius.circular(15),
            ),
            child: label(
              'STAFF',
              size: 12,
              color: PdfColor.fromHex('#e50e2c'),
              heavy: true,
              align: pw.TextAlign.center,
            ),
          ),
        ),
        at(
          79,
          116,
          150,
          150,
          pw.Container(
            decoration: pw.BoxDecoration(
              shape: pw.BoxShape.circle,
              border: pw.Border.all(
                color: PdfColor.fromHex('#e50e2c'),
                width: 6,
              ),
            ),
            child: pw.ClipOval(child: asset(photo, 'PHOTO', cover: true)),
          ),
        ),
        at(
          24,
          280,
          261,
          30,
          label(
            name,
            size: 23,
            color: ink,
            heavy: true,
            align: pw.TextAlign.center,
          ),
        ),
        at(
          58,
          314,
          192,
          25,
          pw.Container(
            decoration: pw.BoxDecoration(
              color: PdfColor.fromHex('#e50e2c'),
              borderRadius: pw.BorderRadius.circular(15),
            ),
            child: label(
              v('designation', 'TEACHER'),
              size: 15,
              color: white,
              heavy: true,
              align: pw.TextAlign.center,
            ),
          ),
        ),
        at(
          26,
          361,
          252,
          66,
          table(
            [
              ['ID NO', id],
              [
                'DEPARTMENT',
                first(['department', 'subject']),
              ],
              [
                'VALID UNTIL',
                first(['validUntil', 'expiryDate']),
              ],
            ],
            firstHeader: false,
            font: 11,
          ),
        ),
        at(
          26,
          341,
          252,
          14,
          label(
            v('subject'),
            size: 10,
            color: PdfColors.grey600,
            align: pw.TextAlign.center,
          ),
        ),
        at(247, 440, 47, 42, qrCode(34)),
      ]);
      back.addAll([
        at(20, 22, 40, 36, asset(logo, 'LOGO')),
        at(
          70,
          22,
          220,
          23,
          label('OFFICIAL TEACHER ID', size: 15, color: white, heavy: true),
        ),
        at(80, 51, 210, 17, label(school, size: 11, color: white)),
        at(
          28,
          99,
          251,
          88,
          table(
            [
              [
                'PHONE',
                first(['contact', 'phone']),
              ],
              ['EMAIL', v('email')],
              [
                'WEBSITE',
                first(['schoolWebsite', 'website']),
              ],
              ['ADDRESS', v('address')],
            ],
            firstHeader: false,
            font: 10,
          ),
        ),
        at(
          28,
          197,
          251,
          44,
          table(
            [
              ['BLOOD GROUP', v('bloodGroup')],
              [
                'EMERGENCY',
                first(['emergencyContact', 'contact', 'phone']),
              ],
            ],
            firstHeader: false,
            font: 10,
          ),
        ),
        at(
          28,
          252,
          250,
          25,
          label(
            'TERMS OF USE',
            size: 13,
            color: PdfColor.fromHex('#b83548'),
            heavy: true,
          ),
        ),
        at(
          28,
          281,
          251,
          66,
          IdCardLayout.text(
            first(
              ['idCardTerms'],
              'This card is the property of the school and identifies its staff member. Wear it while on duty. It is not transferable. If found, return it to the school office.',
            ),
            font: regular,
            fontSize: 11,
            wrap: true,
            maxLines: 6,
          ),
        ),
        at(28, 353, 110, 31, label('Holder signature: __________', size: 9)),
        at(169, 348, 109, 31, asset(printSignature, 'Signature not set')),
        at(169, 380, 109, 13, label('Principal signature', size: 9)),
        at(
          78,
          406,
          174,
          44,
          pw.BarcodeWidget(
            barcode: pw.Barcode.code128(),
            data: id == '-' ? 'TEACHER' : id,
            drawText: true,
          ),
        ),
        at(
          30,
          467,
          250,
          15,
          label(
            'SCHOOL • TEACHER • STAFF',
            size: 10,
            color: white,
            align: pw.TextAlign.center,
          ),
        ),
      ]);
    }
    validateIdSide(front, w, h);
    validateIdSide(back, w, h);
    addIdCardPair(pdf, front, back, w, h, landscape: landscape);
  } else if (kind == 'reportCard') {
    return renderMaroonMarksheet(data, photo:photo,logo:logo,signature:printSignature,seal:seal);
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
        at(86, 78, 75, 39, asset(logo, 'SCHOOL LOGO')),
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
        if (seal != null) at(285, 638, 60, 48, asset(seal, '')),
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
  return pdf.save();
}

import 'id_card_engine.dart';
import 'id_card_layout.dart';
import 'windows_id_pair.dart';

import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

// Windows-only, vector artwork. Reference photos/text/watermarks are never used.
const windowsStudentIdNames = [
  'Blue Chevron • Portrait',
  'Navy Schoolhouse • Portrait',
  'Green Curve • Landscape',
  'Green & Yellow • Landscape',
];

int windowsStudentIdIndex(dynamic value) =>
    value is num && value.toInt() >= 0 && value.toInt() < 4 ? value.toInt() : 0;

String _background(int i, bool back) {
  final portrait = i < 2;
  final w = portrait ? 306 : 480, h = portrait ? 486 : 300;
  String art;
  if (i == 0) {
    art = back
        ? '<path fill="#38b2ef" d="M0 0H306L153 65Z M0 386L153 328L306 386V486H0Z"/><path fill="#0d4da7" d="M0 0L153 54L306 0V12L153 66L0 12Z M0 375L153 318L306 375V407L153 352L0 407Z"/><path fill="#38b2ef" d="M0 375L52 350L70 361L153 318L237 361L254 350L306 375V388L153 331L0 388Z"/>'
        : '<path fill="#38b2ef" d="M0 0H306V164L153 230L0 164Z"/><path fill="#0d4da7" d="M0 82L153 148L306 82V146L153 214L0 146Z M0 466L153 408L306 466V486L153 430L0 486Z"/><path fill="#38b2ef" d="M0 153L153 222L306 153V167L153 236L0 167Z M0 474L53 450L70 460L153 423L237 460L253 450L306 474V486H0Z"/>';
  } else if (i == 1) {
    art = back
        ? '<path fill="none" stroke="#201c4a" stroke-width="11" d="M6 6H300V480H6Z"/><path fill="none" stroke="#201c4a" stroke-width="8" d="M196 478V389Q236 354 264 369V478 M196 389Q167 353 132 367V478 M264 369Q277 343 293 349L306 423"/>'
        : '<path fill="#bed8ea" d="M0 0H306V151L153 70L0 151Z"/><path fill="#201c4a" d="M25 44H61V94H25Z M25 60H61V102H25Z M238 19H246V77H238Z M244 19H282L271 36L282 53H244Z M0 117L153 37L306 117V159L153 79L0 159Z"/><path fill="none" stroke="#8983ac" stroke-width="1" stroke-dasharray="5 3" d="M0 126L153 47L306 126 M0 148L153 68L306 148"/><path fill="#201c4a" d="M0 400Q77 364 153 400Q229 364 306 400V486H0Z"/><path fill="none" stroke="#8983ac" stroke-dasharray="4 3" d="M6 409Q77 377 153 409Q229 377 300 409V477H6Z"/>';
  } else if (i == 2) {
    art = back
        ? '<path fill="#f3f6f4" d="M0 166L180 63V230H0Z"/><path fill="#008043" d="M0 264H301Q334 264 350 221Q363 192 386 192H480V300H0Z"/><path fill="#006538" d="M332 300L399 192H480V300Z"/>'
        : '<path fill="#009c51" d="M0 0H480V72H0Z"/><path fill="#006b38" d="M0 0H180L126 106Q117 119 97 119H0Z"/><path fill="#ffd12b" d="M146 60H480V76H138Z"/><path fill="#007442" d="M0 276H480V300H0Z"/>';
  } else {
    art = back
        ? '<path fill="#f5f6f3" d="M0 220L300 78V254H0Z"/><path fill="#006915" d="M0 226H406L464 300H0Z"/><path fill="#ffdf23" d="M398 208H422L480 282V300H462Z"/>'
        : '<path fill="#006915" d="M0 0H480V82H0Z"/><path fill="#ffdf23" d="M0 82H480V87H0Z"/><path fill="#f4f6f2" d="M292 91L480 160V276H292Z"/><path fill="#ffdf23" d="M0 223H136L202 289H480V300H0Z"/><path fill="#006915" d="M0 228H109L169 300H0Z"/>';
  }
  return '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" viewBox="0 0 $w $h"><rect width="$w" height="$h" fill="white"/>$art</svg>';
}

/// Front/back share the same renderer for preview, download and printing.
Future<Uint8List> renderWindowsStudentId({
  required int template,
  required Map<String, dynamic> data,
  String qr = '',
  Uint8List? photo,
  Uint8List? logo,
  Uint8List? signature,
}) async {
  final i = windowsStudentIdIndex(template), portrait = i < 2;
  final width = portrait ? 306.0 : 480.0, height = portrait ? 486.0 : 300.0;
  final ink = PdfColor.fromHex(
    i == 0
        ? '#0d4da7'
        : i == 1
            ? '#201c4a'
            : '#006b38',
  );
  String value(String key, [String fallback = '-']) {
    final s = data[key]?.toString().trim() ?? '';
    return s.isEmpty || s.toLowerCase() == 'n/a' ? fallback : s;
  }

  final school = value('schoolName', 'School name');
  final name = value('name', value('studentName', 'Student name'));
  final father = value('parentName', value('fatherName'));
  final roll = value('roll', value('rollNo'));
  final contact = value('contact', value('parentContact'));
  final normalFont = pw.Font.ttf(
    await rootBundle.load('assets/id_card_regular.ttf'),
  );
  final boldFont = pw.Font.ttf(
    await rootBundle.load('assets/id_card_bold.ttf'),
  );
  final pdf = pw.Document(
    theme: pw.ThemeData.withFont(base: normalFont, bold: boldFont),
  );
  final positionedRegions = <pw.Widget, List<double>>{};
  final decorations = <pw.Widget>{};
  pw.Widget at(
    double x,
    double y,
    double w,
    double h,
    pw.Widget child, {
    bool decorative = false,
  }) {
    if ([x, y, w, h].any((v) => !v.isFinite) ||
        x < 0 ||
        y < 0 ||
        w <= 0 ||
        h <= 0 ||
        x + w > width ||
        y + h > height) {
      throw const FormatException(
        'Compatibility ID element lies outside its canvas.',
      );
    }
    final widget = pw.Positioned(
      left: x,
      top: y,
      child: pw.SizedBox(width: w, height: h, child: child),
    );
    positionedRegions[widget] = [x, y, w, h];
    if (decorative) decorations.add(widget);
    return widget;
  }

  void validateSide(List<pw.Widget> widgets) {
    final dynamic = widgets
        .where(
          (w) => positionedRegions.containsKey(w) && !decorations.contains(w),
        )
        .toList();
    for (var a = 0; a < dynamic.length; a++) {
      final r = positionedRegions[dynamic[a]]!;
      for (final widget in dynamic.skip(a + 1)) {
        final o = positionedRegions[widget]!;
        if (r[0] < o[0] + o[2] &&
            o[0] < r[0] + r[2] &&
            r[1] < o[1] + o[3] &&
            o[1] < r[1] + r[3]) {
          throw FormatException(
            'Compatibility ID dynamic regions overlap: $r / $o. Select a validated manifest template.',
          );
        }
      }
    }
  }

  pw.Widget text(
    String s, {
    double size = 12,
    PdfColor? color,
    bool bold = false,
    pw.TextAlign align = pw.TextAlign.left,
  }) =>
      IdCardLayout.text(
        s,
        font: bold ? boldFont : normalFont,
        fontSize: size,
        wrap: true,
        maxLines: 3,
        color: color ?? PdfColors.black,
        align: align,
      );
  pw.Widget image(Uint8List? bytes, String placeholder, {bool cover = false}) =>
      pw.Container(
        decoration: pw.BoxDecoration(
          color: PdfColors.white,
          border: pw.Border.all(color: ink, width: .7),
        ),
        child: pw.ClipRect(
          child: bytes == null
              ? pw.Center(child: text(placeholder, size: 9, color: ink))
              : IdCardLayout.image(bytes, cover: cover),
        ),
      );
  pw.Widget asset(Uint8List? bytes, String placeholder) => bytes == null
      ? pw.Center(child: text(placeholder, size: 9, color: ink))
      : IdCardLayout.image(bytes);
  pw.Widget field(String label, String content, double w, {double size = 11}) =>
      pw.Row(
        children: [
          pw.SizedBox(
            width: w * .38,
            child: text(label, size: size, bold: true, color: ink),
          ),
          pw.SizedBox(width: 8, child: text(':', size: size)),
          pw.Expanded(child: text(content, size: size)),
        ],
      );
  pw.Widget address(double w, {double size = 11}) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            'Address',
            style: pw.TextStyle(
              fontSize: size,
              fontWeight: pw.FontWeight.bold,
              color: ink,
            ),
          ),
          pw.SizedBox(height: 3),
          pw.Expanded(
            child: IdCardLayout.text(
              value('streetAddress', value('address')),
              font: normalFont,
              fontSize: size,
              wrap: true,
              maxLines: 6,
            ),
          ),
        ],
      );
  pw.Widget qrWidget(double size) => qr.isEmpty
      ? pw.SizedBox()
      : IdCardLayout.qr(IdCardEngine.compactQr(qr), millimetresPerUnit: (portrait ? 54 : 85.6) / width);
  final front = <pw.Widget>[
    pw.SvgImage(svg: _background(i, false), width: width, height: height),
  ];
  final back = <pw.Widget>[
    pw.SvgImage(svg: _background(i, true), width: width, height: height),
  ];
  if (i == 0) {
    front.addAll([
      at(25, 27, 57, 57, asset(logo, 'LOGO')),
      at(
        92,
        28,
        188,
        49,
        text(school, size: 20, color: PdfColors.white, bold: true),
      ),
      at(
        80,
        97,
        146,
        143,
        pw.Container(
          color: PdfColors.white,
          padding: const pw.EdgeInsets.all(7),
          child: image(photo, 'PHOTO', cover: true),
        ),
      ),
      at(
        24,
        249,
        258,
        33,
        text(
          name.toUpperCase(),
          size: 27,
          bold: true,
          align: pw.TextAlign.center,
        ),
      ),
      at(
        65,
        292,
        176,
        28,
        pw.Container(
          color: ink,
          child: text(
            'STUDENT IDENTITY CARD',
            color: PdfColors.white,
            bold: true,
            size: 12,
            align: pw.TextAlign.center,
          ),
        ),
      ),
      at(28, 325, 250, 18, field('Father name', father, 250)),
      at(28, 345, 250, 18, field('Class', value('class'), 250)),
      at(28, 365, 250, 18, field('Roll no.', roll, 250)),
      at(28, 385, 250, 18, field('Contact no.', contact, 250)),
    ]);
    back.addAll([
      at(
        28,
        77,
        250,
        35,
        text(school, size: 20, bold: true, align: pw.TextAlign.center),
      ),
      at(28, 126, 250, 67, address(250)),
      at(28, 198, 250, 18, field('District', value('district'), 250)),
      at(28, 220, 250, 18, field('State', value('state'), 250)),
      at(28, 242, 250, 18, field('PIN', value('pinCode'), 250)),
      at(32, 272, 130, 35, asset(signature, 'Signature not set')),
      at(
        32,
        309,
        130,
        14,
        text(
          'Principal signature',
          size: 10,
          color: ink,
          align: pw.TextAlign.center,
        ),
      ),
      at(203, 270, 75, 75, qrWidget(75)),
      at(125, 387, 56, 56, asset(logo, 'LOGO')),
      at(
        28,
        451,
        250,
        19,
        text(
          school,
          size: 16,
          color: PdfColors.white,
          bold: true,
          align: pw.TextAlign.center,
        ),
      ),
    ]);
  } else if (i == 1) {
    front.addAll([
      at(
        55,
        91,
        195,
        188,
        pw.SvgImage(
          svg:
              '<svg xmlns="http://www.w3.org/2000/svg" width="195" height="188"><path d="M4 60L97 5L190 60L160 182H34Z" fill="white" stroke="#201c4a" stroke-width="8"/></svg>',
        ),
        decorative: true,
      ),
      at(81, 139, 122, 127, image(photo, 'PHOTO', cover: true)),
      at(
        203,
        192,
        84,
        84,
        pw.Stack(
          children: [
            pw.SvgImage(
              svg:
                  '<svg xmlns="http://www.w3.org/2000/svg" width="84" height="84"><polygon fill="#201c4a" points="84.00,42.00 79.82,45.72 83.19,50.19 78.36,53.03 80.80,58.07 75.51,59.91 76.92,65.33 71.37,66.11 71.70,71.70 66.11,71.37 65.33,76.92 59.91,75.51 58.07,80.80 53.03,78.36 50.19,83.19 45.72,79.82 42.00,84.00 38.28,79.82 33.81,83.19 30.97,78.36 25.93,80.80 24.09,75.51 18.67,76.92 17.89,71.37 12.30,71.70 12.63,66.11 7.08,65.33 8.49,59.91 3.20,58.07 5.64,53.03 0.81,50.19 4.18,45.72 0.00,42.00 4.18,38.28 0.81,33.81 5.64,30.97 3.20,25.93 8.49,24.09 7.08,18.67 12.63,17.89 12.30,12.30 17.89,12.63 18.67,7.08 24.09,8.49 25.93,3.20 30.97,5.64 33.81,0.81 38.28,4.18 42.00,0.00 45.72,4.18 50.19,0.81 53.03,5.64 58.07,3.20 59.91,8.49 65.33,7.08 66.11,12.63 71.70,12.30 71.37,17.89 76.92,18.67 75.51,24.09 80.80,25.93 78.36,30.97 83.19,33.81 79.82,38.28"/></svg>',
            ),
            pw.Positioned(
              left: 10,
              top: 15,
              child: pw.SizedBox(
                width: 64,
                height: 54,
                child: pw.Column(
                  children: [
                    pw.Text(
                      'CLASS',
                      style: const pw.TextStyle(
                        fontSize: 11,
                        color: PdfColors.white,
                      ),
                    ),
                    pw.Expanded(
                      child: text(
                        value('class').replaceFirst('Class ', ''),
                        size: 28,
                        bold: true,
                        color: PdfColors.white,
                        align: pw.TextAlign.center,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      at(32, 292, 241, 22, field('Name', name, 241)),
      at(32, 318, 241, 22, field('Father name', father, 241)),
      at(32, 344, 241, 22, field('Roll no.', roll, 241)),
      at(30, 414, 52, 52, asset(logo, 'LOGO')),
      at(
        93,
        422,
        184,
        34,
        text(school, size: 23, color: PdfColors.white, bold: true),
      ),
    ]);
    back.addAll([
      at(
        30,
        30,
        245,
        29,
        text(
          'STUDENT DETAILS',
          size: 18,
          color: ink,
          align: pw.TextAlign.center,
        ),
      ),
      at(30, 74, 245, 19, field('Class', value('class'), 245)),
      at(30, 100, 245, 19, field('Contact no.', contact, 245)),
      at(30, 132, 245, 61, address(245)),
      at(30, 200, 245, 19, field('District', value('district'), 245)),
      at(30, 226, 245, 19, field('State', value('state'), 245)),
      at(30, 252, 245, 19, field('PIN', value('pinCode'), 245)),
      at(34, 287, 62, 62, asset(logo, 'LOGO')),
      at(132, 286, 141, 46, asset(signature, 'Signature not set')),
      at(
        132,
        334,
        141,
        15,
        text('Principal signature', size: 10, align: pw.TextAlign.center),
      ),
      at(30, 380, 82, 82, qrWidget(82)),
    ]);
  } else {
    final yellow = i == 3;
    front.addAll([
      at(22, 15, 70, 62, asset(logo, 'LOGO')),
      at(
        yellow ? 106 : 164,
        12,
        yellow ? 351 : 294,
        40,
        text(
          school.toUpperCase(),
          size: 24,
          color: PdfColors.white,
          bold: true,
          align: pw.TextAlign.center,
        ),
      ),
      at(
        yellow ? 108 : 164,
        53,
        yellow ? 350 : 294,
        20,
        text(
          yellow
              ? value('schoolAddress', 'STUDENT IDENTITY CARD')
              : 'STUDENT IDENTITY CARD',
          size: 11,
          color: yellow ? PdfColors.white : ink,
          bold: true,
          align: pw.TextAlign.center,
        ),
      ),
      at(
        23,
        yellow ? 101 : 130,
        84,
        yellow ? 111 : 103,
        image(photo, 'PHOTO', cover: true),
      ),
      if (yellow)
        at(
          266,
          104,
          157,
          22,
          pw.Container(
            color: PdfColor.fromHex('#a52b40'),
            child: text(
              'IDENTITY CARD',
              size: 13,
              color: PdfColors.white,
              align: pw.TextAlign.center,
            ),
          ),
        ),
      for (var n = 0; n < 6; n++)
        at(
          151,
          (yellow ? 140.0 : 94.0) + n * 23,
          306,
          20,
          field(
            [
              'Name',
              'Father name',
              'Class',
              'Roll no.',
              'Contact no.',
              'PIN',
            ][n],
            [name, father, value('class'), roll, contact, value('pinCode')][n],
            306,
            size: 12,
          ),
        ),
      at(23, yellow ? 230 : 236, 84, 24, asset(signature, 'Not set')),
      at(
        19,
        yellow ? 257 : 260,
        94,
        14,
        text(
          'Principal signature',
          size: 9,
          color: yellow ? PdfColors.white : PdfColors.black,
          align: pw.TextAlign.center,
        ),
      ),
      if (!yellow)
        at(
          134,
          279,
          322,
          16,
          text(
            value('schoolAddress', school),
            size: 10,
            color: PdfColors.white,
            align: pw.TextAlign.center,
          ),
        ),
    ]);
    back.addAll([
      at(
        23,
        23,
        350,
        24,
        text('STUDENT ADDRESS & DETAILS', size: 16, bold: true, color: ink),
      ),
      at(24, 61, 330, 63, address(330, size: 13)),
      at(24, 128, 330, 20, field('District', value('district'), 330, size: 12)),
      at(24, 153, 330, 20, field('State', value('state'), 330, size: 12)),
      at(24, 178, 330, 20, field('PIN', value('pinCode'), 330, size: 12)),
      at(359, 108, 110, 110, qrWidget(110)),
      at(
        26,
        yellow ? 239 : 213,
        yellow ? 341 : 280,
        37,
        text(
          'PLEASE RETURN TO SCHOOL\nAUTHORITY IF FOUND LOST.',
          size: 13,
          bold: true,
          color: yellow ? PdfColors.white : ink,
        ),
      ),
      if (!yellow)
        at(
          24,
          276,
          295,
          18,
          text(
            'STUDENT IDENTITY CARD',
            size: 12,
            color: PdfColors.white,
            bold: true,
          ),
        ),
    ]);
  }
  // Optional test UID stays on the reverse; existing scanner QR remains intact.
  if (data['showStudentUid'] == true)
    back.add(
      at(
        28,
        i == 0
            ? 356
            : portrait
                ? 359
                : 47,
        portrait ? 245 : 420,
        portrait ? 14 : 12,
        text('Student UID: ${value('studentUid')}', size: 9, color: ink),
      ),
    );
  validateSide(front);
  validateSide(back);
  addIdCardPair(pdf, front, back, width, height, landscape: !portrait);
  return pdf.save();
}

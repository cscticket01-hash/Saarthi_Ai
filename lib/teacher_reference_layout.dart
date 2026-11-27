import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw show TextAlign;

// A single geometry source for existing legacy teacher print and native preview.
// The native adapter never creates a PDF document.
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


({List<T> front,List<T> back,double width,double height,bool landscape})
buildTeacherReferenceLayers<T>({
  required int i, required Map<String,dynamic> data,
  required Uint8List? embeddedPhoto, required Uint8List? embeddedLogo,
  required Uint8List? printSignature,
  required T Function(double,double,double,double,T,bool) position,
  required T Function(String,double,PdfColor,bool,pw.TextAlign) text,
  required T Function(Uint8List?,String,bool) image,
  required T Function(String,double?,double?) artwork,
  required T Function(T,PdfColor,double) circle,
  required T Function(T,PdfColor) bordered,
  required T Function(T,PdfColor) badge,
  required T Function(T) rotateSchool,
  required T Function(String,double,PdfColor,int) paragraph,
  required T Function(List<List<String>>,double,double,bool) grid,
  required T Function(double) qrCode,
}) {
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
  final school = first(['schoolName','nameOfSchool'],'School name');
  final name = first(['name','teacherName'],'Teacher name');
  T at(double x,double y,double w,double h,T child,{bool decorative=false}) =>
    position(x,y,w,h,child,decorative);
  T label(String value,{double size=11,PdfColor color=PdfColors.black,
    bool heavy=false,pw.TextAlign align=pw.TextAlign.left}) => text(value,size,color,heavy,align);
  T asset(Uint8List? bytes,String placeholder,{bool cover=false}) => image(bytes,placeholder,cover);
  T svg({required String svg,double? width,double? height}) => artwork(svg,width,height);
  T bodyText(String value,{required double fontSize,PdfColor color=PdfColors.black,
    required int maxLines}) => paragraph(value,fontSize,color,maxLines);
  T table(List<List<String>> rows,{double font=10,double rowHeight=22,bool firstHeader=true}) =>
    grid(rows,font,rowHeight,firstHeader);
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
    final front = <T>[
      svg(svg: _teacherArt(i, false), width: w, height: h),
    ];
    final back = <T>[
      svg(svg: _teacherArt(i, true), width: w, height: h),
    ];
    final details = [
      ['Name:', name],
      ['Father Name:', first(['fatherName', 'parentName'])],
      ['Date of Birth:', first(['dateOfBirth', 'dob'])],
      ['Subject:', first(['subject', 'department'])],
      ['Address:', v('address')],
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
            circle(asset(embeddedPhoto, 'PHOTO', cover: true), white, 4),
          ),
          at(23, 296, 264, 88, table(details, firstHeader: false, font: 9, rowHeight: 17.6)),
          at(234, 76, 45, 45, asset(embeddedLogo, 'LOGO')),
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
          at(49, 15, 172, 192, asset(embeddedPhoto, 'PHOTO', cover: true)),
          at(
            49,
            15,
            172,
            192,
            svg(
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
          at(31, 335, 244, 88, table(details, firstHeader: false, font: 9, rowHeight: 17.6)),
          at(35, 432, 45, 40, asset(embeddedLogo, 'LOGO')),
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
            rotateSchool(label(school, size: 17, color: white, heavy: true)),
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
          bodyText(
            first(
              ['idCardTerms'],
              'This card identifies a member of the school staff. Carry it while on duty. Return it to the school office if found. This card is not transferable.',
            ),
            fontSize: i == 0 ? 8 : 10,
            color: ink,
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
          at(180, 19, 43, 43, asset(embeddedLogo, 'LOGO')),
        ]);
      if (i == 1) back.add(at(236, 17, 54, 76, asset(embeddedLogo, 'LOGO')));
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
            label('School teaching staff', size: 12, color: ink),
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
            details.skip(1).toList(),
            firstHeader: false,
            font: 9,
            rowHeight: 18,
          ),
        ),
        at(
          305,
          24,
          144,
          144,
          bordered(asset(embeddedPhoto, 'PHOTO', cover: true), ink),
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
        at(335, 224, 114, 44, asset(embeddedLogo, 'SCHOOL LOGO')),
        at(88, 221, 57, 57, qrCode(49)),
      ]);
      back.addAll([
        at(18, 12, 143, 46, asset(embeddedLogo, 'SCHOOL LOGO')),
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
          label('School teaching staff', size: 12, color: ink),
        ),
        at(35, 172, 397, 24, label('Terms & Conditions', size: 14)),
        at(
          47,
          202,
          381,
          41,
          bodyText(
            first(
              ['idCardTerms'],
              'Carry this school ID while on duty. If found, return it to the school office. It is not transferable.',
            ),
            fontSize: 10,
            maxLines: 3,
          ),
        ),
        at(35, 251, 143, 20, label('Principal signature', size: 10)),
        at(178, 248, 128, 43, asset(printSignature, 'Signature not set')),
      ]);
    } else {
      front.addAll([
        at(17, 19, 40, 40, asset(embeddedLogo, 'LOGO')),
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
          badge(label('STAFF', size: 12, color: PdfColor.fromHex('#e50e2c'),
              heavy: true, align: pw.TextAlign.center), white),
        ),
        at(
          79,
          116,
          150,
          150,
          circle(asset(embeddedPhoto, 'PHOTO', cover: true), PdfColor.fromHex('#e50e2c'), 6),
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
          badge(label(v('designation', 'TEACHER'), size: 15, color: white,
            heavy: true, align: pw.TextAlign.center), PdfColor.fromHex('#e50e2c')),
        ),
        at(
          26,
          361,
          252,
          66,
          table(
            details.skip(1).toList(),
            firstHeader: false,
            font: 9,
            rowHeight: 16.5,
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
        at(20, 22, 40, 36, asset(embeddedLogo, 'LOGO')),
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
          bodyText(
            first(
              ['idCardTerms'],
              'This card is the property of the school and identifies its staff member. Wear it while on duty. It is not transferable. If found, return it to the school office.',
            ),
            fontSize: 11,
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
          label('School teaching staff', size: 12, color: ink),
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

    return (front:front,back:back,width:w,height:h,landscape:landscape);
}

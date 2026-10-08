import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

const schoolTemplateNames = <String, List<String>>{
  'studentId': [
    'Student • Landscape Classic',
    'Student • Landscape Teal',
    'Student • Portrait Classic',
    'Student • Portrait Modern'
  ],
  'teacherId': [
    'Staff • Landscape Faculty',
    'Staff • Landscape Executive',
    'Staff • Portrait Faculty',
    'Staff • Portrait Executive'
  ],
  'reportCard': [
    'Academic Classic',
    'Modern Result',
    'Compact Landscape',
    'Formal Board'
  ],
  'receipt': [
    'Compact Receipt',
    'A4 Receipt',
    'Thermal Receipt',
    'Premium Receipt'
  ],
};
Future<Uint8List> renderSchoolDocument(
    {required String kind,
    required int template,
    required Map<String, dynamic> data,
    String qr = '',
    Uint8List? photo,
    Uint8List? logo}) async {
  final isDefault = template < 0;
  final i = template.clamp(0, 3);
  final teacher = kind == 'teacherId';
  final id = teacher || kind == 'studentId';
  final pdf = pw.Document();
  final colors = teacher
      ? [
          PdfColor.fromHex('#4A2868'),
          PdfColor.fromHex('#203D5B'),
          PdfColor.fromHex('#572C70'),
          PdfColor.fromHex('#344F63')
        ]
      : [
          PdfColor.fromHex('#174536'),
          PdfColor.fromHex('#087F8C'),
          PdfColor.fromHex('#164B75'),
          PdfColor.fromHex('#0B8874')
        ];
  final accent = colors[i];
  String text(String key, [String fallback = '']) =>
      data[key]?.toString().trim().isNotEmpty == true
          ? data[key].toString()
          : fallback;
  final school = text('schoolName', text('nameOfSchool', 'School'));
  final person = text('name', text('studentName', 'Name'));
  pw.Widget header(String title, {double size = 15}) => pw.Container(
      decoration: pw.BoxDecoration(
          color: isDefault ? PdfColors.white : accent,
          border: isDefault ? pw.Border.all(color: accent) : null),
      padding: pw.EdgeInsets.all(id && i >= 2 ? 6 : 10),
      child: pw.Row(children: [
        if (logo != null) ...[
          pw.Image(pw.MemoryImage(logo), width: 24, height: 24),
          pw.SizedBox(width: 8)
        ],
        pw.Expanded(
            child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
              pw.Text(school,
                  maxLines: 2,
                  style: pw.TextStyle(
                      color: isDefault ? accent : PdfColors.white,
                      fontSize: size,
                      fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 3),
              pw.Text(title,
                  style: pw.TextStyle(
                      color: isDefault ? accent : PdfColors.white, fontSize: 8))
            ]))
      ]));
  pw.Widget line(String label, String value, {double size = 9}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 3),
      child: pw.Row(children: [
        pw.SizedBox(
            width: 80,
            child: pw.Text(label,
                style: pw.TextStyle(color: PdfColors.grey600, fontSize: size))),
        pw.Expanded(
            child: pw.Text(value,
                style: pw.TextStyle(
                    fontSize: size, fontWeight: pw.FontWeight.bold)))
      ]));
  if (id) {
    final landscape = i < 2;
    final format = PdfPageFormat((landscape ? 85.6 : 54) * PdfPageFormat.mm,
        (landscape ? 54 : 85.6) * PdfPageFormat.mm);
    final pic = pw.Container(
        width: (landscape ? 17 : 20) * PdfPageFormat.mm,
        height: (landscape ? 22 : 14) * PdfPageFormat.mm,
        decoration: pw.BoxDecoration(
            color: PdfColors.grey200,
            border: pw.Border.all(color: accent, width: .5)),
        child: photo != null
            ? pw.Image(pw.MemoryImage(photo), fit: pw.BoxFit.cover)
            : pw.Center(
                child: pw.Text(teacher ? 'STAFF' : 'PHOTO',
                    style: const pw.TextStyle(
                        fontSize: 7, color: PdfColors.grey600))));
    final qrWidget = qr.isEmpty
        ? pw.SizedBox()
        : pw.BarcodeWidget(
            barcode: pw.Barcode.qrCode(),
            data: qr,
            width: 20 * PdfPageFormat.mm,
            height: 20 * PdfPageFormat.mm);
    final info = pw
        .Column(crossAxisAlignment: CrossAxisAlignmentForPdf.start, children: [
      pw.Text(person,
          maxLines: 2,
          style: pw.TextStyle(
              fontSize: landscape ? 11 : 9,
              fontWeight: pw.FontWeight.bold,
              color: accent)),
      pw.SizedBox(height: 4),
      pw.Text(
          teacher
              ? text('designation', 'Teacher')
              : '${text('class', 'Class')}  |  Roll ${text('rollNo', text('roll'))}',
          style: const pw.TextStyle(fontSize: 8)),
      pw.SizedBox(height: 4),
      pw.Text(
          teacher
              ? 'ID: ${text('teacherId', text('studentId'))}'
              : 'DOB: ${text('dob', text('dateOfBirth'))}',
          style: const pw.TextStyle(fontSize: 7)),
      pw.SizedBox(height: 3),
      pw.Text(
          teacher ? text('subject') : text('parentName', text('fatherName')),
          maxLines: 2,
          style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700))
    ]);
    pdf.addPage(pw.Page(
        pageFormat: format,
        margin: const pw.EdgeInsets.all(5),
        build: (_) => pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                children: [
                  header(
                      teacher
                          ? 'FACULTY IDENTIFICATION'
                          : 'STUDENT IDENTIFICATION',
                      size: 9),
                  pw.SizedBox(height: 7),
                  if (landscape)
                    pw.Row(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: i == 1
                            ? [
                                qrWidget,
                                pw.SizedBox(width: 7),
                                pw.Expanded(child: info),
                                pw.SizedBox(width: 6),
                                pic
                              ]
                            : [
                                pic,
                                pw.SizedBox(width: 7),
                                pw.Expanded(child: info),
                                pw.SizedBox(width: 6),
                                qrWidget
                              ])
                  else ...[
                    pw.Center(child: pic),
                    pw.SizedBox(height: 6),
                    if (i == 3)
                      pw.Container(
                          decoration: pw.BoxDecoration(
                              color: PdfColors.grey100,
                              border: pw.Border.all(color: accent, width: .5)),
                          padding: const pw.EdgeInsets.all(4),
                          child: info)
                    else
                      info,
                    pw.SizedBox(height: 6),
                    pw.Center(child: qrWidget)
                  ],
                  pw.Spacer(),
                  pw.Container(
                      color: accent,
                      padding: const pw.EdgeInsets.all(4),
                      child: pw.Text(
                          'VALID SCHOOL ID  |  ${teacher ? 'TEACHER' : 'STUDENT'}',
                          textAlign: pw.TextAlign.center,
                          style: const pw.TextStyle(
                              fontSize: 6, color: PdfColors.white)))
                ])));
  } else if (kind == 'reportCard') {
    final marks = data['marks'] is Map
        ? Map<String, dynamic>.from(data['marks'])
        : <String, dynamic>{};
    final rows = marks.entries
        .map((e) => [e.key, e.value.toString(), text('fullMarks', '100')])
        .toList();
    pdf.addPage(pw.MultiPage(
        pageFormat: i == 2 ? PdfPageFormat.a4.landscape : PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (_) => [
              header('ACADEMIC REPORT CARD'),
              if (i == 3 && !isDefault) ...[
                pw.SizedBox(height: 18),
                pw.Center(
                    child: pw.Text('STATEMENT OF MARKS',
                        style: pw.TextStyle(
                            fontSize: 18, fontWeight: pw.FontWeight.bold))),
                pw.Divider(color: accent)
              ],
              pw.SizedBox(height: 18),
              pw.Text(person,
                  style: pw.TextStyle(
                      fontSize: 22,
                      fontWeight: pw.FontWeight.bold,
                      color: accent)),
              pw.SizedBox(height: 8),
              line('Class / Roll',
                  '${text('studentClass', text('class'))} / ${text('rollNo', text('roll'))}'),
              line('Examination', text('examName', 'Final examination')),
              if (i == 1) ...[
                pw.SizedBox(height: 16),
                pw.Container(
                    color: PdfColors.grey100,
                    padding: const pw.EdgeInsets.all(15),
                    child: pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text('${text('percentage', '0')}%',
                              style: pw.TextStyle(
                                  fontSize: 25,
                                  color: accent,
                                  fontWeight: pw.FontWeight.bold)),
                          pw.Text(text('result', 'PENDING'),
                              style: pw.TextStyle(
                                  fontSize: 20,
                                  color: accent,
                                  fontWeight: pw.FontWeight.bold))
                        ]))
              ],
              pw.SizedBox(height: 20),
              pw.TableHelper.fromTextArray(
                  headers: ['Subject', 'Marks obtained', 'Maximum'],
                  data: rows.isEmpty
                      ? [
                          ['No marks entered', '—', '—']
                        ]
                      : rows,
                  headerStyle: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold,
                      color: i == 3 ? accent : PdfColors.white),
                  headerDecoration: pw.BoxDecoration(
                      color: i == 3 ? PdfColors.grey200 : accent),
                  cellPadding: pw.EdgeInsets.all(i == 2 ? 5 : 9),
                  cellStyle: const pw.TextStyle(fontSize: 10)),
              pw.SizedBox(height: 16),
              line('Total', text('totalMarks', text('total'))),
              line('Percentage', '${text('percentage', '0')}%'),
              line('Result', text('result', 'PENDING')),
              pw.SizedBox(height: 35),
              pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text('Class teacher signature'),
                    pw.Text('Principal signature')
                  ]),
              pw.SizedBox(height: 12),
              pw.Text('Issued by $school',
                  style:
                      const pw.TextStyle(fontSize: 8, color: PdfColors.grey600))
            ]));
  } else {
    final items = data['feeItems'] is Map
        ? Map<String, dynamic>.from(data['feeItems'])
        : <String, dynamic>{};
    final rows = items.entries.map((e) => [e.key, 'INR ${e.value}']).toList();
    final format = i == 2
        ? PdfPageFormat(80 * PdfPageFormat.mm, 200 * PdfPageFormat.mm)
        : i == 0
            ? PdfPageFormat.a5
            : PdfPageFormat.a4;
    pdf.addPage(pw.MultiPage(
        pageFormat: format,
        margin: pw.EdgeInsets.all(i == 2 ? 12 : 25),
        build: (_) => [
              header('SCHOOL PAYMENT RECEIPT', size: i == 2 ? 12 : 18),
              if (i == 3 && !isDefault) ...[
                pw.SizedBox(height: 18),
                pw.Container(
                    decoration:
                        pw.BoxDecoration(border: pw.Border.all(color: accent)),
                    padding: const pw.EdgeInsets.all(18),
                    child: pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          pw.Text('PAYMENT RECEIVED',
                              style: pw.TextStyle(
                                  fontWeight: pw.FontWeight.bold,
                                  color: accent)),
                          pw.Text(
                              'INR ${text('totalAmount', text('amount', '0'))}',
                              style: pw.TextStyle(
                                  fontSize: 22,
                                  fontWeight: pw.FontWeight.bold,
                                  color: accent))
                        ]))
              ],
              pw.SizedBox(height: 16),
              line('Receipt', text('receiptNo')),
              line('Date', text('dateText', text('date'))),
              line('Student', person),
              line('Class / Roll',
                  '${text('studentClass', text('class'))} / ${text('rollNo', text('roll'))}'),
              pw.SizedBox(height: 15),
              pw.TableHelper.fromTextArray(
                  headers: ['Description', 'Amount'],
                  data: rows.isEmpty
                      ? [
                          [
                            'School fees',
                            'INR ${text('amount', text('totalAmount', '0'))}'
                          ]
                        ]
                      : rows,
                  headerStyle: pw.TextStyle(
                      fontWeight: pw.FontWeight.bold, color: PdfColors.white),
                  headerDecoration: pw.BoxDecoration(color: accent),
                  cellPadding: const pw.EdgeInsets.all(7)),
              pw.SizedBox(height: 15),
              line('Total paid',
                  'INR ${text('totalAmount', text('amount', '0'))}'),
              line('Payment mode', text('paymentMode', 'Cash')),
              pw.SizedBox(height: 25),
              pw.Text('Authorised signature', textAlign: pw.TextAlign.right),
              pw.SizedBox(height: 12),
              pw.Text('Thank you. Please keep this receipt for your records.',
                  style:
                      const pw.TextStyle(fontSize: 8, color: PdfColors.grey600))
            ]));
  }
  return pdf.save();
}

// A named alias keeps the dense card layout readable without Flutter types.
class CrossAxisAlignmentForPdf {
  static const start = pw.CrossAxisAlignment.start;
}

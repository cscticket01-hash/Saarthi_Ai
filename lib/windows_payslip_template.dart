import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Print colours are fixed to paper/ink; never inherited from the app theme.
Future<Uint8List> renderWindowsPayslip(Map<String,dynamic> row,{String schoolName=''}) async {
  final regular=pw.Font.ttf(await rootBundle.load('assets/id_card_regular.ttf'));
  final bold=pw.Font.ttf(await rootBundle.load('assets/id_card_bold.ttf'));
  final doc=pw.Document(theme:pw.ThemeData.withFont(base:regular,bold:bold));
  int amount(String key)=>(row[key] as num?)?.toInt()??0;
  String money(int paise)=>'Rs ${(paise/100).toStringAsFixed(2)}';
  final earnings=amount('basicPaise')+amount('allowancePaise')+amount('bonusPaise')+amount('overtimePaise');
  final net=(row['netPaise'] as num?)?.toInt()??earnings-amount('deductionPaise');
  final paid=amount('paidPaise');
  final ink=PdfColor.fromHex('#183347'),tint=PdfColor.fromHex('#EEF3F6');
  pw.Widget table(List<List<String>> rows)=>pw.TableHelper.fromTextArray(data:rows,
    headerStyle:pw.TextStyle(fontWeight:pw.FontWeight.bold,color:ink),headerDecoration:pw.BoxDecoration(color:tint),
    cellStyle:const pw.TextStyle(color:PdfColors.black,fontSize:11),cellPadding:const pw.EdgeInsets.all(10),
    border:pw.TableBorder.all(color:PdfColors.grey400,width:.5));
  doc.addPage(pw.MultiPage(pageTheme:pw.PageTheme(pageFormat:PdfPageFormat.a4,margin:const pw.EdgeInsets.all(36),
    buildBackground:(_)=>pw.FullPage(ignoreMargins:true,child:pw.Container(color:PdfColors.white))),
    footer:(context)=>pw.Row(mainAxisAlignment:pw.MainAxisAlignment.spaceBetween,children:[
      pw.Text('Vidya Saarthi | Staff payslip',style:const pw.TextStyle(fontSize:9,color:PdfColors.grey700)),pw.Text('Page ${context.pageNumber}',style:const pw.TextStyle(fontSize:9,color:PdfColors.grey700))]),
    build:(_)=>[
      pw.Text(schoolName.isEmpty?'SCHOOL PAYSLIP':schoolName,style:pw.TextStyle(color:ink,fontSize:22,fontWeight:pw.FontWeight.bold)),
      pw.SizedBox(height:6),pw.Text('STAFF SALARY PAYSLIP',style:pw.TextStyle(color:ink,fontWeight:pw.FontWeight.bold)),pw.SizedBox(height:20),
      table([['Employee','Salary period'],['${row['name']??''}','${row['month']??''}'],['Role: ${row['role']??''}','Employee: ${row['employeeId']??row['teacherId']??row['staffId']??''}']]),
      pw.SizedBox(height:20),table([['Earnings / deductions','Amount'],
        ['Basic pay',money(amount('basicPaise'))],['Allowances',money(amount('allowancePaise'))],['Bonus',money(amount('bonusPaise'))],
        ['Overtime',money(amount('overtimePaise'))],['Deductions',money(amount('deductionPaise'))],['NET SALARY',money(net)]]),
      pw.SizedBox(height:16),table([['Payment summary','Amount'],['Paid',money(paid)],['Balance',money(net-paid)],['Status','${row['status']??'Pending'}']]),
      if ((row['paymentCorrections'] as List? ?? []).isNotEmpty) ...[
        pw.SizedBox(height:18),
        pw.Text('PAYMENT CORRECTION AUDIT',style:pw.TextStyle(color:ink,fontSize:13,fontWeight:pw.FontWeight.bold)),
        pw.SizedBox(height:8),
        ...((row['paymentCorrections'] as List? ?? []).whereType<Map>()).map((entry) {
          final original=(entry['originalPaise'] as num?)?.toInt() ?? 0;
          final previous=(entry['previousPaise'] as num?)?.toInt() ?? original;
          final revised=(entry['correctedPaise'] as num?)?.toInt() ?? 0;
          final change=revised-previous;
          final reason=entry['reason']?.toString() ?? '';
          return pw.Column(crossAxisAlignment:pw.CrossAxisAlignment.start,children:[
            table([
              ['Original entry','Previous value','Corrected value','Adjustment'],
              [money(original),money(previous),money(revised),money(change)],
            ]),
            pw.SizedBox(height:5),
            pw.Text('Correction by: ${entry['authorizedBy'] ?? 'School Admin'}',style:const pw.TextStyle(fontSize:9)),
            pw.SizedBox(height:4),
            pw.Text('Reason: $reason',style:const pw.TextStyle(fontSize:9)),
            pw.SizedBox(height:12),
          ]);
        }),
      ],
      pw.SizedBox(height:12),pw.Text('A payslip summarises this salary record. It does not record a new payment.',style:const pw.TextStyle(fontSize:9,color:PdfColors.grey700)),
      pw.SizedBox(height:36),pw.Row(mainAxisAlignment:pw.MainAxisAlignment.spaceBetween,children:[pw.Text('Employee signature: ______________'),pw.Text('Authorised signature: ______________')]),
    ]));
  return doc.save();
}

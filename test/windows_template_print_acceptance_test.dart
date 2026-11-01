import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Mechanical A4 proof: this creates a real printable PDF artifact.
/// Passing does NOT certify a specific school's physical paper/printer.
void main(){
  TestWidgetsFlutterBinding.ensureInitialized();
  test('produce full US Legal 8.5 by 14 inch printer calibration proof',() async {
    final format=PdfPageFormat.legal;
    expect((format.width-8.5*PdfPageFormat.inch).abs(),lessThan(.01));
    expect((format.height-14*PdfPageFormat.inch).abs(),lessThan(.01));
    final mm=PdfPageFormat.mm;
    final document=pw.Document();
    document.addPage(pw.Page(
      pageFormat:format,margin:pw.EdgeInsets.zero,
      build:(_)=>pw.Stack(children:[
        pw.SizedBox(width:format.width,height:format.height),
        pw.Positioned(left:10*mm,top:10*mm,
          child:pw.Container(width:100*mm,height:.35*mm,
            color:PdfColors.black)),
        pw.Positioned(left:10*mm,top:10*mm,
          child:pw.Container(width:.35*mm,height:100*mm,
            color:PdfColors.black)),
        pw.Positioned(left:10*mm,top:116*mm,
          child:pw.Text('Legal 8.5 x 14 inch physical print calibration')),
        pw.Positioned(left:10*mm,top:124*mm,
          child:pw.Text('Print at Actual Size 100%; no Fit to Page.')),
        pw.Positioned(left:10*mm,top:132*mm,
          child:pw.Text('Measure two 100mm lines and 10mm margins.')),
        pw.Positioned(left:10*mm,top:140*mm,
          child:pw.Text('Physical hardware approval is required.')),
      ]),
    )));
    final bytes=await document.save();
    expect(bytes.take(5).toList(),[37,80,68,70,45]);
    await Directory('build').create(recursive:true);
    await File('build/templateforge_legal_print_proof.pdf')
      .writeAsBytes(bytes,flush:true);
    expect(await File('build/templateforge_legal_print_proof.pdf').length(),
      greaterThan(500));
  });

  test('produce exact-size ISO A4 printer registration proof',() async {
    const tolerance=.01;
    const mm=PdfPageFormat.mm;
    final page=PdfPageFormat.a4;
    expect((page.width-210*mm).abs(),lessThan(tolerance));
    expect((page.height-297*mm).abs(),lessThan(tolerance));
    final doc=pw.Document();
    doc.addPage(pw.Page(pageFormat:page,margin:pw.EdgeInsets.zero,
      build:(_)=>pw.Stack(children:[
        pw.SizedBox(width:page.width,height:page.height),
        pw.Positioned(left:10*mm,top:10*mm,
          child:pw.Container(width:100*mm,height:.35*mm,
            color:PdfColors.black)),
        pw.Positioned(left:10*mm,top:10*mm,
          child:pw.Container(width:.35*mm,height:100*mm,
            color:PdfColors.black)),
        pw.Positioned(left:10*mm,top:115*mm,
          child:pw.Text('A4 TemplateForge physical print calibration')),
        pw.Positioned(left:10*mm,top:123*mm,
          child:pw.Text('Print at actual size / 100%; disable Fit to Page.')),
        pw.Positioned(left:10*mm,top:131*mm,
          child:pw.Text('Measure BOTH 100 mm black lines with a ruler.')),
        pw.Positioned(left:10*mm,top:139*mm,
          child:pw.Text('Verify 10 mm from the top and left paper edges.')),
        pw.Positioned(left:10*mm,top:147*mm,
          child:pw.Text('Record printer, driver, page scaling, and measurement.')),
        pw.Positioned(left:10*mm,top:155*mm,
          child:pw.Text('Do NOT mark printer acceptance from CI alone.')),
      ]),
    ));
    final bytes=await doc.save();
    expect(bytes.take(5).toList(),[37,80,68,70,45]);
    final dir=Directory('build');
    if(!await dir.exists())await dir.create(recursive:true);
    await File('build/templateforge_a4_print_proof.pdf')
      .writeAsBytes(bytes,flush:true);
    expect(await File('build/templateforge_a4_print_proof.pdf').length(),
      greaterThan(500));
  });
}

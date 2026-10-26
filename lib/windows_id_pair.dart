import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Both sides on one page, keeping each card at its physical CR80 size.
void addIdCardPair(pw.Document pdf, List<pw.Widget> front,
    List<pw.Widget> back, double artWidth, double artHeight,
    {required bool landscape}) {
  final width = (landscape ? 85.6 : 54) * PdfPageFormat.mm;
  final height = (landscape ? 54 : 85.6) * PdfPageFormat.mm;
  final gap = 8 * PdfPageFormat.mm;
  pw.Widget side(List<pw.Widget> layers) => pw.SizedBox(
      width: width, height: height,
      child: pw.FittedBox(child: pw.SizedBox(width: artWidth,
          height: artHeight, child: pw.Stack(children: layers))));
  pdf.addPage(pw.Page(pageFormat: PdfPageFormat(width * 2 + gap, height),
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.Row(children: [side(front), pw.SizedBox(width: gap), side(back)])));
}

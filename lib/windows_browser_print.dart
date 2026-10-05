import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

/// Use the installed browser's print preview: printer, copies, pages and paper.
/// Render locally at 300 DPI; student documents never go to a web service.
class WindowsBrowserPrint {
  static Future<void> open(Uint8List pdf) async {
    final pages = <String>[];
    await for (final page in Printing.raster(pdf, dpi: 300)) {
      final png = await page.toPng();
      final width = page.width * 25.4 / 300;
      final height = page.height * 25.4 / 300;
      pages.add('<section><img style="width:${width}mm;height:${height}mm" src="data:image/png;base64,${base64Encode(png)}"></section>');
    }
    if (pages.isEmpty) throw StateError('No printable pages.');
    final directory = await Directory.systemTemp.createTemp('vidya-print-');
    final file = File('${directory.path}${Platform.pathSeparator}print.html');
    await file.writeAsString('''<!doctype html><html><head><meta charset="utf-8"><title>Vidya Saarthi Print</title>
<style>@page{size:A4;margin:10mm}body{margin:0;background:#ddd}section{background:white;break-after:page;padding:0}section:last-child{break-after:auto}img{display:block;max-width:100%;object-fit:contain}@media print{body{background:white}button{display:none}}</style></head>
<body><button onclick="window.print()">Print</button>${pages.join()}<script>window.onload=()=>window.print();</script></body></html>''', flush:true);
    if (!await launchUrl(Uri.file(file.path), mode: LaunchMode.externalApplication)) {
      throw StateError('Could not open browser print preview. Download the PDF and open it in your browser.');
    }
  }
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

/// Local browser print preview, with printer, copies, pages and paper controls.
class WindowsBrowserPrint {
  static Future<void> open(Uint8List pdf) async {
    final pages = <({Uint8List png, int width, int height})>[];
    await for (final page in Printing.raster(pdf, dpi: 300)) {
      pages.add((png:await page.toPng(),width:page.width,height:page.height));
    }
    if (pages.isEmpty) throw StateError('No printable pages.');
    final directory = await Directory.systemTemp.createTemp('vidya-print-');
    final file = File('${directory.path}${Platform.pathSeparator}print.html');
    await file.writeAsString(html(pages),flush:true);
    if (!await launchUrl(Uri.file(file.path), mode: LaunchMode.externalApplication)) {
      throw StateError('Could not open browser print preview. Download the PDF and open it in your browser.');
    }
  }
  static String html(List<({Uint8List png, int width, int height})> pages) {
    final images=[for(final page in pages)
      '<section><img style="width:${page.width*25.4/300}mm" src="data:image/png;base64,${base64Encode(page.png)}"></section>'];
    return '''<!doctype html><html><head><meta charset="utf-8"><title>Vidya Saarthi Print</title>
<style>@page{size:A4;margin:10mm}body{margin:0;background:#ddd}section{background:white;break-after:page;padding:0}section:last-child{break-after:auto}img{display:block;max-width:190mm;max-height:277mm;height:auto;object-fit:contain}@media print{body{background:white}button{display:none}}</style></head>
<body><button onclick="window.print()">Print</button>${images.join()}<script>window.onload=()=>window.print();</script></body></html>''';
  }
}

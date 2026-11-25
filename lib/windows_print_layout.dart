import 'dart:typed_data';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// Print-only imposition. The source PDF is immutable. A changed layout is
/// rendered at 300 dpi; unchanged PDFs can retain their original vector data.
class WindowsPrintLayout {
  static const dpi = 300.0;
  static Set<int>? parseRange(String text) {
    if (text.trim().isEmpty) return null;
    final pages = <int>{};
    for (final token in text.split(',')) {
      final match = RegExp(r'^\s*(\d{1,5})(?:\s*-\s*(\d{1,5}))?\s*$').firstMatch(token);
      if (match == null) throw const FormatException('Use pages like 1,3-5.');
      final first = int.parse(match[1]!);
      final last = int.parse(match[2] ?? match[1]!);
      if (first < 1 || last < first || last > 10000 || last - first > 100) {
        throw const FormatException('Invalid page range.');
      }
      for (var page = first; page <= last; page++) {
        pages.add(page);
        if (pages.length > 100) throw const FormatException('Select up to 100 pages for a changed layout.');
      }
    }
    return pages;
  }

  static ({int columns, int rows}) grid(int count, bool landscape) {
    final dimensions = switch (count) {
      1 => (1,1), 2 => (1,2), 4 => (2,2), 6 => (2,3),
      9 => (3,3), 16 => (4,4), _ => throw const FormatException('Unsupported pages per sheet.'),
    };
    return landscape ? (columns:dimensions.$2,rows:dimensions.$1) :
      (columns:dimensions.$1,rows:dimensions.$2);
  }

  static ({double width, double height}) imageSize({
    required double sourceWidth, required double sourceHeight,
    required double cellWidth, required double cellHeight, double? scale,
  }) {
    if ([sourceWidth,sourceHeight,cellWidth,cellHeight].any((n)=>!n.isFinite||n<=0)) {
      throw const FormatException('Invalid printable area.');
    }
    final fitW = cellWidth/sourceWidth, fitH = cellHeight/sourceHeight;
    final factor = scale == null ? (fitW < fitH ? fitW : fitH) : scale / 100;
    final width = sourceWidth*factor, height = sourceHeight*factor;
    if (!factor.isFinite || factor <= 0 || width > cellWidth+.3 || height > cellHeight+.3) {
      throw const FormatException('Selected scale exceeds the printable area. Use Fit to page or reduce scale.');
    }
    return (width:width,height:height);
  }

  static Future<Uint8List> compose(Uint8List source, PdfPageFormat paper, {
    required bool Function() isCurrent, String range='', int perSheet=1,
    double marginMm=0, double? scale,
  }) async {
    final requested = parseRange(range);
    final gridSize = grid(perSheet,paper.width>paper.height);
    final margin = marginMm*PdfPageFormat.mm;
    final cellW = (paper.width-2*margin)/gridSize.columns;
    final cellH = (paper.height-2*margin)/gridSize.rows;
    if (marginMm<0 || cellW<=0 || cellH<=0) throw const FormatException('Margins exceed paper size.');
    final document = pw.Document();
    final cells = <pw.Widget>[];
    var count=0, sourceIndex=0, encodedBytes=0;
    void flush() {
      if (cells.isEmpty) return;
      final pageCells = List<pw.Widget>.of(cells);
      document.addPage(pw.Page(pageFormat:paper,margin:pw.EdgeInsets.zero,
        build:(_)=>pw.Stack(children:[pw.SizedBox(width:paper.width,height:paper.height),...pageCells])));
      cells.clear();
    }
    await for (final page in Printing.raster(source,dpi:dpi)) {
      if (!isCurrent()) throw StateError('Print cancelled or school changed.');
      sourceIndex++;
      if (requested != null && !requested.contains(sourceIndex)) continue;
      if (++count>100) throw const FormatException('Changed layout supports up to 100 pages. Select a page range.');
      final size=imageSize(sourceWidth:page.width*72/dpi,sourceHeight:page.height*72/dpi,
        cellWidth:cellW,cellHeight:cellH,scale:scale);
      final png=await page.toPng();
      if (!isCurrent()) throw StateError('Print cancelled or school changed.');
      encodedBytes+=png.length;
      if (encodedBytes>80*1024*1024) throw const FormatException('Print layout too large. Select fewer pages.');
      final index=cells.length;
      cells.add(pw.Positioned(
        left:margin+(index%gridSize.columns)*cellW+(cellW-size.width)/2,
        top:margin+(index~/gridSize.columns)*cellH+(cellH-size.height)/2,
        child:pw.Image(pw.MemoryImage(png),width:size.width,height:size.height,fit:pw.BoxFit.contain)));
      if (cells.length==perSheet) flush();
    }
    if (count==0 || (requested!=null && count!=requested.length)) throw const FormatException('Page range is outside the document.');
    flush();
    if (!isCurrent()) throw StateError('Print cancelled or school changed.');
    return document.save();
  }

  /// Native card/report preview is only converted to temporary print bytes
  /// when the operator presses Print; never creates a saved or synced file.
  static Future<Uint8List> fromImages(List<({Uint8List png,int width,int height})> pages,
      {bool actualSize=false}) async {
    if (pages.isEmpty) throw const FormatException('No printable pages.');
    final document=pw.Document();
    final paper=PdfPageFormat.a4;
    for (final page in pages) {
      final size=imageSize(sourceWidth:page.width*72/dpi,sourceHeight:page.height*72/dpi,
        cellWidth:paper.width-20*PdfPageFormat.mm,cellHeight:paper.height-20*PdfPageFormat.mm,
        scale:actualSize?100:null);
      document.addPage(pw.Page(pageFormat:paper,margin:pw.EdgeInsets.zero,
        build:(_)=>pw.Center(child:pw.Image(pw.MemoryImage(page.png),width:size.width,height:size.height,fit:pw.BoxFit.contain))));
    }
    return document.save();
  }
}

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';
import 'package:pdf/pdf.dart';

/// Single-page documents (including the complete front/back ID pair) fit the
/// viewport. Multi-page documents keep the normal page navigation/scrolling.
/// Raster scaling is display-only; the original PDF remains unchanged.
class FittedDocumentPreview extends StatefulWidget {
  const FittedDocumentPreview({super.key, required this.bytes, this.onPageFormat,this.showPaperOutline=false});
  final bool showPaperOutline;
  final Uint8List bytes;
  /// First-page physical dimensions from the existing preview raster, not a second render.
  final ValueChanged<PdfPageFormat?>? onPageFormat;
  @override
  State<FittedDocumentPreview> createState() => _FittedDocumentPreviewState();
}

class _FittedDocumentPreviewState extends State<FittedDocumentPreview> {
  late Future<List<Uint8List>> pages;
  int generation = 0;
  double? paperRatio;
  Future<List<Uint8List>> raster() async {
    final current = ++generation;
    final bytes = widget.bytes;
    final result = <Uint8List>[];
    var reported = false;
    try {
      await for (final page in Printing.raster(bytes, dpi: 200).take(2)) {
        if (!mounted || current != generation) return result;
        if (!reported) {
          reported = true;
          paperRatio = page.width / page.height;
          widget.onPageFormat?.call(PdfPageFormat(
            page.width * PdfPageFormat.inch / 200,
            page.height * PdfPageFormat.inch / 200));
        }
        result.add(await page.toPng());
      }
      if (!reported && mounted && current == generation) widget.onPageFormat?.call(null);
      return result;
    } catch (_) {
      if (!reported && mounted && current == generation) widget.onPageFormat?.call(null);
      rethrow;
    }
  }

  @override
  void initState() {
    super.initState();
    pages = raster();
  }

  @override
  void didUpdateWidget(covariant FittedDocumentPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bytes != widget.bytes) pages = raster();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Uint8List>>(
    future: pages,
    builder: (context, snapshot) {
      if (snapshot.hasError)
        return Center(child: Text('Preview unavailable: ${snapshot.error}'));
      if (!snapshot.hasData)
        return const Center(child: CircularProgressIndicator());
      if (snapshot.data!.isEmpty)
        return const Center(child: Text('Document has no pages.'));
      if (snapshot.data!.length == 1) {
        if (widget.showPaperOutline) {
          return ColoredBox(color: const Color(0xFF263036),
            child: Padding(padding: const EdgeInsets.all(16),
              child: Center(child: AspectRatio(
                aspectRatio: paperRatio ?? (210 / 297),
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Colors.white,
                    boxShadow: [BoxShadow(color: Colors.black38, blurRadius: 5)]),
                  child: Image.memory(snapshot.data!.first, fit: BoxFit.contain,
                    semanticLabel: 'Complete document preview', gaplessPlayback: true),
                ),
              )),
            ),
          );
        }
        return Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox.expand(
            child: ColoredBox(color: Colors.white, child: Image.memory(
              snapshot.data!.first,
              fit: BoxFit.contain,
              semanticLabel: 'Complete document preview',
              gaplessPlayback: true,
            )),
          ),
        );
      }
      return PdfPreview(
        build: (_) => widget.bytes,
        dpi: 200,
        canDebug: false,
        allowPrinting: false,
        allowSharing: false,
        useActions: false,
        canChangePageFormat: false,
        canChangeOrientation: false,
        pdfPreviewPageDecoration: const BoxDecoration(color: Colors.white),
      );
    },
  );
}

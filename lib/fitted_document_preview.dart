import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

/// Single-page documents (including the complete front/back ID pair) fit the
/// viewport. Multi-page documents keep the normal page navigation/scrolling.
/// Raster scaling is display-only; the original PDF remains unchanged.
class FittedDocumentPreview extends StatefulWidget {
  const FittedDocumentPreview({super.key, required this.bytes});
  final Uint8List bytes;
  @override
  State<FittedDocumentPreview> createState() => _FittedDocumentPreviewState();
}

class _FittedDocumentPreviewState extends State<FittedDocumentPreview> {
  late Future<List<Uint8List>> pages;
  Future<List<Uint8List>> raster() async {
    final result = <Uint8List>[];
    await for (final page in Printing.raster(widget.bytes, dpi: 200).take(2)) {
      result.add(await page.toPng());
    }
    return result;
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
        return Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox.expand(
            child: Image.memory(
              snapshot.data!.first,
              fit: BoxFit.contain,
              semanticLabel: 'Complete document preview',
              gaplessPlayback: true,
            ),
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
      );
    },
  );
}

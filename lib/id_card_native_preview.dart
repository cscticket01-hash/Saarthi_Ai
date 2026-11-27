import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'id_card_engine.dart';
import 'id_card_manifest.dart';

/// Native preview reads the same manifest and data as export. No PDF is built
/// or rasterized to display a card. Print export remains separately reviewed.
class NativeIdCardPreview extends StatefulWidget {
  const NativeIdCardPreview({
    super.key, required this.template, required this.data,
    this.images = const {}, this.backgrounds = const {}, this.qr = '',
    this.onDownload, this.onPrint, this.onPrintDocument,
  });
  final IdCardManifest template;
  final Map<String, dynamic> data;
  final Map<String, Uint8List> images, backgrounds;
  final String qr;
  final Future<void> Function()? onDownload;
  final Future<void> Function(bool frontOnly)? onPrintDocument;
  final Future<void> Function(
    List<({Uint8List png, int width, int height})> pages,
  )? onPrint;
  @override
  State<NativeIdCardPreview> createState() => _NativeIdCardPreviewState();
}

class _NativeIdCardPreviewState extends State<NativeIdCardPreview> {
  bool both = true, busy = false;
  String? error;
  final printBoundaries = {'front': GlobalKey(), 'back': GlobalKey()};

  Widget content(IdCardRegion r, Map<String, dynamic> data, String qr) {
    if (r.kind == 'image') {
      final bytes = widget.images[r.key];
      if (bytes == null) return const SizedBox.shrink();
      final photo = Image.memory(
        bytes, fit: r.fit == 'cover' ? BoxFit.cover : BoxFit.contain,
        alignment: Alignment(r.focusX * 2 - 1, r.focusY * 2 - 1),
      );
      return r.shape == 'oval' ? ClipOval(child: photo) : photo;
    }
    if (r.kind == 'qr') {
      return qr.isEmpty ? const SizedBox.shrink() : QrImageView(
        data: qr,
        padding: widget.template.id == 'student-green-blue-modern-v1'
            ? const EdgeInsets.all(4) : EdgeInsets.zero,
        backgroundColor: Colors.white,
      );
    }
    final value = r.label + (data[r.key]?.toString() ?? '');
    final align = r.align == 'center' ? TextAlign.center :
      r.align == 'right' ? TextAlign.right : TextAlign.left;
    final color = Color(0xff000000 | int.parse(r.textColor.substring(1), radix: 16));
    final availableWidth = r.contentWidth;
    final availableHeight = r.contentHeight;
    TextStyle style(double size) => TextStyle(color: color, fontSize: size);
    var size = r.fontSize;
    // Bounded fitting: do not grow beyond the reviewed manifest geometry.
    for (var i = 0; i < 150; i++) {
      final painter = TextPainter(text: TextSpan(text: value, style: style(size)),
        textAlign: align, textDirection: Directionality.of(context),
        maxLines: r.maxLines, ellipsis: r.overflow == 'ellipsis' ? '…' : null)
        ..layout(maxWidth: availableWidth);
      final fits = painter.height <= availableHeight && !painter.didExceedMaxLines;
      painter.dispose();
      if (fits || size <= r.minFontSize) break;
      size = (size - .5).clamp(r.minFontSize, r.fontSize).toDouble();
    }
    final text = Text(value, textAlign: align, style: style(size), softWrap: r.wrap,
      maxLines: r.maxLines, overflow: r.overflow == 'ellipsis' ? TextOverflow.ellipsis : TextOverflow.clip);
    return r.rotation == -90 ? RotatedBox(quarterTurns: 3, child: text) : text;
  }
  Widget side(String name, Map<String, dynamic> data, String qr) {
    final m = widget.template;
    return SizedBox(
      height: 380, child: FittedBox(fit: BoxFit.contain,
        child: RepaintBoundary(
          key: printBoundaries[name],
          child: SizedBox(width: m.width, height: m.height, child: ColoredBox(
          color: Colors.white, child: Stack(clipBehavior: Clip.hardEdge, children: [
            if (widget.backgrounds[name] != null)
              Positioned.fill(child: Image.memory(widget.backgrounds[name]!, fit: BoxFit.contain)),
            for (final r in m.regions.where((r) => r.side == name))
              Positioned(left: r.x, top: r.y, width: r.width, height: r.height,
                child: Padding(padding: EdgeInsets.all(r.padding),
                  child: ClipRect(child: content(r, data, qr)))),
          ]),
        ))),
      ),
    );
  }
  Future<void> runAction(Future<void> Function() action, String failure) async {
    if (busy) return;
    setState(() { busy = true; error = null; });
    try {
      await action();
    } catch (e) {
      if (mounted) setState(() => error = '$failure: $e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> printCards(String qr) async {
    final template = widget.template;
    if (widget.onPrintDocument != null) {
      await widget.onPrintDocument!(!both || !template.hasBack);
      return;
    }
    final ratio = template.printWidth * 300 / 25.4 / template.width;
    final sides = both && template.hasBack ? const ['front', 'back'] : const ['front'];
    final pages = <({Uint8List png, int width, int height})>[];
    for (final side in sides) {
      final boundary = printBoundaries[side]?.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) {
        throw StateError('Card side is unavailable.');
      }
      final image = await boundary.toImage(pixelRatio: ratio);
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) throw StateError('Could not render the card.');
        final png = bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
        if (qr.isNotEmpty && template.regions.any((r) => r.side == side && r.kind == 'qr') &&
            IdCardEngine.decodeFinalRaster(png) != qr) {
          throw const FormatException('Printed ID QR did not match the card.');
        }
        pages.add((png: png, width: image.width, height: image.height));
      } finally {
        image.dispose();
      }
    }
    if (mounted) await widget.onPrint!(pages);
  }
  @override
  Widget build(BuildContext context) {
    final data = IdCardEngine.normalizedInput(widget.template, widget.data);
    final qr = IdCardEngine.compactQr(widget.qr);
    final missing = widget.template.regions.where((r) => r.isRequired &&
      ((both && widget.template.hasBack) || r.side == 'front') &&
      (r.kind == 'image' ? widget.images[r.key] == null :
        r.kind == 'qr' ? qr.isEmpty : (data[r.key]?.toString().trim().isEmpty ?? true)));
    return Scaffold(appBar: AppBar(title: const Text('ID Card • Native preview')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (widget.template.hasBack) SegmentedButton<bool>(segments: const [
          ButtonSegment(value: false, label: Text('Front only')),
          ButtonSegment(value: true, label: Text('Front + back')),
        ], selected: {both}, onSelectionChanged: busy ? null : (v) => setState(() => both = v.single)),
        const SizedBox(height: 12),
        if (missing.isNotEmpty) Text('Missing template fields: ' + missing.map((r) => r.key).join(', '),
          style: TextStyle(color: Theme.of(context).colorScheme.error)),
        Column(children: [
          side('front', data, qr),
          if (both && widget.template.hasBack) ...[const SizedBox(height: 12), side('back', data, qr)],
        ]),
        const SizedBox(height: 12),
        const Text('Native visual preview. PDF export uses the verified print renderer.'),
        if (error != null) Text(error!),
        if (widget.template.id != 'student-green-blue-modern-v1' &&
            (widget.onPrint != null || widget.onPrintDocument != null))
          OutlinedButton.icon(
            onPressed: busy || missing.isNotEmpty ? null :
              () => runAction(() => printCards(qr), 'Print failed'),
            icon: const Icon(Icons.print),
            label: const Text('Print'),
          ),
        if (widget.onDownload != null)
          FilledButton.icon(
            onPressed: busy || missing.isNotEmpty ? null :
              () => runAction(widget.onDownload!, 'PDF export failed'),
            icon: const Icon(Icons.download),
            label: Text(widget.template.id == 'student-green-blue-modern-v1'
                ? 'Download ID Card' : 'Download full PDF'),
          ),
      ]));
  }
}

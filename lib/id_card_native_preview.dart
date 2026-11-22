import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'id_card_engine.dart';
import 'id_card_manifest.dart';

/// Native preview reads the same manifest and data as export. No PDF is built
/// or rasterized to display a card. Print export remains separately reviewed.
class NativeIdCardPreview extends StatefulWidget {
  const NativeIdCardPreview({
    super.key, required this.template, required this.data,
    this.images = const {}, this.backgrounds = const {}, this.qr = '',
    this.onDownload,
  });
  final IdCardManifest template;
  final Map<String, dynamic> data;
  final Map<String, Uint8List> images, backgrounds;
  final String qr;
  final Future<void> Function()? onDownload;
  @override
  State<NativeIdCardPreview> createState() => _NativeIdCardPreviewState();
}

class _NativeIdCardPreviewState extends State<NativeIdCardPreview> {
  bool both = true, busy = false;
  String? error;

  Widget content(IdCardRegion r, Map<String, dynamic> data, String qr) {
    if (r.kind == 'image') {
      final bytes = widget.images[r.key];
      return bytes == null ? const SizedBox.shrink() : Image.memory(
        bytes, fit: r.fit == 'cover' ? BoxFit.cover : BoxFit.contain,
        alignment: Alignment(r.focusX * 2 - 1, r.focusY * 2 - 1),
      );
    }
    if (r.kind == 'qr') {
      return qr.isEmpty ? const SizedBox.shrink() : QrImageView(
        data: qr, padding: EdgeInsets.zero, backgroundColor: Colors.white,
      );
    }
    final value = r.label + (data[r.key]?.toString() ?? '');
    final align = r.align == 'center' ? TextAlign.center :
      r.align == 'right' ? TextAlign.right : TextAlign.left;
    final color = Color(0xff000000 | int.parse(r.textColor.substring(1), radix: 16));
    final availableWidth = r.width - r.padding * 2;
    final availableHeight = r.height - r.padding * 2;
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
    return Text(value, textAlign: align, style: style(size), softWrap: r.wrap,
      maxLines: r.maxLines, overflow: r.overflow == 'ellipsis' ? TextOverflow.ellipsis : TextOverflow.clip);
  }
  Widget side(String name, Map<String, dynamic> data, String qr) {
    final m = widget.template;
    return SizedBox(
      height: 380, child: FittedBox(fit: BoxFit.contain,
        child: SizedBox(width: m.width, height: m.height, child: ColoredBox(
          color: Colors.white, child: Stack(clipBehavior: Clip.hardEdge, children: [
            if (widget.backgrounds[name] != null)
              Positioned.fill(child: Image.memory(widget.backgrounds[name]!, fit: BoxFit.contain)),
            for (final r in m.regions.where((r) => r.side == name))
              Positioned(left: r.x, top: r.y, width: r.width, height: r.height,
                child: Padding(padding: EdgeInsets.all(r.padding),
                  child: ClipRect(child: content(r, data, qr)))),
          ]),
        )),
      ),
    );
  }
  Future<void> download() async {
    if (busy || widget.onDownload == null) return;
    setState(() { busy = true; error = null; });
    try { await widget.onDownload!(); }
    catch (e) { if (mounted) setState(() => error = 'PDF export failed: $e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override
  Widget build(BuildContext context) {
    final data = IdCardEngine.normalizedInput(widget.template, widget.data);
    final qr = IdCardEngine.compactQr(widget.qr);
    final missing = widget.template.regions.where((r) => r.isRequired &&
      (both || r.side == 'front') &&
      (r.kind == 'image' ? widget.images[r.key] == null :
        r.kind == 'qr' ? qr.isEmpty : (data[r.key]?.toString().trim().isEmpty ?? true)));
    return Scaffold(appBar: AppBar(title: const Text('ID Card • Native preview')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SegmentedButton<bool>(segments: const [
          ButtonSegment(value: false, label: Text('Front only')),
          ButtonSegment(value: true, label: Text('Front + back')),
        ], selected: {both}, onSelectionChanged: (v) => setState(() => both = v.single)),
        const SizedBox(height: 12),
        if (missing.isNotEmpty) Text('Missing template fields: ' + missing.map((r) => r.key).join(', '),
          style: TextStyle(color: Theme.of(context).colorScheme.error)),
        side('front', data, qr),
        if (both) ...[const SizedBox(height: 12), side('back', data, qr)],
        const SizedBox(height: 12),
        const Text('Native visual preview. PDF export uses the verified print renderer.'),
        if (error != null) Text(error!),
        if (widget.onDownload != null)
          FilledButton.icon(onPressed: busy || missing.isNotEmpty ? null : download,
            icon: const Icon(Icons.download),
            label: Text(busy ? 'Generating…' : 'Download full PDF')),
      ]));
  }
}

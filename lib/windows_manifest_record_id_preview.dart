import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'id_card_engine.dart';
import 'id_card_manifest.dart';

/// Uses the actual selected ID template geometry and unmodified bundled
/// artwork. Native Flutter paints the record directly: no PDF is created,
/// rasterized, cached or uploaded when the user opens the card.
class WindowsManifestRecordIdPreview extends StatelessWidget {
  const WindowsManifestRecordIdPreview({
    super.key,
    required this.manifest,
    required this.record,
    required this.backgrounds,
    required this.images,
    this.qr = '',
  });

  final IdCardManifest manifest;
  final Map<String, dynamic> record;
  final Map<String, Uint8List> backgrounds, images;
  final String qr;

  @override
  Widget build(BuildContext context) {
    final normalized = IdCardEngine.normalizedInput(
        manifest, Map<String, dynamic>.from(record));
    final width = manifest.width;
    final height = manifest.height;
    const displayWidth = 250.0;
    final scale = displayWidth / width;

    Widget region(IdCardRegion r) {
      final innerWidth = (r.width - r.padding * 2) * scale;
      final innerHeight = (r.height - r.padding * 2) * scale;
      Widget child;
      if (r.kind == 'image') {
        final source = images[r.key];
        child = source == null || source.isEmpty
            ? const SizedBox.shrink()
            : Image.memory(source,
                width: innerWidth,
                height: innerHeight,
                fit: r.fit == 'cover' ? BoxFit.cover : BoxFit.contain,
                alignment: Alignment(
                  (r.focusX * 2) - 1,
                  (r.focusY * 2) - 1,
                ));
      } else if (r.kind == 'qr') {
        child = qr.isEmpty ? const SizedBox.shrink() : QrImageView(
            data: IdCardEngine.compactQr(qr),
            size: innerWidth < innerHeight ? innerWidth : innerHeight,
            backgroundColor: Colors.white,
            padding: EdgeInsets.zero);
      } else {
        final raw = normalized[r.key]?.toString() ?? '';
        final color = Color(int.parse(r.textColor.substring(1), radix: 16)
            | 0xFF000000);
        child = Text(
          '${r.label}$raw',
          key: ValueKey('id-data-${r.side}-${r.key}'),
          textAlign: r.align == 'center'
              ? TextAlign.center
              : r.align == 'right' ? TextAlign.right : TextAlign.left,
          softWrap: r.wrap,
          maxLines: r.maxLines,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: r.fontSize * scale,
            color: color,
            height: 1.08,
            fontWeight: FontWeight.w500,
          ),
        );
      }
      return Positioned(
        left: (r.x + r.padding) * scale,
        top: (r.y + r.padding) * scale,
        width: innerWidth,
        height: innerHeight,
        child: ClipRect(child: r.kind == 'text'
            ? Align(
                alignment: r.align == 'center'
                    ? Alignment.center
                    : r.align == 'right'
                        ? Alignment.centerRight : Alignment.centerLeft,
                child: child)
            : child),
      );
    }

    Widget side(String name) => ClipRRect(
      key: ValueKey('record-id-$name'),
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: displayWidth,
        height: height * scale,
        child: Stack(children: [
          const Positioned.fill(child: ColoredBox(color: Colors.white)),
          if (backgrounds[name] != null)
            Positioned.fill(child: Image.memory(
              backgrounds[name]!, fit: BoxFit.contain)),
          for (final r in manifest.regions.where((r) => r.side == name))
            region(r),
        ]),
      ),
    );

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Selected school template · Data-only preview (no PDF)',
          style: TextStyle(fontSize: 12)),
      const SizedBox(height: 12),
      Wrap(spacing: 12, runSpacing: 12, children: [
        side('front'), side('back'),
      ]),
    ]);
  }
}

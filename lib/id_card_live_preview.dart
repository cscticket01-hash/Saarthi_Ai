import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'id_card_manifest.dart';

/// A lightweight on-screen card. This builds Flutter widgets, NOT a PDF.
/// Use the existing IdCardEngine only for explicit export/download or the
/// independent durable publication pipeline.
class IdCardLivePreview extends StatelessWidget {
  const IdCardLivePreview({
    super.key,
    required this.template,
    required this.data,
    required this.qr,
    this.images = const {},
    this.backgrounds = const {},
  });

  final IdCardManifest template;
  final Map<String, dynamic> data;
  final String qr;
  final Map<String, Uint8List> images;
  final Map<String, Uint8List> backgrounds;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final available = constraints.maxWidth.isFinite
          ? constraints.maxWidth
          : template.width * 2 + 20;
      final sideWidth = (available - 12) / 2;
      final cardWidth = sideWidth.clamp(1.0, template.width).toDouble();
      final showRow = available >= 2 * 120 + 12;
      return Semantics(
        label: 'ID card front and back preview',
        child: showRow
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(width: cardWidth, child: _side('front')),
                  const SizedBox(width: 12),
                  SizedBox(width: cardWidth, child: _side('back')),
                ],
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(width: available, child: _side('front')),
                  const SizedBox(height: 12),
                  SizedBox(width: available, child: _side('back')),
                ],
              ),
      );
    });
  }

  Widget _side(String side) => AspectRatio(
        aspectRatio: template.width / template.height,
        child: ClipRect(
          child: LayoutBuilder(builder: (context, bounds) {
            final sx = bounds.maxWidth / template.width;
            final sy = bounds.maxHeight / template.height;
            final background = backgrounds[side];
            return Stack(children: [
              const Positioned.fill(child: ColoredBox(color: Colors.white)),
              if (background != null)
                Positioned.fill(
                  child: Image.memory(
                    background,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              for (final r in template.regions.where((r) => r.side == side))
                Positioned(
                  left: r.x * sx,
                  top: r.y * sy,
                  width: r.width * sx,
                  height: r.height * sy,
                  child: Padding(
                    padding: EdgeInsets.all(r.padding * sx),
                    child: ClipRect(child: _region(r, sx)),
                  ),
                ),
            ]);
          }),
        ),
      );

  Widget _region(IdCardRegion region, double scale) {
    if (region.kind == 'image') {
      final bytes = images[region.key];
      if (bytes == null || bytes.isEmpty) return const SizedBox.shrink();
      return Image.memory(
        bytes,
        fit: region.fit == 'cover' ? BoxFit.cover : BoxFit.contain,
        alignment: Alignment(
          region.focusX * 2 - 1,
          region.focusY * 2 - 1,
        ),
        gaplessPlayback: true,
      );
    }
    if (region.kind == 'qr') {
      return qr.isEmpty
          ? const SizedBox.shrink()
          : QrImageView(
              data: qr,
              version: QrVersions.auto,
              gapless: true,
              padding: EdgeInsets.zero,
              backgroundColor: Colors.white,
            );
    }
    final value = '${region.label}${data[region.key] ?? ''}';
    return Align(
      alignment: switch (region.align) {
        'center' => Alignment.center,
        'right' => Alignment.centerRight,
        _ => Alignment.centerLeft,
      },
      child: Text(
        value,
        textAlign: switch (region.align) {
          'center' => TextAlign.center,
          'right' => TextAlign.right,
          _ => TextAlign.left,
        },
        maxLines: region.maxLines,
        softWrap: region.wrap,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: region.fontSize * scale,
          height: 1,
          color: Color(
            0xff000000 | int.parse(region.textColor.substring(1), radix: 16),
          ),
        ),
      ),
    );
  }
}

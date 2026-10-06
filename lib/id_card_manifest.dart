/// Coordinates are design units. Print dimensions are millimetres, independent
/// of preview size. Unknown schema versions and overflowing regions fail closed.
class IdCardManifest {
  factory IdCardManifest.fromJson(Map<String, dynamic> data) {
    try {
      return IdCardManifest._parse(data);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Malformed ID manifest.');
    }
  }
  IdCardManifest._parse(Map<String, dynamic> data)
    : id = data['id'] as String,
      width = (data['canvasWidth'] as num).toDouble(),
      height = (data['canvasHeight'] as num).toDouble(),
      printWidth = (data['printWidthMm'] as num).toDouble(),
      printHeight = (data['printHeightMm'] as num).toDouble(),
      regions = [
        for (final r in data['regions'] as List)
          IdCardRegion.fromJson(Map<String, dynamic>.from(r as Map)),
      ] {
    if (data['version'] != 1 ||
        id.isEmpty ||
        [
          width,
          height,
          printWidth,
          printHeight,
        ].any((n) => !n.isFinite || n <= 0) ||
        width > 10000 ||
        height > 10000 ||
        printWidth > 150 ||
        printHeight > 150) {
      throw const FormatException('Invalid ID template dimensions/version.');
    }
    if ((width / height - printWidth / printHeight).abs() > 0.01) {
      throw const FormatException(
        'ID artwork and physical aspect ratio differ.',
      );
    }
    final keys = <String>{};
    for (final r in regions) {
      if (!keys.add('${r.side}:${r.key}') ||
          r.x + r.width > width ||
          r.y + r.height > height) {
        throw const FormatException(
          'Duplicate or overflowing ID template region.',
        );
      }
    }
    for (final r in regions) {
      if (r.allowOverlapWith.any(
        (key) =>
            key == r.key ||
            !regions.any((other) => other.side == r.side && other.key == key),
      )) {
        throw const FormatException("Invalid overlap exception reference.");
      }
    }
    for (var i = 0; i < regions.length; i++) {
      final r = regions[i];
      if (r.kind == 'qr' &&
          (r.width < 8 ||
              r.height < 8 ||
              (r.width < r.height ? r.width : r.height) * printWidth / width <
                  12)) {
        throw const FormatException('ID QR region is too small.');
      }
      for (final other in regions.skip(i + 1)) {
        final overlaps =
            r.side == other.side &&
            r.x < other.x + other.width &&
            other.x < r.x + r.width &&
            r.y < other.y + other.height &&
            other.y < r.y + r.height;
        if (overlaps &&
            !(r.allowOverlapWith.contains(other.key) &&
                other.allowOverlapWith.contains(r.key))) {
          throw FormatException(
            'Overlapping ID regions: ${r.key} / ${other.key}',
          );
        }
      }
    }
    if (!regions.any((r) => r.side == 'front') ||
        !regions.any((r) => r.side == 'back')) {
      throw const FormatException('ID template must expose front and back.');
    }
  }
  final String id;
  final double width, height, printWidth, printHeight;
  final List<IdCardRegion> regions;
}

class IdCardRegion {
  IdCardRegion.fromJson(Map<String, dynamic> data)
    : key = data['key'] as String,
      side = data['side'] as String,
      kind = data['kind'] as String,
      fit = data['fit']?.toString() ?? 'contain',
      align = data['align']?.toString() ?? 'left',
      label = data['label']?.toString() ?? '',
      x = (data['x'] as num).toDouble(),
      y = (data['y'] as num).toDouble(),
      width = (data['width'] as num).toDouble(),
      height = (data['height'] as num).toDouble(),
      fontSize = (data['fontSize'] as num? ?? 12).toDouble(),
      minFontSize = (data['minFontSize'] as num? ?? 8).toDouble(),
      wrap = data['wrap'] == true,
      maxLines = (data['maxLines'] as int? ?? 1),
      overflow = data['overflow']?.toString() ?? 'ellipsis',
      focusX = (data['focusX'] as num? ?? .5).toDouble(),
      focusY = (data['focusY'] as num? ?? .35).toDouble(),
      allowOverlapWith = List<String>.from(
        data['allowOverlapWith'] as List? ?? const [],
      ) {
    if (key.isEmpty ||
        !{'front', 'back'}.contains(side) ||
        !{'text', 'image', 'qr'}.contains(kind) ||
        !{'contain', 'cover'}.contains(fit) ||
        !{'left', 'center', 'right'}.contains(align) ||
        [x, y, width, height, fontSize].any((n) => !n.isFinite) ||
        x < 0 ||
        y < 0 ||
        width <= 0 ||
        height <= 0 ||
        !minFontSize.isFinite ||
        minFontSize < 6 ||
        minFontSize > fontSize ||
        maxLines < 1 ||
        maxLines > 12 ||
        (!wrap && maxLines != 1) ||
        !{'ellipsis', 'error'}.contains(overflow) ||
        !focusX.isFinite ||
        !focusY.isFinite ||
        focusX < 0 ||
        focusX > 1 ||
        focusY < 0 ||
        focusY > 1 ||
        ({'logo', 'seal', 'signature'}.contains(key) && fit != 'contain') ||
        fontSize < 4 ||
        fontSize > 72) {
      throw const FormatException('Invalid ID region.');
    }
  }
  final String key, side, kind, fit, align, label;
  final double x, y, width, height, fontSize, minFontSize, focusX, focusY;
  final bool wrap;
  final int maxLines;
  final String overflow;
  final List<String> allowOverlapWith;
}

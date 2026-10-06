import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Runs in an isolate. The target is subordinate to the quality floor; the
/// caller retains original bytes separately and displays the actual output size.
class DocumentProcessingEngine {
  static const sourceLimit = 50 * 1024 * 1024;
  static const setTarget = 300 * 1024;
  static Map<String, dynamic> process(Map<String, dynamic> input) {
    final bytes = input['bytes'] as Uint8List;
    if (bytes.isEmpty || bytes.length > sourceLimit)
      throw const FormatException('Source exceeds document safety limit.');
    final decoder = img.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width * info.height > 20000000 ||
        decoder!.numFrames() != 1) {
      throw const FormatException(
        'Unsupported image or decoded image exceeds 20 megapixels.',
      );
    }
    final decoded = decoder!.decodeFrame(0);
    if (decoded == null)
      throw const FormatException('Image cannot be decoded.');
    var image = img.bakeOrientation(decoded);
    final longest = math.max(image.width, image.height);
    if (longest > 2200)
      image = img.copyResize(
        image,
        width: image.width >= image.height ? 2200 : null,
        height: image.height > image.width ? 2200 : null,
        interpolation: img.Interpolation.average,
      );
    final detected = _paperCorners(image);
    bool corrected = false;
    if (detected != null) {
      image = _rectify(image, detected);
      corrected = true;
    }
    final deskew = _textAngle(image);
    if (deskew.abs() >= 0.5) {
      image.backgroundColor = img.ColorRgb8(255, 255, 255);
      image = img.copyRotate(
        image,
        angle: -deskew,
        interpolation: img.Interpolation.linear,
      );
    }
    for (final pixel in image) {
      pixel.r = ((pixel.r - 128) * 1.025 + 128).clamp(0, 255);
      pixel.g = ((pixel.g - 128) * 1.025 + 128).clamp(0, 255);
      pixel.b = ((pixel.b - 128) * 1.025 + 128).clamp(0, 255);
    }
    // Mild local sharpening; do not threshold text/stamps into binary pixels.
    image = img.convolution(
      image,
      filter: [0, -1, 0, -1, 5, -1, 0, -1, 0],
      amount: 0.12,
    );
    // Re-encoding strips EXIF/GPS and unrelated source metadata.
    image.exif = img.ExifData();
    image.textData = null;
    image.iccProfile = null;
    final highQuality = Uint8List.fromList(img.encodeJpg(image, quality: 94));
    final target = (input['targetBytes'] as num? ?? setTarget ~/ 8).toInt();
    var optimized = highQuality;
    var quality = 94;
    for (final q in [88, 82, 78]) {
      if (optimized.length <= target) break;
      optimized = Uint8List.fromList(img.encodeJpg(image, quality: q));
      quality = q;
    }
    // Keep at least a 1600px long edge when present in the original. Never
    // reduce to thumbnail dimensions just to meet the storage target.
    if (optimized.length > target &&
        math.max(image.width, image.height) > 1600) {
      final smaller = img.copyResize(
        image,
        width: image.width >= image.height ? 1600 : null,
        height: image.height > image.width ? 1600 : null,
        interpolation: img.Interpolation.average,
      );
      optimized = Uint8List.fromList(img.encodeJpg(smaller, quality: 78));
      quality = 78;
    }
    return {
      'optimized': optimized,
      'highQuality': highQuality,
      'quality': quality,
      'targetMet': optimized.length <= target,
      'actualBytes': optimized.length,
      'perspectiveCorrected': corrected,
      'deskewDegrees': deskew,
      'width': image.width,
      'height': image.height,
      'cleanupStatus': corrected
          ? 'Detected paper boundary corrected'
          : 'No confident boundary; full image preserved',
    };
  }

  static double _textAngle(img.Image source) {
    final sample = img.copyResize(
      source,
      width: source.width >= source.height ? 500 : null,
      height: source.height > source.width ? 500 : null,
    );
    final dark = <img.Point>[];
    var colored = 0;
    for (var y = 8; y < sample.height - 8; y += 2)
      for (var x = 8; x < sample.width - 8; x += 2) {
        final p = sample.getPixel(x, y), light = (p.r + p.g + p.b) / 3;
        if (light < 100) dark.add(img.Point(x, y));
        if (math.max(p.r, math.max(p.g, p.b)) -
                math.min(p.r, math.min(p.g, p.b)) >
            40)
          colored++;
      }
    // Text-like scans only; portraits and rich colour photos are not rotated.
    if (dark.length < 100 ||
        dark.length > sample.width * sample.height * 0.12 ||
        colored > sample.width * sample.height * 0.02)
      return 0;
    double score(double angle) {
      final r = angle * math.pi / 180,
          rows = List<int>.filled(sample.height + sample.width, 0);
      for (final p in dark) {
        final y =
            (p.y * math.cos(r) - p.x * math.sin(r)).round() + sample.width ~/ 2;
        if (y >= 0 && y < rows.length) rows[y]++;
      }
      return rows.fold<double>(0, (sum, n) => sum + n * n);
    }

    final baseline = score(0);
    var best = baseline, angle = 0.0;
    for (var step = -8; step <= 8; step++) {
      final candidate = step / 2, value = score(candidate);
      if (value > best) {
        best = value;
        angle = candidate;
      }
    }
    return best > baseline * 1.18 ? angle : 0;
  }

  /// Conservative bright-paper detection against a darker surrounding surface.
  /// Ambiguous/background-free scans retain all content instead of guessing.
  static List<img.Point>? _paperCorners(img.Image source) {
    final sample = img.copyResize(
      source,
      width: source.width >= source.height ? 500 : null,
      height: source.height > source.width ? 500 : null,
    );
    double light(int x, int y) {
      final p = sample.getPixel(x, y);
      return (p.r + p.g + p.b) / 3;
    }

    final border = <double>[];
    for (var x = 0; x < sample.width; x += 8) {
      border.add(light(x, 0));
      border.add(light(x, sample.height - 1));
    }
    for (var y = 0; y < sample.height; y += 8) {
      border.add(light(0, y));
      border.add(light(sample.width - 1, y));
    }
    border.sort();
    final background = border[border.length ~/ 2];
    if (background > 190) return null;
    final points = <img.Point>[];
    for (var y = 1; y < sample.height - 1; y += 2)
      for (var x = 1; x < sample.width - 1; x += 2) {
        if (light(x, y) > math.max(205, background + 45))
          points.add(img.Point(x, y));
      }
    if (points.length < sample.width * sample.height * 0.12) return null;
    img.Point extreme(num Function(img.Point) score, bool minimum) =>
        points.reduce(
          (a, b) =>
              (minimum ? score(a) < score(b) : score(a) > score(b)) ? a : b,
        );
    final p = [
      extreme((p) => p.x + p.y, true),
      extreme((p) => p.x - p.y, false),
      extreme((p) => p.x + p.y, false),
      extreme((p) => p.x - p.y, true),
    ];
    double area = 0;
    for (var i = 0; i < 4; i++) {
      final a = p[i], b = p[(i + 1) % 4];
      area += a.x * b.y - b.x * a.y;
    }
    if (area.abs() / 2 < sample.width * sample.height * 0.30) return null;
    // Preserve a small margin so border text/seals are not shaved off.
    final cx = p.fold<double>(0, (v, p) => v + p.x.toDouble()) / 4,
        cy = p.fold<double>(0, (v, p) => v + p.y.toDouble()) / 4;
    return p
        .map(
          (p) => img.Point(
            (cx + (p.x - cx) * 1.02).clamp(0, sample.width - 1) *
                source.width /
                sample.width,
            (cy + (p.y - cy) * 1.02).clamp(0, sample.height - 1) *
                source.height /
                sample.height,
          ),
        )
        .toList();
  }

  static img.Image _rectify(img.Image source, List<img.Point> p) {
    double distance(img.Point a, img.Point b) =>
        math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));
    final w = math.max(distance(p[0], p[1]), distance(p[3], p[2])).round();
    final h = math.max(distance(p[0], p[3]), distance(p[1], p[2])).round();
    if (w < 200 || h < 200) return source;
    final x0 = p[0].x,
        y0 = p[0].y,
        x1 = p[1].x,
        y1 = p[1].y,
        x2 = p[2].x,
        y2 = p[2].y,
        x3 = p[3].x,
        y3 = p[3].y;
    final dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3;
    final dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3;
    final determinant = dx1 * dy2 - dx2 * dy1;
    if (determinant.abs() < 0.001) return source;
    final g = (dx3 * dy2 - dx2 * dy3) / determinant,
        hp = (dx1 * dy3 - dx3 * dy1) / determinant;
    final a = x1 - x0 + g * x1,
        b = x3 - x0 + hp * x3,
        d = y1 - y0 + g * y1,
        e = y3 - y0 + hp * y3;
    final result = img.Image(width: w, height: h, numChannels: 3);
    for (var y = 0; y < h; y++)
      for (var x = 0; x < w; x++) {
        final u = x / (w - 1), v = y / (h - 1), den = g * u + hp * v + 1;
        final sx = ((a * u + b * v + x0) / den)
            .clamp(0, source.width - 1)
            .toDouble();
        final sy = ((d * u + e * v + y0) / den)
            .clamp(0, source.height - 1)
            .toDouble();
        result.setPixel(
          x,
          y,
          source.getPixelInterpolate(
            sx,
            sy,
            interpolation: img.Interpolation.linear,
          ),
        );
      }
    return result;
  }
}

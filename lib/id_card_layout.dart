import 'school_image_input.dart';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:qr/qr.dart';

class FittedIdText {
  FittedIdText(this.text, this.fontSize, this.truncated);
  final String text;
  final double fontSize;
  final bool truncated;
}

/// Deterministic region fitting shared by manifest and compatibility templates.
class IdCardLayout {
  static FittedIdText fitText(
    String text, {
    required double width,
    required double height,
    required double Function(String) measure,
    double fontSize = 12,
    double minFontSize = 8,
    bool wrap = false,
    int maxLines = 1,
    String overflow = 'ellipsis',
  }) {
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      throw const FormatException('Text region has no available space.');
    }
    if (!fontSize.isFinite ||
        !minFontSize.isFinite ||
        minFontSize <= 0 ||
        fontSize < minFontSize ||
        maxLines < 1 ||
        (!wrap && maxLines != 1) ||
        !{'ellipsis', 'error'}.contains(overflow)) {
      throw const FormatException('Invalid text fitting rules.');
    }
    final value = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    List<String> lines(double size) {
      if (!wrap) return [value];
      final result = <String>[];
      var current = '';
      for (final word in value.split(' ')) {
        if (measure(word) * size <= width) {
          final candidate = current.isEmpty ? word : '$current $word';
          if (current.isNotEmpty && measure(candidate) * size > width) {
            result.add(current);
            current = word;
          } else {
            current = candidate;
          }
        } else {
          if (current.isNotEmpty) {
            result.add(current);
            current = '';
          }
          for (final rune in word.runes) {
            final char = String.fromCharCodes([rune]);
            if (current.isNotEmpty && measure('$current$char') * size > width) {
              result.add(current);
              current = '';
            }
            current += char;
          }
        }
      }
      if (current.isNotEmpty) result.add(current);
      return result.isEmpty ? [''] : result;
    }

    // Include the exact manifest minimum even when it is not a quarter-point
    // step below the preferred size. Otherwise readable text can be needlessly
    // truncated despite fitting at the requested minimum.
    final sizes = <double>[];
    for (double size = fontSize; size > minFontSize; size -= .25) {
      sizes.add(size);
    }
    sizes.add(minFontSize);
    for (final size in sizes) {
      final parts = lines(size);
      if (parts.length <= maxLines &&
          parts.length * size * 1.25 <= height &&
          parts.every((line) => measure(line) * size <= width)) {
        return FittedIdText(parts.join('\n'), size, false);
      }
    }
    if (overflow == 'error')
      throw const FormatException(
        'Text cannot fit at the readable minimum font size.',
      );
    final limit = math.min(maxLines, (height / (minFontSize * 1.25)).floor());
    if (limit < 1 || measure('…') * minFontSize > width) {
      throw const FormatException(
        'Text region is too small for readable content.',
      );
    }
    final parts = lines(minFontSize).take(limit).toList();
    var last = parts.last;
    while (last.isNotEmpty && measure('$last…') * minFontSize > width) {
      last = String.fromCharCodes(last.runes.take(last.runes.length - 1));
    }
    parts[parts.length - 1] = '$last…';
    return FittedIdText(parts.join('\n'), minFontSize, true);
  }

  static pw.Widget text(
    String value, {
    required pw.Font font,
    double fontSize = 12,
    double minFontSize = 8,
    bool wrap = false,
    int maxLines = 1,
    String overflow = 'error',
    PdfColor color = PdfColors.black,
    pw.TextAlign align = pw.TextAlign.left,
  }) =>
      pw.LayoutBuilder(
        builder: (context, constraints) {
          final pdfFont = font.getFont(context);
          final width = constraints?.maxWidth ?? double.infinity,
              height = constraints?.maxHeight ?? double.infinity;
          // Compatibility labels in unconstrained table cells keep their normal
          // style; every positioned ID field has finite template bounds.
          if (!width.isFinite || !height.isFinite) {
            return pw.Text(
              value,
              style: pw.TextStyle(font: font, fontSize: fontSize, color: color),
              textAlign: align,
            );
          }
          final fitted = fitText(
            value,
            width: width,
            height: height,
            measure: (s) {
              final m = pdfFont.stringMetrics(s);
              return math.max(m.width, m.advanceWidth);
            },
            fontSize: fontSize,
            minFontSize: math.min(minFontSize, fontSize),
            wrap: wrap,
            maxLines: maxLines,
            overflow: overflow,
          );
          return pw.Align(
            alignment: align == pw.TextAlign.center
                ? pw.Alignment.center
                : align == pw.TextAlign.right
                    ? pw.Alignment.centerRight
                    : pw.Alignment.centerLeft,
            child: pw.Text(
              fitted.text,
              textAlign: align,
              style: pw.TextStyle(
                font: font,
                fontSize: fitted.fontSize,
                color: color,
              ),
            ),
          );
        },
      );

  static Uint8List prepareImage(
    Uint8List bytes, {
    required double aspect,
    bool cover = false,
    double focusX = .5,
    double focusY = .35,
  }) {
    SchoolImageInput.validate(bytes);
    try {
      return _prepareImage(bytes, aspect: aspect, cover: cover, focusX: focusX, focusY: focusY);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('ID image cannot be safely decoded.');
    }
  }

  static Uint8List _prepareImage(Uint8List bytes, {
    required double aspect, bool cover = false, double focusX = .5, double focusY = .35,
  }) {
    if (bytes.length < 12 || bytes.length > 50 * 1024 * 1024)
      throw const FormatException("ID image is empty, truncated or too large.");
    if (!aspect.isFinite ||
        aspect <= 0 ||
        !focusX.isFinite ||
        !focusY.isFinite ||
        focusX < 0 ||
        focusX > 1 ||
        focusY < 0 ||
        focusY > 1) {
      throw const FormatException('Invalid photo fitting rules.');
    }
    final decoder = img.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null ||
        info.width <= 0 ||
        info.height <= 0 ||
        info.width * info.height > 20000000) {
      throw const FormatException(
        'ID image is invalid or exceeds 20 megapixels.',
      );
    }
    var image = decoder!.decodeFrame(0);
    if (image == null)
      throw const FormatException('ID image cannot be decoded.');
    image = img.bakeOrientation(image);
    if (cover) {
      var w = image.width, h = image.height;
      if (w / h > aspect) {
        w = (h * aspect).round();
      } else {
        h = (w / aspect).round();
      }
      w = w.clamp(1, image.width);
      h = h.clamp(1, image.height);
      image = img.copyCrop(
        image,
        x: ((image.width - w) * focusX).round(),
        y: ((image.height - h) * focusY).round(),
        width: w,
        height: h,
      );
    }
    if (math.max(image.width, image.height) > 1600) {
      final ratio = 1600 / math.max(image.width, image.height);
      image = img.copyResize(
        image,
        width: (image.width * ratio).round(),
        height: (image.height * ratio).round(),
      );
    }
    return Uint8List.fromList(img.encodePng(image));
  }

  static pw.Widget image(
    Uint8List bytes, {
    bool cover = false,
    double focusX = .5,
    double focusY = .35,
  }) =>
      pw.LayoutBuilder(
        builder: (_, bounds) {
          if (bounds == null)
            throw const FormatException("ID image has no template bounds.");
          if (!bounds.maxWidth.isFinite ||
              !bounds.maxHeight.isFinite ||
              bounds.maxWidth <= 0 ||
              bounds.maxHeight <= 0) {
            throw const FormatException(
                'ID image region has invalid dimensions.');
          }
          final prepared = prepareImage(
            bytes,
            aspect: bounds.maxWidth / bounds.maxHeight,
            cover: cover,
            focusX: focusX,
            focusY: focusY,
          );
          return pw.ClipRect(
            child: pw.Image(pw.MemoryImage(prepared), fit: pw.BoxFit.contain),
          );
        },
      );

  static double qrPadding(String value, double side, {double? physicalSideMm}) {
    final modules = QrCode.fromData(
      data: value,
      errorCorrectLevel: QrErrorCorrectLevel.L,
    ).moduleCount;
    // Compact credentials in preserved CR80 artwork may use 0.15 mm modules.
    // This is only the geometry floor: acceptance still requires decoding the
    // final composed 300-DPI export, not just constructing the QR widget.
    if (physicalSideMm != null && physicalSideMm / (modules + 8) < .15) {
      throw const FormatException(
        'QR region is too small for this payload. Use a larger QR region or a shorter verified link.',
      );
    }
    return side *
        4 /
        (modules + 8); // Four-module white quiet zone on each side.
  }

  static pw.Widget qr(String value, {double? millimetresPerUnit}) =>
      pw.LayoutBuilder(
        builder: (_, bounds) {
          if (bounds == null)
            throw const FormatException("QR has no template bounds.");
          final side = math.min(bounds.maxWidth, bounds.maxHeight);
          if (!side.isFinite || side <= 0)
            throw const FormatException('Invalid QR region.');
          final padding = qrPadding(
            value,
            side,
            physicalSideMm:
                millimetresPerUnit == null ? null : side * millimetresPerUnit,
          );
          return pw.Center(
            child: pw.SizedBox(
              width: side,
              height: side,
              child: pw.Container(
                color: PdfColors.white,
                padding: pw.EdgeInsets.all(padding),
                child: pw.BarcodeWidget(
                  barcode: pw.Barcode.qrCode(),
                  data: value,
                  width: side - padding * 2,
                  height: side - padding * 2,
                ),
              ),
            ),
          );
        },
      );
}

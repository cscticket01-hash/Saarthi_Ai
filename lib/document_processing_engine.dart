import 'school_image_input.dart';

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Runs in an isolate. The target is subordinate to the quality floor; the
/// caller retains original bytes separately and displays the actual output size.
class DocumentProcessingEngine {
  static const sourceLimit = 50 * 1024 * 1024;
  static const photoTarget = 80 * 1024;
  static const portraitTarget = 40 * 1024;
  static const brandingTarget = 30 * 1024;

  /// Losslessly optimize the normalized PNG artwork used by TemplateForge.
  /// Unlike portrait/photo compression, print backgrounds must retain every
  /// pixel, including fine text, stamps and transparent edges. This runs in
  /// an isolate before the existing verified school-Drive publication.
  /// A larger, non-identical or color-profiled re-encode keeps source bytes.
  static Map<String, dynamic> templateArtworkUpload(Map<String, dynamic> input) {
    final source = input['bytes'] as Uint8List;
    if (source.isEmpty || source.length > 20 * 1024 * 1024) {
      throw const FormatException('Template artwork exceeds the 20 MiB safe upload limit.');
    }
    try {
    final decoder = img.PngDecoder();
    final info = decoder.startDecode(source);
    if (info == null || info.width <= 0 || info.height <= 0 ||
        info.width * info.height > 20000000 || decoder.numFrames() != 1) {
      throw const FormatException('Template artwork must be a valid single-frame PNG.');
    }
    final original = decoder.decodeFrame(0);
    if (original == null) {
      throw const FormatException('Template artwork cannot be decoded.');
    }
    Uint8List result = source;
    // Re-encoding an ICC-profiled design could change its printed colours.
    if (original.iccProfile == null) {
      final candidate = Uint8List.fromList(img.encodePng(original, level: 9));
      if (candidate.length < source.length) {
        final verified = img.decodePng(candidate);
        if (verified != null && verified.width == original.width &&
            verified.height == original.height) {
          var identicalPixels = true;
          for (var y = 0; y < original.height && identicalPixels; y++) {
            for (var x = 0; x < original.width; x++) {
              final before = original.getPixel(x, y);
              final after = verified.getPixel(x, y);
              if (before.r != after.r || before.g != after.g ||
                  before.b != after.b || before.a != after.a) {
                identicalPixels = false;
                break;
              }
            }
          }
          if (identicalPixels) result = candidate;
        }
      }
    }
    return {
      'optimized': result, 'mimeType': 'image/png',
      'originalBytes': source.length, 'actualBytes': result.length,
      'lossless': true, 'pixelsVerified': true,
      'reusedSource': identical(result, source),
    };
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Template artwork cannot be safely decoded.');
    }
  }

  /// Optimize school logo, seal and signature for a strict 30 KB upload.
  /// Unlike the document-scanner pathway, transparent ink is never flattened
  /// onto white JPEG. This protects transparent signatures and round seals.
  /// No generated output is accepted unless the exact encoded bytes fit.
  static Map<String, dynamic> brandingUpload(Map<String, dynamic> input) {
    final source = input['bytes'] as Uint8List;
    SchoolImageInput.validate(source);
    final decoder = img.findDecoderForData(source);
    final info = decoder?.startDecode(source);
    if (info == null || info.width <= 0 || info.height <= 0 ||
        info.width * info.height > 20000000 || decoder!.numFrames() != 1) {
      throw const FormatException('Branding image is invalid or exceeds 20 megapixels.');
    }
    final decoded = decoder!.decodeFrame(0);
    if (decoded == null) {
      throw const FormatException('Cannot decode school branding image.');
    }
    final oriented = img.bakeOrientation(decoded).convert(numChannels: 4);
    oriented.exif = img.ExifData();
    oriented.textData = null;
    oriented.iccProfile = null;
    var hasTransparency = false;
    for (final pixel in oriented) {
      if (pixel.a < 255) {
        hasTransparency = true;
        break;
      }
    }
    final longest = math.max(oriented.width, oriented.height);
    final steps = <int>[
      longest,
      for (final edge in [1024, 768, 640, 512, 448, 384, 320, 256])
        if (longest > edge) edge,
    ].toSet().toList();
    for (final edge in steps) {
      final frame = edge == longest ? oriented : img.copyResize(
        oriented,
        width: oriented.width >= oriented.height ? edge : null,
        height: oriented.height > oriented.width ? edge : null,
        interpolation: img.Interpolation.average,
      );
      final png = Uint8List.fromList(img.encodePng(frame, level: 9));
      if (png.length <= brandingTarget) {
        return {
          'optimized': png, 'mimeType': 'image/png', 'targetMet': true,
          'actualBytes': png.length, 'originalBytes': source.length,
          'targetBytes': brandingTarget, 'width': frame.width,
          'height': frame.height, 'transparencyPreserved': hasTransparency,
          'quality': 'lossless PNG at selected resolution',
        };
      }
      if (!hasTransparency) {
        final rgb = frame.convert(numChannels: 3);
        for (final quality in [92, 86, 80]) {
          final jpeg = Uint8List.fromList(img.encodeJpg(rgb, quality: quality));
          if (jpeg.length <= brandingTarget) {
            return {
              'optimized': jpeg, 'mimeType': 'image/jpeg', 'targetMet': true,
              'actualBytes': jpeg.length, 'originalBytes': source.length,
              'targetBytes': brandingTarget, 'width': frame.width,
              'height': frame.height, 'transparencyPreserved': true,
              'quality': quality,
            };
          }
        }
      }
    }
    throw const FormatException(
      'School logo, seal or signature cannot fit 30 KB without losing '
      'important detail or transparency. Original retained; use a clearer asset.',
    );
  }

  /// Upload contract for profile photos. Never silently send an oversized
  /// fallback, or lower the quality floor merely to claim the budget passed.
  static Map<String, dynamic> portraitUpload(Map<String, dynamic> input) {
    final result = process({...input, 'kind': 'portrait', 'targetBytes': portraitTarget});
    final bytes = result['optimized'] as Uint8List;
    if (result['targetMet'] != true || bytes.length > portraitTarget) {
      throw const FormatException(
        'Photo cannot fit 40 KB safely. Original retained; please choose a clearer portrait.',
      );
    }
    return result;
  }
  // Retain the existing eight-document aggregate measurement contract.
  static const setTarget = 8 * photoTarget;
  static Map<String, dynamic> process(Map<String, dynamic> input) {
    SchoolImageInput.validate(input['bytes'] as Uint8List);
    try {
      return _process(input);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('Image cannot be safely decoded.');
    }
  }

  static Map<String, dynamic> _process(Map<String, dynamic> input) {
    final portrait = input['kind'] == 'portrait';
    final pdfCompression = input['kind'] == 'pdfCompression';
    final bytes = input['bytes'] as Uint8List;
    if (bytes.length < 12 || bytes.length > sourceLimit)
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
    // JPEG decoding already applies and removes its EXIF orientation. Read
    // only the bounded source orientation before stripping its metadata, so
    // retained compressed samples still carry the original display transform.
    final sourceOrientation =
        _jpegSourceOrientation(bytes) ?? decoded.exif.imageIfd.orientation ?? 1;
    final orientedSource = img.bakeOrientation(decoded);
    var image = orientedSource.convert(
      format: img.Format.uint8,
      numChannels: 4,
    );
    // PNG/PDF raster transparency must become white paper, not black JPEG ink.
    for (final pixel in image) {
      final alpha = pixel.a / 255;
      pixel.r = pixel.r * alpha + 255 * (1 - alpha);
      pixel.g = pixel.g * alpha + 255 * (1 - alpha);
      pixel.b = pixel.b * alpha + 255 * (1 - alpha);
      pixel.a = 255;
    }
    image = image.convert(numChannels: 3);

    final longest = math.max(image.width, image.height);
    final maxEdge = portrait ? 1280 : 2200;
    if (longest > maxEdge)
      image = img.copyResize(
        image,
        width: image.width >= image.height ? maxEdge : null,
        height: image.height > image.width ? maxEdge : null,
        interpolation: img.Interpolation.average,
      );
    // Crop coordinates refer to the EXIF-oriented original, before rotation.
    final edit = portrait || pdfCompression ? null : input['manualEdit'];
    final quad = portrait || pdfCompression ? null : input['manualCorners'];
    final filter = portrait ? 'auto' : pdfCompression ? 'original' : input['scanFilter'] ?? 'auto';
    final brightness = portrait || pdfCompression ? 0.0 : (input['brightness'] as num? ?? 0).toDouble();
    final contrast = portrait || pdfCompression ? 0.0 : (input['contrast'] as num? ?? 0).toDouble();
    if (!{'auto', 'original', 'lightText', 'grayscale', 'whiteboard'}.contains(filter) ||
        !brightness.isFinite || !contrast.isFinite ||
        brightness.abs() > 0.4 || contrast.abs() > 0.5) {
      throw const FormatException('Invalid scan filter or adjustment.');
    }
    final adjusted = filter != 'auto' || brightness != 0 || contrast != 0;
    List<img.Point>? manualPoints;
    if (quad != null) {
      if (quad is! List || quad.length != 8 ||
          quad.any((v) => v is! num || !v.isFinite || v < 0 || v > 1)) {
        throw const FormatException('Invalid four-corner crop.');
      }
      final v = quad.cast<num>();
      manualPoints = [
        for (var i = 0; i < 8; i += 2)
          img.Point(v[i] * (image.width - 1), v[i + 1] * (image.height - 1)),
      ];
      for (var i = 0; i < 4; i++) {
        final a = manualPoints[i], b = manualPoints[(i + 1) % 4],
            c = manualPoints[(i + 2) % 4];
        if ((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) <= 0) {
          throw const FormatException('Keep the crop corners in clockwise order.');
        }
      }
      if (edit == null) throw const FormatException('Manual crop requires explicit edit settings.');
    }
    var manualCrop = false;
    var rotation = 0;
    if (edit != null) {
      if (edit is! List || edit.length != 5 ||
          edit.any((v) => v is! num || !v.isFinite)) {
        throw const FormatException('Invalid manual scan correction.');
      }
      final values = edit.cast<num>();
      final left = values[0], top = values[1], right = values[2], bottom = values[3];
      if (left < 0 || top < 0 || right > 1 || bottom > 1 ||
          right - left < 0.1 || bottom - top < 0.1 ||
          !{0, 90, 180, 270}.contains(values[4])) {
        throw const FormatException('Invalid manual crop or rotation.');
      }
      final x = (left * image.width).floor();
      final y = (top * image.height).floor();
      final w = (right * image.width).ceil() - x;
      final h = (bottom * image.height).ceil() - y;
      if (w < 16 || h < 16) {
        throw const FormatException('Manual crop is too small.');
      }
      manualCrop = x != 0 || y != 0 || w != image.width || h != image.height;
      if (manualPoints != null) {
        final correctedImage = _rectify(image, manualPoints);
        if (identical(correctedImage, image)) {
          throw const FormatException('Crop is too small or corners are not valid.');
        }
        image = correctedImage;
        manualCrop = true;
      } else if (manualCrop) {
        image = img.copyCrop(image, x: x, y: y, width: w, height: h);
      }
      rotation = values[4].toInt();
    } else if (!portrait && !pdfCompression && {90, 180, 270}.contains(input['autoRotation']) &&
        sourceOrientation == 1) {
      rotation = input['autoRotation'] as int;
    }
    if (rotation != 0) image = img.copyRotate(image, angle: rotation);
    final detected = portrait || pdfCompression || edit != null ? null : _paperCorners(image);
    bool corrected = false;
    if (detected != null) {
      final rectified = _rectify(image, detected);
      corrected = !identical(image, rectified);
      image = rectified;
    }
    final deskew = portrait || pdfCompression || edit != null ? 0.0 : _textAngle(image);
    if (deskew.abs() >= 0.5) {
      image.backgroundColor = img.ColorRgb8(255, 255, 255);
      image = img.copyRotate(
        image,
        angle: -deskew,
        interpolation: img.Interpolation.linear,
      );
    }
    if (filter == 'grayscale' || filter == 'whiteboard') {
      image = img.grayscale(image);
    }
    final factor = (filter == 'original' ? 1.0 : filter == 'lightText' ? 1.16 :
        filter == 'whiteboard' ? 1.22 : 1.025) * (1 + contrast);
    final lift = brightness * 255 + (filter == 'whiteboard' ? 12 : filter == 'lightText' ? 6 : 0);
    for (final pixel in image) {
      pixel.r = ((pixel.r - 128) * factor + 128 + lift).clamp(0, 255);
      pixel.g = ((pixel.g - 128) * factor + 128 + lift).clamp(0, 255);
      pixel.b = ((pixel.b - 128) * factor + 128 + lift).clamp(0, 255);
    }
    // Mild sharpening; never erase text, seals or signatures by thresholding.
    if (filter != 'original') {
      image = img.convolution(
        image,
        filter: [0, -1, 0, -1, 5, -1, 0, -1, 0],
        amount: 0.12,
      );
    }
    // Retain normalized source pixels as a fallback if sharpening expands a
    // previously compressed upload. Orientation and transparency were baked.
    // Re-encoding strips EXIF/GPS and unrelated source metadata.
    image.exif = img.ExifData();
    image.textData = null;
    image.iccProfile = null;
    final highQuality = Uint8List.fromList(img.encodeJpg(image, quality: 94));
    final target =
        (input['targetBytes'] as num? ??
                (portrait ? portraitTarget : photoTarget))
            .toInt();
    if (target <= 0 || target > sourceLimit) {
      throw const FormatException('Invalid optimization target.');
    }
    var optimized = highQuality;
    var optimizedWidth = image.width, optimizedHeight = image.height;
    var quality = 94;
    for (final q in [88, 82, 78]) {
      if (optimized.length <= target) break;
      optimized = Uint8List.fromList(img.encodeJpg(image, quality: q));
      quality = q;
    }
    // Full-page documents keep their 1600px readability floor. Portraits first
    // try 640px; the ID-only adaptive stage below may reduce them further.
    final minimumEdge = portrait ? 640 : 1600;
    if (optimized.length > target &&
        math.max(image.width, image.height) > minimumEdge) {
      final smaller = img.copyResize(
        image,
        width: image.width >= image.height ? minimumEdge : null,
        height: image.height > image.width ? minimumEdge : null,
        interpolation: img.Interpolation.average,
      );
      optimized = Uint8List.fromList(img.encodeJpg(smaller, quality: 78));
      optimizedWidth = smaller.width;
      optimizedHeight = smaller.height;
      quality = 78;
    }
    // Text and line scans often compress better losslessly than as JPEG.
    // Compare fully processed pixels, never silently substitute an unprocessed
    // source or remove the retained original/high-quality generation.
    // Exact neutral pixels need one channel, not three identical RGB channels.
    // This retains the processed page and all pixel values without quantization.
    var neutral = true;
    for (final pixel in image) {
      if (pixel.r != pixel.g || pixel.g != pixel.b) {
        neutral = false;
        break;
      }
    }
    // Photographic portraits already have a compact JPEG candidate. A full
    // lossless PNG encode costs time and is not the ID-photo size strategy.
    // Colour photographs almost always lose to JPEG; encoding them as
    // maximum-compression PNG on every page is very expensive on Windows.
    // Retain the lossless path for truly neutral text/line artwork only.
    final lossless = portrait || !neutral
        ? null
        : Uint8List.fromList(
            img.encodePng(image.convert(numChannels: 1), level: 6),
          );
    var optimizedMime = 'image/jpeg';
    if (lossless != null && lossless.length < optimized.length) {
      optimized = lossless;
      optimizedMime = 'image/png';
      optimizedWidth = image.width;
      optimizedHeight = image.height;
    }
    // The q78 rendition at the minimum allowed edge was already measured
    // above. Repeating that exact resize and encode cannot improve the bytes.
    // Keep the better measured JPEG or lossless candidate.
    // ID photos are small printed/displayed regions, unlike full-page scans.
    // Adapt resolution to the measured encoded size while keeping JPEG q78,
    // aspect ratio, the uncropped face and at least a 256px long edge. Resize
    // from the processed source each time to avoid repeated-resampling blur.
    if (portrait) {
      var edge=math.max(optimizedWidth,optimizedHeight);
      while(optimized.length>target && edge>256) {
        final nextEdge=(edge*math.sqrt(target/optimized.length)*.90).floor()
          .clamp(256,edge-1).toInt();
        final candidateImage=img.copyResize(image,
          width:image.width>=image.height?nextEdge:null,
          height:image.height>image.width?nextEdge:null,
          interpolation:img.Interpolation.average);
        final candidate=Uint8List.fromList(img.encodeJpg(candidateImage,quality:78));
        if(candidate.length<optimized.length) {
          optimized=candidate;optimizedMime='image/jpeg';
          optimizedWidth=candidateImage.width;optimizedHeight=candidateImage.height;quality=78;
        }
        edge=nextEdge;
      }
      // Recover the highest JPEG quality that fits at the chosen dimensions.
      // Adaptive sizing used q78 to find a safe resolution, not as a fixed
      // quality setting for every face. Always encode from the source pixels.
      if (optimized.length <= target && quality < 94) {
        final candidateImage = optimizedWidth == image.width && optimizedHeight == image.height
            ? image
            : img.copyResize(image, width: optimizedWidth, height: optimizedHeight,
                interpolation: img.Interpolation.average);
        var low = quality + 1, high = 94;
        while (low <= high) {
          final q = (low + high) ~/ 2;
          final candidate = Uint8List.fromList(img.encodeJpg(candidateImage, quality: q));
          if (candidate.length <= target) {
            optimized = candidate;
            quality = q;
            low = q + 1;
          } else {
            high = q - 1;
          }
        }
      }
    }
    // For inventory photos the measured encoded byte ceiling is mandatory.
    // Reduce JPEG quality and then resolution, always from the processed
    // pixels (never from the uncropped original or a prior JPEG).
    if (!portrait && !pdfCompression && target <= photoTarget &&
        optimized.length > target) {
      var edge = math.max(optimizedWidth, optimizedHeight);
      while (optimized.length > target) {
        final candidateImage = edge == math.max(image.width, image.height)
            ? image
            : img.copyResize(image,
                width: image.width >= image.height ? edge : null,
                height: image.height > image.width ? edge : null,
                interpolation: img.Interpolation.average);
        for (final q in [78, 65, 50, 35, 20, 10]) {
          final candidate = Uint8List.fromList(img.encodeJpg(candidateImage, quality: q));
          if (candidate.length < optimized.length) {
            optimized = candidate;
            optimizedMime = 'image/jpeg';
            optimizedWidth = candidateImage.width;
            optimizedHeight = candidateImage.height;
            quality = q;
          }
          if (optimized.length <= target) break;
        }
        if (optimized.length <= target || edge <= 32) break;
        edge = (edge * .75).floor().clamp(32, edge - 1).toInt();
      }
      if (optimized.length > target) {
        throw const FormatException('Image cannot fit the required byte limit.');
      }
    }
    // A recompression must not consume more than the safe existing source.
    // Retain the original container when processing expands it: this is an
    // explicitly reported fallback, not a claim that cleanup was applied.
    final sourceContainer = _sanitizedSource(bytes, sourceOrientation);
    // Do not replace a successfully cropped/deskewed document with the
    // original JPEG merely because the processed encoding is larger. That
    // silently undoes the visible cleanup in Student Inventory.
    final retainedSource = sourceContainer != null &&
        optimized.length > sourceContainer.length &&
        !corrected && !manualCrop && rotation == 0 && edit == null && !adjusted &&
        deskew.abs() < 0.5;
    if (retainedSource) {
      optimized = sourceContainer!;
      optimizedMime = bytes[0] == 137 ? 'image/png' : 'image/jpeg';
      optimizedWidth = orientedSource.width;
      optimizedHeight = orientedSource.height;
    }
    // Compare decoded optimized pixels with the same processed reference,
    // at a bounded common scale. This is an image-quality guard, not an OCR
    // guarantee for every glyph. Never silently describe an uncertain result
    // as text-verified.
    final qualityGuard = portrait
        ? <String, dynamic>{}
        : _scanQualityGuard(retainedSource ? orientedSource : image, optimized);
    final targetMet = optimized.length <= target;
    return {
      'optimized': optimized,
      'sourceRetained': retainedSource,
      'optimizationReason': targetMet
          ? 'Target met; actual encoded size measured'
          : 'Requested target not met without crossing the quality/resolution floor',
      'mimeType': optimizedMime,
      'highQuality': highQuality,
      'quality': retainedSource ? null : quality,
      'attemptedJpegQuality': quality,
      'outputQualityReason': retainedSource
          ? 'Existing compressed samples retained; original encoder quality unknown'
          : optimizedMime == 'image/png'
          ? 'Lossless processed pixels'
          : 'JPEG quality selected from measured encoded size',
      'targetMet': targetMet,
      'actualBytes': optimized.length,
      'originalBytes': bytes.length,
      'targetBytes': target,
      'savingsPercent': 100 * (1 - optimized.length / bytes.length),
      'perspectiveCorrected': corrected,
      'manualCrop': manualCrop,
      'rotationDegrees': rotation,
      'scanFilter': filter,
      'brightness': brightness,
      'contrast': contrast,
      'deskewDegrees': deskew,
      ...qualityGuard,
      'width': optimizedWidth,
      'height': optimizedHeight,
      'cleanupStatus': retainedSource
          ? 'Original container retained: cleanup encoding would enlarge upload'
          : edit != null
          ? 'Manual crop and rotation applied; original preserved'
          : corrected
          ? 'Detected paper boundary corrected'
          : rotation != 0
          ? 'Confident orientation corrected; full image preserved'
          : 'No confident boundary; full image preserved',
    };
  }

  static Map<String, dynamic> _scanQualityGuard(img.Image reference, Uint8List encoded) {
    final decoded = img.decodeImage(encoded);
    if (decoded == null) throw const FormatException('Optimized scan cannot be decoded.');
    // Use the channel count from the Image API (image 4.10), not Pixel.
    // A grayscale sample represents equal displayed R/G/B values even when
    // the storage object exposes absent green and blue channels as zero.
    final w = math.min(180, math.min(reference.width, decoded.width));
    final h = math.min(180, math.min(reference.height, decoded.height));
    final a = img.copyResize(reference, width: w, height: h,
        interpolation: img.Interpolation.average);
    final b = img.copyResize(decoded, width: w, height: h,
        interpolation: img.Interpolation.average);
    double lum(img.Image raster, int x, int y) {
      final p = raster.getPixel(x, y);
      final alpha = raster.hasAlpha ? p.aNormalized : 1.0;
      final value = raster.numChannels <= 2
          ? p.rNormalized
          : p.rNormalized * 0.299 + p.gNormalized * 0.587 +
              p.bNormalized * 0.114;
      return value * 255 * alpha + (1 - alpha) * 255;
    }
    var error = 0.0, edges = 0, kept = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final av = lum(a, x, y), bv = lum(b, x, y);
        error += (av - bv).abs();
        if (x == 0) continue;
        final da = (av - lum(a, x - 1, y)).abs();
        final db = (bv - lum(b, x - 1, y)).abs();
        if (da >= 40) {
          edges++;
          if (db >= da * 0.55) kept++;
        }
      }
    }
    final mae = error / (w * h);
    final edgeRetention = edges == 0 ? 1.0 : kept / edges;
    return {
      'qualityGuard': mae <= 20 && (edges < 12 || edgeRetention >= 0.70)
          ? 'pixel-check-passed' : 'review-required',
      'meanLuminanceError': mae,
      'contrastEdgeRetention': edgeRetention,
    };
  }

  static int? _jpegSourceOrientation(Uint8List source) {
    if (source[0] != 255 || source[1] != 216) return null;
    var offset = 2;
    while (offset + 4 <= source.length) {
      if (source[offset] != 255) return null;
      final marker = source[offset + 1];
      if (marker == 218 || marker == 217) return null;
      final length = (source[offset + 2] << 8) | source[offset + 3];
      final end = offset + 2 + length;
      if (length < 2 || end > source.length) return null;
      final payload = offset + 4;
      if (marker == 225 &&
          length >= 16 &&
          source[payload] == 69 &&
          source[payload + 1] == 120 &&
          source[payload + 2] == 105 &&
          source[payload + 3] == 102 &&
          source[payload + 4] == 0 &&
          source[payload + 5] == 0) {
        final tiff = payload + 6;
        final order = source[tiff] == 73 && source[tiff + 1] == 73
            ? Endian.little
            : source[tiff] == 77 && source[tiff + 1] == 77
            ? Endian.big
            : null;
        if (order == null) return null;
        final data = ByteData.sublistView(source);
        if (data.getUint16(tiff + 2, order) != 42) return null;
        final ifd = tiff + data.getUint32(tiff + 4, order);
        if (ifd < tiff + 8 || ifd + 2 > end) return null;
        final count = data.getUint16(ifd, order);
        if (count > 512 || ifd + 2 + count * 12 > end) return null;
        for (var i = 0; i < count; i++) {
          final entry = ifd + 2 + i * 12;
          if (data.getUint16(entry, order) == 0x112 &&
              data.getUint16(entry + 2, order) == 3 &&
              data.getUint32(entry + 4, order) == 1) {
            final value = data.getUint16(entry + 8, order);
            return value >= 1 && value <= 8 ? value : null;
          }
        }
      }
      offset = end;
    }
    return null;
  }

  /// Keep compressed image samples without copying location/comment metadata.
  /// JPEG orientation is the only EXIF entry retained so the fallback remains
  /// correctly displayed; the separate processed preview has baked orientation.
  static Uint8List? _sanitizedSource(Uint8List source, int orientation) {
    final result = BytesBuilder(copy: false);
    if (source[0] == 137 && source[1] == 80) {
      if (orientation != 1) return null;
      result.add(source.sublist(0, 8));
      final data = ByteData.sublistView(source);
      var offset = 8;
      while (offset + 12 <= source.length) {
        final length = data.getUint32(offset);
        final end = offset + length + 12;
        if (end > source.length) return null;
        final kind = String.fromCharCodes(
          source.sublist(offset + 4, offset + 8),
        );
        if (!{'eXIf', 'tEXt', 'zTXt', 'iTXt'}.contains(kind)) {
          result.add(source.sublist(offset, end));
        }
        offset = end;
      }
      return result.takeBytes();
    }
    if (source[0] != 255 || source[1] != 216) return null;
    result.add([255, 216]);
    var offset = 2;
    while (offset + 4 <= source.length) {
      if (source[offset] != 255) return null;
      final marker = source[offset + 1];
      if (marker == 218) {
        // Image samples, restart markers and end marker are copied unchanged.
        result.add(source.sublist(offset));
        return result.takeBytes();
      }
      final length = (source[offset + 2] << 8) | source[offset + 3];
      final end = offset + 2 + length;
      if (length < 2 || end > source.length) return null;
      if (marker != 225 && marker != 237 && marker != 254) {
        result.add(source.sublist(offset, end));
      }
      offset = end;
      // Insert one minimal orientation-only EXIF entry before the next segment.
      if (orientation >= 2 && orientation <= 8) {
        result.add([
          255,
          225,
          0,
          34,
          69,
          120,
          105,
          102,
          0,
          0,
          73,
          73,
          42,
          0,
          8,
          0,
          0,
          0,
          1,
          0,
          18,
          1,
          3,
          0,
          1,
          0,
          0,
          0,
          orientation,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
        ]);
        orientation = 1;
      }
    }
    return null;
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

  // Compute a between-class variance threshold from a small detection raster.
  // Technique reference: Otsu's method; also used by
  // https://github.com/Nardo86/document_scanner (MIT).
  static int _adaptivePaperThreshold(img.Image sample) {
    final bins = List<int>.filled(256, 0);
    var count = 0;
    var weighted = 0;
    for (var y = 0; y < sample.height; y += 2) {
      for (var x = 0; x < sample.width; x += 2) {
        final pixel = sample.getPixel(x, y);
        final value = ((pixel.r + pixel.g + pixel.b) / 3).round().clamp(0, 255).toInt();
        bins[value]++;
        count++;
        weighted += value;
      }
    }
    var leftCount = 0, leftSum = 0, split = 0;
    var best = -1.0;
    for (var level = 0; level < 255; level++) {
      leftCount += bins[level];
      leftSum += level * bins[level];
      final rightCount = count - leftCount;
      if (leftCount == 0 || rightCount == 0) continue;
      final gap = leftSum / leftCount - (weighted - leftSum) / rightCount;
      final variance = leftCount.toDouble() * rightCount * gap * gap;
      if (variance > best) {
        best = variance;
        split = level;
      }
    }
    return split;
  }

  /// Suggest four crop handles in the normalized EXIF-oriented editor raster.
  /// A missing result means no confident border: the editor keeps all pixels.
  static List<double>? suggestCrop(Uint8List thumbnail) {
    SchoolImageInput.validate(thumbnail);
    final raster = img.decodePng(thumbnail);
    if (raster == null) return null;
    final points = _paperCorners(raster);
    if (points == null) return null;
    return [
      for (final point in points) ...[
        (point.x / (raster.width - 1)).clamp(0.0, 1.0).toDouble(),
        (point.y / (raster.height - 1)).clamp(0.0, 1.0).toDouble(),
      ],
    ];
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
    if (border.isEmpty) return null;
    final background = border[border.length ~/ 2];
    if (background > 215) return null;
    // A relative threshold handles light cloth and shadowed paper without
    // dropping the neutral-colour and connected-page geometry safeguards.
    final adaptive = _adaptivePaperThreshold(sample);
    final threshold = math.max(165.0, math.max(background + 22, adaptive.toDouble()));
    // Use one connected, neutral paper surface. Unrelated bright table/hand
    // pixels must never become the page's corners.
    final gw = (sample.width + 1) ~/ 2, gh = (sample.height + 1) ~/ 2;
    final mask = Uint8List(gw * gh);
    for (var y = 1; y < gh - 1; y++) {
      for (var x = 1; x < gw - 1; x++) {
        final pixel = sample.getPixel(x * 2, y * 2);
        final spread =
            math.max(pixel.r, math.max(pixel.g, pixel.b)) -
            math.min(pixel.r, math.min(pixel.g, pixel.b));
        // Allow softly lit / slightly tinted paper against patterned cloth,
        // but keep colour contrast and largest-component geometry safeguards.
        if (light(x * 2, y * 2) > threshold && spread < 45) {
          mask[y * gw + x] = 1;
        }
      }
    }
    var points = <img.Point>[];
    var runnerUp = 0;
    for (var seed = 0; seed < mask.length; seed++) {
      if (mask[seed] != 1) continue;
      final queue = <int>[seed], component = <img.Point>[];
      mask[seed] = 2;
      for (var index = 0; index < queue.length; index++) {
        final cell = queue[index], x = cell % gw, y = cell ~/ gw;
        component.add(img.Point(x * 2, y * 2));
        for (final next in [
          if (x > 0) cell - 1,
          if (x + 1 < gw) cell + 1,
          if (y > 0) cell - gw,
          if (y + 1 < gh) cell + gw,
        ]) {
          if (mask[next] == 1) {
            mask[next] = 2;
            queue.add(next);
          }
        }
      }
      if (component.length > points.length) {
        runnerUp = points.length;
        points = component;
      } else if (component.length > runnerUp) {
        runnerUp = component.length;
      }
    }
    if (points.length < gw * gh * 0.30 || runnerUp > points.length * 0.25)
      return null;
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
    final quadArea = area.abs() / 2;
    final frameArea = sample.width * sample.height;
    if (quadArea < frameArea * 0.30 ||
        quadArea > frameArea * 0.96 ||
        points.length * 4 / quadArea < 0.70)
      return null;
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

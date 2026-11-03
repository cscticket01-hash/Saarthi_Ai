import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../document_processing_engine.dart';

import 'dart:convert';
import 'dart:typed_data';

import '../windows_school_image_cache.dart';
import '../windows_local_firestore.dart';
import 'central_school_cloud.dart';
import 'school_drive_images.dart' show schoolDriveFileId;

/// Upload images to this school's Drive before publishing a text-only record.
Future<Map<String, dynamic>> prepareManagedRecord(
  Map<String, dynamic> data,
  String school,
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) call,
) => _prepareManagedRecord(
  data,
  school,
  call,
  FirebaseFirestore.instance.activeProfileId,
  0,
);

Future<Map<String, dynamic>> _prepareManagedRecord(
  Map<String, dynamic> data,
  String school,
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>) call,
  String profile,
  int depth,
) async {
  void own() {
    if (FirebaseFirestore.instance.activeProfileId != profile)
      throw StateError('School changed during media preparation.');
  }

  own();
  if (depth > 12)
    throw StateError('Record is too deeply nested. Local media retained.');
  if (data['schoolId'] != null && data['schoolId'] != school)
    throw StateError('Foreign school record blocked.');
  final result = Map<String, dynamic>.from(data);
  if(depth==0&&result['studentId'] is String&&result['personId']==null&&result['role']!='teacher'&&result['ownerRole']!='teacher') {
    final parent=(await FirebaseFirestore.instance.collection('students_directory').doc(result['studentId']).get()).data();
    own();
    if(parent?['mobileStableId'] is String)result['personId']=parent!['mobileStableId'];
  }

  // Photos, logos and seals have no business ordering dependency. Prepare
  // at most two concurrently to avoid saturating older school PCs or the
  // provider; the original sync/outbox owner remains the single writer.
  // A failed item never publishes partially prepared record metadata.
  Future<Map<String, dynamic>?> prepareImage(String prefix) async {
    final pending = data['${prefix}Base64'];
    final raw = pending is String && pending.startsWith('data:image/')
        ? pending
        : data['${prefix}Url'];
    if (raw is! String || !raw.startsWith('data:image/')) return null;
    own();
    final image = UriData.parse(raw);
    var bytes = image.contentAsBytes(), mime = image.mimeType;
    final originalDigest = sha256.convert(bytes).toString();
    if (prefix == 'photo') {
      final processed = await compute(DocumentProcessingEngine.portraitUpload, {
        'bytes': bytes, 'kind': 'portrait',
        'targetBytes': DocumentProcessingEngine.portraitTarget,
      });
      own();
      bytes = processed['optimized'] as Uint8List;
      mime = processed['mimeType'] as String;
    } else {
      final processed = await compute(DocumentProcessingEngine.brandingUpload, {
        'bytes': bytes,
      });
      own();
      bytes = processed['optimized'] as Uint8List;
      mime = processed['mimeType'] as String;
    }
    final digest = sha256.convert(bytes).toString();
    final upload = await call('managed/file/upload', {
      'name': prefix == 'photo'
          ? '${prefix}_optimized_${originalDigest}_$digest.${mime == 'image/jpeg' ? 'jpg' : 'png'}'
          : '${prefix}_$digest.${mime == 'image/jpeg' ? 'jpg' : 'png'}',
      'mime': mime,
      'uploadKey': sha256
          .convert(utf8.encode(prefix == 'photo'
              ? '$school:$prefix:$mime:$originalDigest:$digest'
              : '$school:$prefix:$mime:$digest'))
          .toString(),
      'base64': base64Encode(bytes),
    });
    own();
    if (upload['success'] != true || upload['schoolId'] != school ||
        upload['fileId'] is! String || upload['fileUrl'] is! String ||
        schoolDriveFileId(upload['fileUrl'] as String) != upload['fileId']) {
      throw StateError('School image upload failed. Local image retained.');
    }
    // Preserve the input for verified quality recovery. Stable upload keys
    // make a retry idempotent even if one parallel request completed earlier.
    await WindowsSchoolImageCache.store(
      school, upload['fileId'] as String, raw, profileId: profile,
    );
    own();
    return {
      'prefix': prefix, 'url': upload['fileUrl'],
      'fileId': upload['fileId'], 'sourceHash': originalDigest,
    };
  }

  const assetPrefixes = ['photo', 'logo', 'seal', 'principalSignature'];
  for (var i = 0; i < assetPrefixes.length; i += 2) {
    final assets = await Future.wait(
      assetPrefixes.skip(i).take(2).map(prepareImage));
    own();
    for (final asset in assets) {
      if (asset == null) continue;
      final prefix = asset['prefix'] as String;
      result['${prefix}Url'] = asset['url'];
      result['${prefix}FileId'] = asset['fileId'];
      result['${prefix}SourceHash'] = asset['sourceHash'];
    }
  }
  for (final key in result.keys.toList()) {
    final value = result[key];
    if (value is Map)
      result[key] = await _prepareManagedRecord(
        Map<String, dynamic>.from(value),
        school,
        call,
        profile,
        depth + 1,
      );
    if (value is List) {
      final items = <dynamic>[];
      for (final item in value)
        items.add(
          item is Map
              ? await _prepareManagedRecord(
                  Map<String, dynamic>.from(item),
                  school,
                  call,
                  profile,
                  depth + 1,
                )
              : item,
        );
      result[key] = items;
    }
  }
  if (FirebaseFirestore.instance.activeProfileId != profile)
    throw StateError('School changed during media preparation.');
  return depth == 0 ? centralSchoolData(result, school) : result;
}

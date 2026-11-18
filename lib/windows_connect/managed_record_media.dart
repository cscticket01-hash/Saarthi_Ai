import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../document_processing_engine.dart';

import 'dart:convert';
import 'dart:typed_data';

import '../windows_school_image_cache.dart';
import '../windows_local_firestore.dart';
import 'central_school_cloud.dart';
import 'school_drive_images.dart' show schoolDriveFileId;
import 'managed_resumable_upload.dart';

/// Cloudflare receives ONE optimized original portrait plus the original
/// person record metadata. The caller keeps the immutable local outbox until
/// the Worker verifies a *real* Google Drive file and matching record revision.
/// Multi-media, field patches, deletes and atomic bundles use their established
/// version-safe path rather than publishing partial metadata.
Future<Map<String,dynamic>?> stageManagedOriginalPhotoRecord(
  Map<String,dynamic> item,
  String school, {
  required Future<Map<String,dynamic>> Function(Map<String,dynamic>) request,
  Future<Map<String,dynamic>> Function(Uint8List)? optimize,
}) async {
  final collection=item['collection'],id=item['documentId'],
      operationId=item['operationId'], data=item['data'];
  if(!{'students_directory','teachers_directory'}.contains(collection) ||
      !{'set','update'}.contains(item['operation']) ||
      item['schoolId']!=school || data is! Map ||
      item['atomicBundleId']!=null || item['priorDeletion']!=null ||
      item['wireData'] is Map || item['wireMode']=='fieldPatch1' ||
      id is! String||id.isEmpty||id.length>200||id.contains('/') ||
      operationId is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(operationId) ||
      item['baseCloudRevision'] is! String) return null;
  final source=Map<String,dynamic>.from(data);
  if(source['schoolId']!=null && source['schoolId']!=school) {
    throw StateError('Foreign person/photo owner.');
  }
  final fromBase64=source['photoBase64'];
  final raw=fromBase64 is String && fromBase64.startsWith('data:image/')
      ? fromBase64 : source['photoUrl'];
  if(raw is! String||!raw.startsWith('data:image/')) return null;
  for(final key in ['logo','seal','principalSignature']) {
    if((source[key+'Url'] is String &&
        (source[key+'Url'] as String).startsWith('data:')) ||
       (source[key+'Base64'] is String &&
        (source[key+'Base64'] as String).startsWith('data:'))) return null;
  }
  final db=FirebaseFirestore.instance, profile=db.activeProfileId;
  void own() {
    if(db.activeProfileId!=profile ||
       db.activeProfileIdentity['schoolSyncId']!=school) {
      throw StateError('School changed during original photo handoff.');
    }
  }
  own();
  final original=UriData.parse(raw).contentAsBytes();
  if(original.isEmpty || original.length>20*1024*1024) {
    throw StateError('Original portrait exceeds safe Cloudflare upload limit.');
  }
  final sourceHash=sha256.convert(original).toString();
  final processed=await (optimize?.call(Uint8List.fromList(original)) ??
      compute(DocumentProcessingEngine.portraitUpload, {
        'bytes':Uint8List.fromList(original),'kind':'portrait',
        'targetBytes':DocumentProcessingEngine.portraitTarget,
      }));
  own();
  final bytes=processed['optimized'];
  final mime=processed['mimeType'];
  if(bytes is! Uint8List || bytes.isEmpty ||
     bytes.length>20*1024*1024 ||
     !['image/jpeg','image/png','image/webp'].contains(mime)) {
    throw StateError('Verified optimized photo is unavailable.');
  }
  final fileSha256=sha256.convert(bytes).toString();
  // Keep student stable ID semantics of the existing record media preflight.
  if(source['studentId'] is String && source['personId']==null &&
     source['role']!='teacher' && source['ownerRole']!='teacher') {
    final parent=(await db.collection('students_directory')
       .doc(source['studentId'] as String).get()).data();
    own();
    if(parent?['mobileStableId'] is String)
       source['personId']=parent!['mobileStableId'];
  }
  final safe=centralSchoolData(source,school)
    ..remove('photoUrl')
    ..remove('photoFileId')
    ..remove('photoBase64');
  safe['photoSourceHash']=sourceHash;
  final record=<String,dynamic>{
    'version':1,'schoolId':school,'collection':collection,
    'operation':'write','id':id,'operationId':operationId,
    'expectedRecordRevision':item['baseCloudRevision'],
    'mediaPrefix':'photo','sourceHash':sourceHash,'data':safe,
  };
  if(jsonEncode(record).length>190000) return null;
  final uploadKey=sha256.convert(utf8.encode(
    jsonEncode([school,collection,id,operationId,fileSha256]))).toString();
  final result=await uploadManagedChunks(
    schoolId:school,uploadKey:uploadKey,
    name:'photo_optimized_'+sourceHash+'_'+fileSha256+
      (mime=='image/jpeg'?'.jpg':mime=='image/png'?'.png':'.webp'),
    mime:mime as String,bytes:bytes,record:record,
    action:'managed/record/media/stage/resumable',
    acceptDurableCloudflareHandoff:true,request:request,
  );
  own();
  if(result['cloudflareHandoffVersion']!=1 ||
     result['cloudflareAccepted']!=true ||
     !['pending','verified'].contains(result['driveState']) ||
     result['delivery'] is! Map) {
    throw StateError('Original portrait Cloudflare custody unverified.');
  }
  return {
    'delivery':result['delivery'],'sourceHash':sourceHash,
    'fileSha256':fileSha256,
  };
}

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

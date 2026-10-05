import '../windows_school_image_cache.dart';
import '../windows_local_firestore.dart';
import 'central_school_cloud.dart';

/// Upload images to this school's Drive before publishing a text-only record.
Future<Map<String,dynamic>> prepareManagedRecord(Map<String,dynamic> data, String school,
    Future<Map<String,dynamic>> Function(String, Map<String,dynamic>) call) async {
  if (data['schoolId'] != null && data['schoolId'] != school) throw StateError('Foreign school record blocked.');
  final profile=FirebaseFirestore.instance.activeProfileId;
  final result = Map<String,dynamic>.from(data);
  for (final prefix in ['photo','logo','seal','principalSignature']) {
    final pending = data['${prefix}Base64'];
    final raw = pending is String && pending.startsWith('data:image/') ? pending : data['${prefix}Url'];
    if (raw is! String || !raw.startsWith('data:image/')) continue;
    final image = UriData.parse(raw);
    final upload = await call('managed/file/upload', {
      'name': '$prefix.png', 'mime': image.mimeType,
      'base64': raw.substring(raw.indexOf(',') + 1),
    });
    if (upload['success'] != true || upload['schoolId'] != school ||
        upload['fileId'] is! String || upload['fileUrl'] is! String) throw StateError('School image upload failed. Local image retained.');
    await WindowsSchoolImageCache.store(school,upload['fileId'] as String,raw,profileId:profile);
    result['${prefix}Url'] = upload['fileUrl'];
    result['${prefix}FileId'] = upload['fileId'];
  }
  return centralSchoolData(result, school);
}

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Offset ownership is the authenticated Script's durable provider session.
/// Reopening the existing queue with the same key discovers the committed prefix.
/// This helper never retries writes or acknowledges a document record itself.
Future<Map<String, dynamic>> uploadManagedChunks({
  required String schoolId,
  required String uploadKey,
  required String name,
  required String mime,
  required Uint8List bytes,
  required Future<Map<String, dynamic>> Function(Map<String, dynamic>) request,
}) async {
  if (bytes.isEmpty || bytes.length > 20 * 1024 * 1024) {
    throw StateError('School file must be between 1 byte and 20 MB.');
  }
  final digest = sha256.convert(bytes).toString();
  final metadata = <String, dynamic>{
    'action': 'managed/file/upload/resumable', 'schoolId': schoolId,
    'uploadKey': uploadKey, 'name': name, 'mime': mime,
    'sha256': digest, 'sizeBytes': bytes.length,
  };
  Map<String, dynamic> verify(Map<String, dynamic> out) {
    if (out['schoolId'] != schoolId || out['uploadResumableVersion'] != 1 ||
        out['uploadKey'] != uploadKey || out['sha256'] != digest ||
        out['sizeBytes'] != bytes.length || out['committed'] is! bool ||
        out['offset'] is! int || out['offset'] < 0 || out['offset'] > bytes.length ||
        out['committed'] == true && (out['offset'] != bytes.length ||
            !RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(out['fileId']?.toString() ?? '')) ||
        out['committed'] == false && out['offset'] == bytes.length) {
      throw StateError('School upload progress or completion is unverified.');
    }
    return out;
  }
  var result = verify(await request({...metadata, 'operation': 'begin'}));
  // 20 MiB / 512 KiB plus a bounded allowance for provider partial progress.
  for (var step = 0; step < 160 && result['committed'] != true; step++) {
    final offset = result['offset'] as int;
    final end = (offset + 512 * 1024).clamp(0, bytes.length).toInt();
    final chunk = Uint8List.sublistView(bytes, offset, end);
    final next = verify(await request({...metadata, 'operation': 'part',
      'offset': offset, 'base64': base64Encode(chunk),
      'chunkSha256': sha256.convert(chunk).toString(),
    }));
    if (next['committed'] != true && next['offset'] <= offset) {
      throw TimeoutException('School upload has not advanced; retain the same upload key.');
    }
    result = next;
  }
  if (result['committed'] != true) {
    throw TimeoutException('School upload needs another owner attempt; pending retained.');
  }
  return {'fileId': result['fileId'],
    'fileUrl': 'https://drive.google.com/file/d/${result['fileId']}/view'};
}

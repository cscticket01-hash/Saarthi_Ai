import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../windows_sync_evidence.dart';

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
  String action = 'managed/file/upload/resumable',
  Map<String, dynamic>? document,
  Map<String, dynamic>? record,
  bool acceptDurableCloudflareHandoff = false,
}) async {
  if (bytes.isEmpty || bytes.length > 20 * 1024 * 1024) {
    throw StateError('School file must be between 1 byte and 20 MB.');
  }
  final digest = sha256.convert(bytes).toString();
  final metadata = <String, dynamic>{
    'action': action, 'schoolId': schoolId,
    if (document != null) 'document': document,
    if (record != null) 'record': record,
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
  // A durable, exactly bound file ticket ends only the outgoing device upload.
  // The independent broker remains responsible for the real Drive fileId.
  Map<String, dynamic>? cloudAccepted(Map<String, dynamic> out) {
    if (!acceptDurableCloudflareHandoff ||
        out['cloudflareHandoffVersion'] != 1 ||
        out['success'] != true ||
        out['schoolId'] != schoolId ||
        out['cloudflareAccepted'] != true ||
        !(out['driveState'] == 'pending' ||
          out['driveState'] == 'verified' && out['committed'] == true &&
          out['fileId'] is String &&
          (out['fileId'] as String).isNotEmpty)) return null;
    final ticket = out['delivery'];
    final expected = sha256.convert(utf8.encode(
      jsonEncode([schoolId, uploadKey]),
    )).toString();
    if (ticket is! Map || ticket['id'] != expected ||
        ticket['lane'] != 'file-$expected') {
      throw StateError('Document Cloudflare ticket identity did not verify.');
    }
    return out;
  }
  final tracked = acceptDurableCloudflareHandoff;
  final transfer = Object();
  void report(Map<String, dynamic> receipt) {
    if (tracked && receipt['committed'] == false) {
      WindowsSyncEvidence.reportUpload(
        transfer, schoolId, receipt['offset'] as int, bytes.length,
      );
    }
  }

  try {
    final first = await request({...metadata, 'operation': 'begin'});
    final alreadyAccepted = cloudAccepted(first);
    if (alreadyAccepted != null) return alreadyAccepted;
    var result = verify(first);
    report(result);
    // 20 MiB / 512 KiB plus a bounded allowance for provider partial progress.
    for (var step = 0; step < 160 && result['committed'] != true; step++) {
      final offset = result['offset'] as int;
      final end = (offset + 512 * 1024).clamp(0, bytes.length).toInt();
      final chunk = Uint8List.sublistView(bytes, offset, end);
      final reply = await request({...metadata, 'operation': 'part',
        'offset': offset, 'base64': base64Encode(chunk),
        'chunkSha256': sha256.convert(chunk).toString(),
      });
      final completedCloudflare = cloudAccepted(reply);
      if (completedCloudflare != null) return completedCloudflare;
      final next = verify(reply);
      if (next['committed'] != true && next['offset'] <= offset) {
        throw TimeoutException('School upload has not advanced; retain the same upload key.');
      }
      result = next;
      report(result);
    }
    if (result['committed'] != true) {
      throw TimeoutException('School upload needs another owner attempt; pending retained.');
    }
    return {'fileId': result['fileId'],
      'fileUrl': 'https://drive.google.com/file/d/${result['fileId']}/view'};
  } finally {
    if (tracked) WindowsSyncEvidence.endUpload(transfer);
  }

}

import 'dart:convert';

import 'school_timestamp.dart';

import 'package:crypto/crypto.dart';

// UUID revisions are identities, not ordered version numbers. Never infer
// cloud/local newer from clocks, UUID spelling, or retry count.
const _bookkeeping = {
  'id',
  '_syncRevision',
  '_syncOperationId',
  '_syncRequestHash',
  '_syncDeleted',
  '_syncDeletedFileId',
  '_syncFileCleanupComplete',
};
Object? _canonical(Object? value) {
  if (value is Timestamp)
    return {'__vidya_type': 'timestamp', 'ms': value.millisecondsSinceEpoch};
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return {for (final k in keys) k: _canonical(value[k])};
  }
  if (value is List) return value.map(_canonical).toList();
  if (value is DateTime) return value.toUtc().toIso8601String();
  return value;
}

String syncPayloadHash(Map data) => sha256
    .convert(
      utf8.encode(
        jsonEncode(
          _canonical({
            for (final e in data.entries)
              if (!_bookkeeping.contains(e.key)) e.key.toString(): e.value,
          }),
        ),
      ),
    )
    .toString();

bool identicalDocumentPayload(Map local, Map cloud) {
  if (local['schoolId'] == null ||
      local['schoolId'] != cloud['schoolId'] ||
      cloud['_syncDeleted'] == true ||
      local['documentRevision'] is! String ||
      local['documentRevision'].isEmpty ||
      local['documentRevision'] != cloud['documentRevision'] ||
      local['contentHash'] is! String ||
      !RegExp(r'^[a-f0-9]{64}$').hasMatch(local['contentHash']) ||
      local['contentHash'] != cloud['contentHash'])
    return false;
  // Bytes alone are insufficient: student ownership and business metadata count.
  const keys = [
    'studentId',
    'studentName',
    'studentClass',
    'rollNo',
    'documentName',
    'fileName',
    'mimeType',
    'uploadedBy',
    'documentKind',
    'ownerRole',
    'personId',
    'inputRevision',
  ];
  return keys.every((key) => local[key] == cloud[key]);
}

String compareSyncVersions(Map queued, Map cloud) {
  if (queued['schoolId'] != cloud['schoolId'] ||
      cloud['_syncDeleted'] == true ||
      queued['operation'] == 'delete' ||
      queued['deleted'] == true)
    return 'differs';
  final local = queued['data'];
  if (local is! Map)
    return 'differs'; // File bytes must be verified by their owner.
  if (syncPayloadHash(local) == syncPayloadHash(cloud)) return 'identical';
  return 'differs (revision order unknown)';
}

/// A bool success is transport feedback, never a verified cloud receipt.
bool verifiedDocumentAcknowledgement(Map payload, Map result) {
  final cloud = result['document'];
  if (result['success'] != true ||
      result['cloudVerified'] != true ||
      cloud is! Map ||
      result['schoolId'] != payload['schoolId'] ||
      cloud['schoolId'] != payload['schoolId'] ||
      cloud['id'] != payload['documentId'] ||
      cloud['_syncRevision'] is! String ||
      (cloud['_syncRevision'] as String).isEmpty)
    return false;
  if (payload['action'] == 'delete_student_document') {
    return cloud['_syncDeleted'] == true &&
        cloud['documentRevision'] == payload['baseCloudRevision'];
  }
  return identicalDocumentPayload(payload, cloud);
}

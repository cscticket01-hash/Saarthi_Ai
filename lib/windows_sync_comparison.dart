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

/// Bind identity to the key selected from an authenticated managed readback.
/// Never replace an explicitly contradictory ID or weaken content verification.
Map<String, dynamic> documentAcknowledgementFromReadback(Map payload, Map reply, {Map? deleteAcknowledgement}) {
  final id = payload['documentId'];
  final records = reply['records'];
  final row = id is String && records is Map ? records[id] : null;
  final identityMatches = row is Map &&
      (row['id'] == null || row['id'] == id) &&
      (row['documentId'] == null || row['documentId'] == id);
  return {
    'success': reply['success'] != false,
    'cloudVerified': reply['syncProtocol'] == 2 && identityMatches,
    'schoolId': reply['schoolId'],
    'documentId': id,
    'document': identityMatches ? {...row, 'id': id} : row,
    'fileUrl': row is Map ? row['fileUrl'] : null,
    if (deleteAcknowledgement != null) 'deleteAcknowledgement':deleteAcknowledgement,
  };
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
    final ack = result['deleteAcknowledgement'];
    final base = payload['baseCloudRevision'];
    // Absent-record tombstones deliberately omit documentRevision. Accept this
    // shape only with the exact authenticated delete response AND readback.
    return base is String && cloud['_syncDeleted'] == true &&
        (cloud['documentRevision'] == base ||
          (base.isEmpty && cloud['documentRevision'] == null)) &&
        ack is Map && ack['success'] == true && ack['syncProtocol'] == 2 &&
        ack['schoolId'] == payload['schoolId'] && ack['collection'] == 'documents' &&
        ack['documentId'] == payload['documentId'] &&
        payload['deleteOperationId'] is String &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(payload['deleteOperationId']) &&
        ack['operationId'] == payload['deleteOperationId'] &&
        ack['recordRevision'] == cloud['_syncRevision'];
  }
  return identicalDocumentPayload(payload, cloud);
}

/// Explain content differences without assuming UUIDs or clocks establish order.
List<String> documentDifferenceFields(Map local, Map cloud) => [
  for (final key in const ['schoolId','documentRevision','contentHash','studentId',
    'studentName','studentClass','rollNo','documentName','fileName','mimeType',
    'uploadedBy','documentKind','ownerRole','personId','inputRevision'])
    if (local[key] != cloud[key]) key,
  if (cloud['_syncDeleted'] == true) '_syncDeleted',
];

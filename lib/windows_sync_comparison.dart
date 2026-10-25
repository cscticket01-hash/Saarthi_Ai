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
  '_syncUpdatedAt',
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

/// Directory Save timestamps describe the save, not another person or edit.
/// Keep identity, photos, lifecycle markers and every business field in proof.
/// Financial/document dates remain significant in their original collections.
bool sameSavedRecord(String collection, Map left, Map right) {
  Map value(Map row) => {
    for (final entry in row.entries)
      if (!({'students_directory', 'teachers_directory'}.contains(collection) &&
          {'createdAt', 'updatedAt'}.contains(entry.key)))
        entry.key: entry.value,
  };
  return syncPayloadHash(value(left)) == syncPayloadHash(value(right));
}

/// An explicit changed Save may replace a reviewed directory version, using
/// CAS against the last authenticated read. Never apply to another person,
/// a deletion/recreation, documents or financial records.
bool canSaveDirectoryConflict(Map queued, Map data) {
  final proof = queued['directoryConflictBase'];
  final collection = queued['collection'];
  final field = collection == 'students_directory' ? 'mobileStableId' : 'teacherId';
  return {'students_directory', 'teachers_directory'}.contains(collection) &&
      queued['syncState'] == 'conflict' && queued['operation'] == 'set' &&
      queued['priorDeletion'] == null && queued['reviewedFromOperationId'] == null &&
      proof is Map && proof['schoolId'] == queued['schoolId'] &&
      proof['documentId'] == queued['documentId'] &&
      proof['revision'] is String && (proof['revision'] as String).isNotEmpty &&
      proof['identityField'] == field && proof['identity'] is String &&
      (proof['identity'] as String).isNotEmpty &&
      queued['data'] is Map && queued['data'][field] == proof['identity'] &&
      data[field] == proof['identity'] &&
      (data['schoolId'] == null || data['schoolId'] == proof['schoolId']) &&
      !data.keys.any((key) => key.toString().startsWith('_syncRecreates')) &&
      data['replacesStudentGeneration'] == null;
}

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
  if (sameSavedRecord(queued['collection']?.toString() ?? '', local, cloud)) return 'identical';
  return 'differs (revision order unknown)';
}

/// Only an identical complete value for the same logical record is disposable.
/// Partial updates, deletes, recreation intents and owner/media changes retain
/// their originals for explicit review. No name/phone similarity heuristic.
bool automaticDuplicateReadback(Map queued, Map cloud) {
  final id = queued['documentId'];
  final revision = cloud['_syncRevision'];
  final data = queued['data'];
  return queued['operation'] == 'set' &&
      queued['collection'] != 'documents' &&
      queued['priorDeletion'] == null &&
      queued['reviewedFromOperationId'] == null &&
      queued['schoolId'] is String && (queued['schoolId'] as String).isNotEmpty &&
      id is String && id.isNotEmpty && cloud['id'] == id &&
      (cloud['documentId'] == null || cloud['documentId'] == id) &&
      revision is String && revision.isNotEmpty &&
      data is Map && (data['schoolId'] == null || data['schoolId'] == queued['schoolId']) &&
      !data.keys.any((key) => key.toString().startsWith('_syncRecreates')) &&
      (compareSyncVersions({...queued, 'data': {...data, 'schoolId': queued['schoolId']}}, cloud) == 'identical' ||
        identicalFreshStudent(queued, cloud));
}

/// Independently entered pupils have different generated identities/timestamps.
/// A slot/name alone never establishes equivalence. All business fields must
/// match, with populated parent and DOB evidence, and no replacement intent.
/// The durable writer must additionally reject any linked local child records.
bool identicalFreshStudent(Map queued, Map cloud) {
  final data = queued['data'];
  if (queued['collection'] != 'students_directory' || data is! Map ||
      (queued['baseCloudRevision'] ?? '') != '' ||
      data['replacesStudentGeneration'] != null ||
      cloud['replacesStudentGeneration'] != null ||
      data['mobileStableId'] is! String || cloud['mobileStableId'] is! String ||
      (data['mobileStableId'] as String).isEmpty || (cloud['mobileStableId'] as String).isEmpty ||
      data['mobileStableId'] == cloud['mobileStableId']) return false;
  for (final key in ['name', 'parentName', 'dateOfBirth', 'class', 'rollNo']) {
    if (data[key] is! String || (data[key] as String).trim().isEmpty ||
        data[key] != cloud[key]) return false;
  }
  const generated = {'mobileStableId', 'createdAt', 'updatedAt', 'studentUidTest'};
  Map business(Map row) => {
    for (final entry in row.entries)
      if (!generated.contains(entry.key)) entry.key: entry.value,
    'schoolId': queued['schoolId'],
  };
  return syncPayloadHash(business(data)) == syncPayloadHash(business(cloud));
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
bool verifiedDocumentAcknowledgement(Map payload, Map result, {String? action}) {
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
  if ((action ?? payload['action']) == 'delete_student_document') {
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

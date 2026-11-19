/// Transport-only Cloudflare ACK. This is NOT a canonical Drive record
/// revision or proof that a user file was written to Google Drive.
class CloudflareRecordHandoff implements Exception {
  const CloudflareRecordHandoff({
    required this.school,
    required this.collection,
    required this.id,
    required this.operationId,
    required this.ticketId,
    this.lane = 'records',
    this.mediaSourceHash,
    this.mediaFileSha256,
  });
  final String school, collection, id, operationId, ticketId, lane;
  final String? mediaSourceHash, mediaFileSha256;

  @override
  String toString() => 'Cloudflare accepted the original operation; '
      'provider delivery is independently pending.';
}

/// Real-school two-phase stage admission is negotiated from the existing,
/// authenticated broker capability. A valid school ID by itself NEVER
/// authorizes an early Cloudflare-only ACK.
bool eligibleForRecordHandoff(
  Map item,
  String school, {
  required bool edgeDeliverySupported,
}) {
  return edgeDeliverySupported &&
      RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school) &&
      item['schoolId'] == school &&
      item['collection'] is String &&
      (item['collection'] as String).isNotEmpty &&
      // Binary attachments and their Drive fileId-dependent metadata have a
      // different owner; stage them only after a separate file-first handoff.
      item['collection'] != 'documents' &&
      item['atomicBundleId'] == null &&
      item['priorDeletion'] == null &&
      ({'set','update'}.contains(item['operation']) &&
        item['data'] is Map ||
       item['operation'] == 'delete' &&
        item['baseCloudRevision'] is String &&
        (item['baseCloudRevision'] as String).isNotEmpty &&
        (item['collection'] != 'students_directory' ||
         item['deletedStudentGeneration'] is String &&
         RegExp(r'^p-[a-f0-9]{32,64}
      RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(item['operationId']) &&
      item['baseCloudRevision'] is String;
}


/// A staged ticket is not a final result. It may retire the original
/// locally retained operation only after the authenticated owner separately
/// proves a canonical revision for that exact same-school ticket.
bool verifiedStagedRecordFinal(Map original, Map journal, Map proof,
    String school) {
  final ticket=journal['ticketId'];
  if(ticket is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(ticket)||
      journal['schoolId']!=school||original['schoolId']!=school||
      journal['action']!='managed/records'||
      journal['originalOperationId']!=original['operationId']||
      journal['collection']!=original['collection']||
      journal['id']!=original['documentId']||
      original['cloudTicketId']!=ticket||
      original['cloudTicketLane']!='records'||
      original['syncState']!='cloudAccepted'||
      !{'set','update','delete'}.contains(original['operation'])||
      original['collection']=='documents'||
      original['atomicBundleId']!=null||
      original['priorDeletion']!=null||
      (original['operation']!='delete'&&original['data'] is! Map)||
      (original['operation']=='delete'&&
       (original['baseCloudRevision'] is! String||
        (original['baseCloudRevision'] as String).isEmpty||
        original['collection']=='students_directory'&&
        (original['deletedStudentGeneration'] is! String||
         !RegExp(r'^p-[a-f0-9]{32,64}
      proof['success']!=true||proof['schoolId']!=school||
      proof['cloudflareAccepted']!=true||
      proof['driveState']!='verified'||
      proof['syncProtocol']!=2||
      proof['recordRevision'] is! String||
      (proof['recordRevision'] as String).isEmpty)
    return false;
  final deleting=original['operation']=='delete';
  if(deleting &&
      (proof['deleteEverywhereVersion']!=1||
       proof['driveDeletionComplete']!=true||
       proof['firebaseDeletionComplete']!=true||
       proof['record'] is! Map||
       proof['record']['schoolId']!=school||
       proof['record']['_syncDeleted']!=true||
       proof['record']['_syncRevision']!=proof['recordRevision']||
       proof['record']['_syncOperationId']!=original['operationId']||
       proof['record']['_syncErasePlan'] is! Map||
       proof['record']['_syncErasePlan']['complete']!=true)) return false;
  final record=proof['record'];
  if(record is Map) {
    // A verified Script projection sometimes omits wrapper metadata. Its
    // signed broker owner still binds the immutable original operation ID
    // through the stored ticket. Reject any *present* contradictory identity.
    if(record['schoolId']!=school||
        (record['_syncRevision']!=null&&
         record['_syncRevision']!=proof['recordRevision'])||
        (record['_syncOperationId']!=null&&
         record['_syncOperationId']!=original['operationId'])||
        (record['id']!=null&&record['id']!=original['documentId']))
      return false;
  }
  return true;
}


/// The broker has verified the original Google file and its canonical
/// same-operation photo record; only this exact file/record pair may ACK.
bool verifiedStagedPhotoRecordFinal(Map original, Map journal, Map proof,
    String school) {
  final id=journal['ticketId'], media=proof['mediaRecord'];
  if(id is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)||
      journal['schoolId']!=school||original['schoolId']!=school||
      journal['action']!='managed/record/media/stage/resumable'||
      journal['originalOperationId']!=original['operationId']||
      journal['collection']!=original['collection']||
      journal['id']!=original['documentId']||
      original['cloudTicketId']!=id||
      original['cloudTicketLane']!='file-$id'||
      original['syncState']!='cloudAccepted'||
      !{'set','update'}.contains(original['operation'])||
      !{'students_directory','teachers_directory'}.contains(original['collection'])||
      original['atomicBundleId']!=null||original['priorDeletion']!=null||
      original['data'] is! Map||
      proof['success']!=true||proof['schoolId']!=school||
      proof['cloudflareAccepted']!=true||
      proof['driveState']!='verified'||proof['committed']!=true||
      proof['fileId'] is! String||proof['sha256'] is! String||
      media is! Map||media['collection']!=original['collection']||
      media['id']!=original['documentId']||
      media['operationId']!=original['operationId']||
      media['fileId']!=proof['fileId']||
      media['fileSha256']!=proof['sha256']||
      original['cloudMediaSourceHash']!=media['sourceHash']||
      original['cloudMediaFileSha256']!=media['fileSha256']||
      media['recordRevision'] is! String||
      (media['recordRevision'] as String).isEmpty||
      RegExp(r'^(live-|cf-)').hasMatch(media['recordRevision'])) return false;
  return true;
}
)
             .hasMatch(item['deletedStudentGeneration']))) &&
      item['operationId'] is String &&
      RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(item['operationId']) &&
      item['baseCloudRevision'] is String;
}


/// A staged ticket is not a final result. It may retire the original
/// locally retained operation only after the authenticated owner separately
/// proves a canonical revision for that exact same-school ticket.
bool verifiedStagedRecordFinal(Map original, Map journal, Map proof,
    String school) {
  final ticket=journal['ticketId'];
  if(ticket is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(ticket)||
      journal['schoolId']!=school||original['schoolId']!=school||
      journal['action']!='managed/records'||
      journal['originalOperationId']!=original['operationId']||
      journal['collection']!=original['collection']||
      journal['id']!=original['documentId']||
      original['cloudTicketId']!=ticket||
      original['cloudTicketLane']!='records'||
      original['syncState']!='cloudAccepted'||
      !{'set','update'}.contains(original['operation'])||
      original['collection']=='documents'||
      original['atomicBundleId']!=null||
      original['priorDeletion']!=null||
      original['data'] is! Map||
      proof['success']!=true||proof['schoolId']!=school||
      proof['cloudflareAccepted']!=true||
      proof['driveState']!='verified'||
      proof['syncProtocol']!=2||
      proof['recordRevision'] is! String||
      (proof['recordRevision'] as String).isEmpty)
    return false;
  final record=proof['record'];
  if(record is Map) {
    // A verified Script projection sometimes omits wrapper metadata. Its
    // signed broker owner still binds the immutable original operation ID
    // through the stored ticket. Reject any *present* contradictory identity.
    if(record['schoolId']!=school||
        (record['_syncRevision']!=null&&
         record['_syncRevision']!=proof['recordRevision'])||
        (record['_syncOperationId']!=null&&
         record['_syncOperationId']!=original['operationId'])||
        (record['id']!=null&&record['id']!=original['documentId']))
      return false;
  }
  return true;
}


/// The broker has verified the original Google file and its canonical
/// same-operation photo record; only this exact file/record pair may ACK.
bool verifiedStagedPhotoRecordFinal(Map original, Map journal, Map proof,
    String school) {
  final id=journal['ticketId'], media=proof['mediaRecord'];
  if(id is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)||
      journal['schoolId']!=school||original['schoolId']!=school||
      journal['action']!='managed/record/media/stage/resumable'||
      journal['originalOperationId']!=original['operationId']||
      journal['collection']!=original['collection']||
      journal['id']!=original['documentId']||
      original['cloudTicketId']!=id||
      original['cloudTicketLane']!='file-$id'||
      original['syncState']!='cloudAccepted'||
      !{'set','update'}.contains(original['operation'])||
      !{'students_directory','teachers_directory'}.contains(original['collection'])||
      original['atomicBundleId']!=null||original['priorDeletion']!=null||
      original['data'] is! Map||
      proof['success']!=true||proof['schoolId']!=school||
      proof['cloudflareAccepted']!=true||
      proof['driveState']!='verified'||proof['committed']!=true||
      proof['fileId'] is! String||proof['sha256'] is! String||
      media is! Map||media['collection']!=original['collection']||
      media['id']!=original['documentId']||
      media['operationId']!=original['operationId']||
      media['fileId']!=proof['fileId']||
      media['fileSha256']!=proof['sha256']||
      original['cloudMediaSourceHash']!=media['sourceHash']||
      original['cloudMediaFileSha256']!=media['fileSha256']||
      media['recordRevision'] is! String||
      (media['recordRevision'] as String).isEmpty||
      RegExp(r'^(live-|cf-)').hasMatch(media['recordRevision'])) return false;
  return true;
}
)
          .hasMatch(original['deletedStudentGeneration']))))||
      proof['success']!=true||proof['schoolId']!=school||
      proof['cloudflareAccepted']!=true||
      proof['driveState']!='verified'||
      proof['syncProtocol']!=2||
      proof['recordRevision'] is! String||
      (proof['recordRevision'] as String).isEmpty)
    return false;
  final record=proof['record'];
  if(record is Map) {
    // A verified Script projection sometimes omits wrapper metadata. Its
    // signed broker owner still binds the immutable original operation ID
    // through the stored ticket. Reject any *present* contradictory identity.
    if(record['schoolId']!=school||
        (record['_syncRevision']!=null&&
         record['_syncRevision']!=proof['recordRevision'])||
        (record['_syncOperationId']!=null&&
         record['_syncOperationId']!=original['operationId'])||
        (record['id']!=null&&record['id']!=original['documentId']))
      return false;
  }
  return true;
}


/// The broker has verified the original Google file and its canonical
/// same-operation photo record; only this exact file/record pair may ACK.
bool verifiedStagedPhotoRecordFinal(Map original, Map journal, Map proof,
    String school) {
  final id=journal['ticketId'], media=proof['mediaRecord'];
  if(id is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)||
      journal['schoolId']!=school||original['schoolId']!=school||
      journal['action']!='managed/record/media/stage/resumable'||
      journal['originalOperationId']!=original['operationId']||
      journal['collection']!=original['collection']||
      journal['id']!=original['documentId']||
      original['cloudTicketId']!=id||
      original['cloudTicketLane']!='file-$id'||
      original['syncState']!='cloudAccepted'||
      !{'set','update'}.contains(original['operation'])||
      !{'students_directory','teachers_directory'}.contains(original['collection'])||
      original['atomicBundleId']!=null||original['priorDeletion']!=null||
      original['data'] is! Map||
      proof['success']!=true||proof['schoolId']!=school||
      proof['cloudflareAccepted']!=true||
      proof['driveState']!='verified'||proof['committed']!=true||
      proof['fileId'] is! String||proof['sha256'] is! String||
      media is! Map||media['collection']!=original['collection']||
      media['id']!=original['documentId']||
      media['operationId']!=original['operationId']||
      media['fileId']!=proof['fileId']||
      media['fileSha256']!=proof['sha256']||
      original['cloudMediaSourceHash']!=media['sourceHash']||
      original['cloudMediaFileSha256']!=media['fileSha256']||
      media['recordRevision'] is! String||
      (media['recordRevision'] as String).isEmpty||
      RegExp(r'^(live-|cf-)').hasMatch(media['recordRevision'])) return false;
  return true;
}
)
             .hasMatch(item['deletedStudentGeneration']))) &&
      item['operationId'] is String &&
      RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(item['operationId']) &&
      item['baseCloudRevision'] is String;
}


/// A staged ticket is not a final result. It may retire the original
/// locally retained operation only after the authenticated owner separately
/// proves a canonical revision for that exact same-school ticket.
bool verifiedStagedRecordFinal(Map original, Map journal, Map proof,
    String school) {
  final ticket=journal['ticketId'];
  if(ticket is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(ticket)||
      journal['schoolId']!=school||original['schoolId']!=school||
      journal['action']!='managed/records'||
      journal['originalOperationId']!=original['operationId']||
      journal['collection']!=original['collection']||
      journal['id']!=original['documentId']||
      original['cloudTicketId']!=ticket||
      original['cloudTicketLane']!='records'||
      original['syncState']!='cloudAccepted'||
      !{'set','update'}.contains(original['operation'])||
      original['collection']=='documents'||
      original['atomicBundleId']!=null||
      original['priorDeletion']!=null||
      original['data'] is! Map||
      proof['success']!=true||proof['schoolId']!=school||
      proof['cloudflareAccepted']!=true||
      proof['driveState']!='verified'||
      proof['syncProtocol']!=2||
      proof['recordRevision'] is! String||
      (proof['recordRevision'] as String).isEmpty)
    return false;
  final record=proof['record'];
  if(record is Map) {
    // A verified Script projection sometimes omits wrapper metadata. Its
    // signed broker owner still binds the immutable original operation ID
    // through the stored ticket. Reject any *present* contradictory identity.
    if(record['schoolId']!=school||
        (record['_syncRevision']!=null&&
         record['_syncRevision']!=proof['recordRevision'])||
        (record['_syncOperationId']!=null&&
         record['_syncOperationId']!=original['operationId'])||
        (record['id']!=null&&record['id']!=original['documentId']))
      return false;
  }
  return true;
}


/// The broker has verified the original Google file and its canonical
/// same-operation photo record; only this exact file/record pair may ACK.
bool verifiedStagedPhotoRecordFinal(Map original, Map journal, Map proof,
    String school) {
  final id=journal['ticketId'], media=proof['mediaRecord'];
  if(id is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)||
      journal['schoolId']!=school||original['schoolId']!=school||
      journal['action']!='managed/record/media/stage/resumable'||
      journal['originalOperationId']!=original['operationId']||
      journal['collection']!=original['collection']||
      journal['id']!=original['documentId']||
      original['cloudTicketId']!=id||
      original['cloudTicketLane']!='file-$id'||
      original['syncState']!='cloudAccepted'||
      !{'set','update'}.contains(original['operation'])||
      !{'students_directory','teachers_directory'}.contains(original['collection'])||
      original['atomicBundleId']!=null||original['priorDeletion']!=null||
      original['data'] is! Map||
      proof['success']!=true||proof['schoolId']!=school||
      proof['cloudflareAccepted']!=true||
      proof['driveState']!='verified'||proof['committed']!=true||
      proof['fileId'] is! String||proof['sha256'] is! String||
      media is! Map||media['collection']!=original['collection']||
      media['id']!=original['documentId']||
      media['operationId']!=original['operationId']||
      media['fileId']!=proof['fileId']||
      media['fileSha256']!=proof['sha256']||
      original['cloudMediaSourceHash']!=media['sourceHash']||
      original['cloudMediaFileSha256']!=media['fileSha256']||
      media['recordRevision'] is! String||
      (media['recordRevision'] as String).isEmpty||
      RegExp(r'^(live-|cf-)').hasMatch(media['recordRevision'])) return false;
  return true;
}

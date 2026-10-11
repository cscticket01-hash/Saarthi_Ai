import 'dart:async';
import 'windows_local_firestore.dart';

typedef LocalRestoreCall = Future<Map<String,dynamic>> Function(Map<String,dynamic> body);

/// Completes an approved restore only after the original delete's durable ACK.
/// Bounded inventory reads retain both original operations on every failure.
Future<void> syncLocalRestoreRequests(FirebaseFirestore db, String school,
    LocalRestoreCall call) async {
  final origin = db.activeProfileId;
  void check() {
    if (db.activeProfileId != origin || db.activeProfileIdentity['schoolSyncId'] != school) {
      throw StateError('School changed during restore coordination.');
    }
  }
  check();
  final requests = await db.collection('_windows_recycle_requests').get();
  check();
  for (final row in requests.docs.where((r)=>r.data()['localRestore']==true &&
      r.data()['schoolId']==school && {'awaitingDeleteAck','awaitingCloudRestore','retry'}.contains(r.data()['state'])).take(3)) {
    final intent = row.data();
    final deletionId = intent['deletionOperationId'];
    if (deletionId is! String || intent['administratorApproved'] != true) continue;
    final evidence = (await db.collection('_windows_local_deletions').doc(deletionId).get()).data();
    check();
    if (evidence == null || evidence['schoolId'] != school || evidence['cloudDeletionVerified'] != true ||
        evidence['deletedRevision'] is! String) continue;
    final revision = evidence['deletedRevision'] as String;
    try {
      String? cursor;
      Map<String,dynamic>? selected;
      final retainedBody=intent['body'];
      if(retainedBody is Map && retainedBody['operation']=='restore' && retainedBody['operationId']==intent['operationId'] && retainedBody['expectedRecordRevision']==revision && retainedBody['fileId'] is String) {
        selected={'fileId':retainedBody['fileId']};
      }
      for (var page=0;selected==null && page<4;page++) {
        final inventory = await call({'operation':'list','collection':intent['collection'],'after':cursor??''}).timeout(const Duration(seconds:95));
        check();
        if (inventory['schoolId'] != school || inventory['recycleVersion'] != 1 || inventory['entries'] is! List || inventory['partial'] is! bool) {
          throw StateError('Authoritative same-school recycle inventory required.');
        }
        for(final candidate in inventory['entries'] as List) {
          if(candidate is Map && candidate['id']==intent['documentId'] &&
              candidate['collection']==intent['collection'] && candidate['deletedRevision']==revision) {
            selected=Map<String,dynamic>.from(candidate);break;
          }
        }
        if(selected!=null || inventory['partial']==false)break;
        cursor=inventory['nextAfter'] as String?;
        if(cursor==null || cursor.isEmpty)throw StateError('Incomplete recycle cursor.');
      }
      if(selected==null) {
        await row.reference.set({'state':'awaitingCloudRestore','reason':'snapshot_not_in_bounded_inventory'},const SetOptions(merge:true));
        continue;
      }
      if(selected['fileId'] is! String || selected['status']=='expired' || selected['status']=='needsReview') {
        await row.reference.set({'state':'conflict','reason':'snapshot_requires_administrator_review'},const SetOptions(merge:true));
        continue;
      }
      final body={'operation':'restore','fileId':selected['fileId'],'operationId':intent['operationId'],'expectedRecordRevision':revision};
      await row.reference.set({'state':'awaitingCloudRestore','body':body},const SetOptions(merge:true));
      check();
      final ack=await call(body).timeout(const Duration(seconds:95));
      check();
      if(ack['schoolId']!=school || ack['restored']!=true || ack['syncProtocol']!=2 ||
          ack['recordRevision'] is! String || ack['recordRevision']==revision || (ack['recordRevision'] as String).isEmpty) {
        throw StateError('Durable same-school restore ACK required.');
      }
      await db.finishLocalRestore(deletionId,expectedDeletedRevision:revision,restoredRevision:ack['recordRevision'] as String);
    } catch (_) {
      check();
      await row.reference.set({'state':'retry','reason':'restore_not_verified'},const SetOptions(merge:true));
      rethrow; // Existing capped engine backoff owns retries; no inner replay.
    }
  }
}

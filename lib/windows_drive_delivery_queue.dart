import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'cloudflare_record_handoff.dart';
import 'live_sync_protocol.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_local_firestore.dart';

/// This is a receipt journal, not a second record outbox. A committed live
/// operation leaves device-sync pending only after this journal is durable.
/// Drive completion never changes the canonical live revision or clears work.
class WindowsDriveDeliveryQueue {
  static const collection = '_windows_drive_deliveries';
  static final changed = ValueNotifier<int>(0);
  static bool _busy = false;
  static Future<void> _edgeWriteTail = Future<void>.value();
  static void _scope(String school, String profile) {
    final db = FirebaseFirestore.instance;
    if (db.activeProfileId != profile ||
        db.activeProfileIdentity['schoolSyncId'] != school) {
      throw StateError('School changed during Drive delivery tracking.');
    }
  }

  static Future<void> retain(
    String school,
    String recordCollection,
    String id,
    String operationId,
    Map<String, dynamic> ack, {
    bool deleting = false,
  }) async {
    if (!verifyLiveRecordReceipt(
      ack,
      school: school,
      collection: recordCollection,
      id: id,
      operationId: operationId,
      deleting: deleting,
    ))
      return;
    final db = FirebaseFirestore.instance,
        profile = FirebaseFirestore.instance.activeProfileId;
    _scope(school, profile);
    final ref = db.collection(collection).doc(operationId);
    final old = (await ref.get()).data();
    _scope(school, profile);
    if (old != null) {
      if (old['schoolId'] != school ||
          old['collection'] != recordCollection ||
          old['id'] != id ||
          old['recordRevision'] != ack['recordRevision']) {
        throw StateError(
          'Conflicting Drive receipt journal; original retained.',
        );
      }
      // A replay cannot regress a completed or review receipt to pending.
      return;
    }
    final verified = verifiedBackupReceipt({
      'schoolId': school,
      'operationId': operationId,
      'recordRevision': ack['recordRevision'],
    }, ack);
    if (ack['backupState'] == 'verified' && !verified) {
      throw StateError('Drive backup receipt did not verify.');
    }
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
      () => ref.set({
        'schoolId': school,
        'operationId': operationId,
        'collection': recordCollection,
        'id': id,
        'recordRevision': ack['recordRevision'],
        'liveProtocol': 1,
        // This only follows a validated, durably committed Cloudflare live
        // receipt; it is not evidence of Google Drive completion.
        'cloudflareAccepted': true,
        'operation': deleting ? 'delete' : 'write',
        'state': verified ? 'completed' : 'pending',
        'acceptedAt': DateTime.now().millisecondsSinceEpoch,
        'completedAt': verified ? DateTime.now().millisecondsSinceEpoch : 0,
        'attempts': 0,
        'nextPollAt': 0,
        if (verified) 'driveRevision': ack['driveRevision'],
      }),
    );
    _scope(school, profile);
    // Update the latest ACK notice immediately; periodic Drive status reads
    // must never be required to dismiss the app's outgoing sync spinner.
    changed.value++;
  }

  /// Track the existing staging lane independently of the native live lane.
  /// Only metadata is stored. A pending or completed receipt cannot clear the
  /// original record/file queue, whose existing version-safe ACK still owns it.
  static Future<void> retainEdge(Map<String, dynamic> notice) {
    final originalProof = notice['proof'];
    final copy = Map<String, dynamic>.from(notice);
    if (originalProof is Map) {
      final proof = Map<String, dynamic>.from(originalProof);
      if (proof['delivery'] is Map) {
        proof['delivery'] = Map<String, dynamic>.from(proof['delivery'] as Map);
      }
      copy['proof'] = proof;
    }
    final next = _edgeWriteTail.catchError((Object _) {}).then((_) => _retainEdge(copy));
    _edgeWriteTail = next;
    return next;
  }

  static Future<void> _retainEdge(Map<String, dynamic> notice) async {
    final school = notice['schoolId'], source = notice['source'];
    final proof = notice['proof'];
    if (school is! String || !validSchoolId(school) || source is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(source) || proof is! Map ||
        proof['success'] != true || proof['schoolId'] != school ||
        proof['cloudflareAccepted'] != true || proof['edgeDeliveryVersion'] != 1 ||
        !const ['managed/records', 'managed/records/batch', 'managed/file/upload', 'managed/document/stage/resumable', 'managed/record/media/stage/resumable'].contains(notice['action']) ||
        (notice['originalOperationId'] != null &&
          (notice['originalOperationId'] is! String ||
           !RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(notice['originalOperationId'])))) {
      throw StateError('Unverified Cloudflare staging receipt.');
    }
    final providerVerified = proof['driveState'] == 'verified', ticket = proof['delivery'];
    final authorized = notice['handoffAuthorized'] == true;
    final authorizedFile = authorized &&
        {'managed/document/stage/resumable','managed/record/media/stage/resumable'}.contains(notice['action']);
    final authorizedRecord = authorized && notice['action']=='managed/records';
    // An authenticated already-verified replay can still arrive before this
    // PC has committed its local CAS. Keep that journal pollable.
    final completed = providerVerified && !authorizedFile && !authorizedRecord;
    if (authorizedFile && (!{'pending','verified'}.contains(proof['driveState']) ||
        !authorizedPendingSidecar({...notice,'cloudflareAccepted':true,
          'edgeDeliveryVersion':1,'state':'pending',
          'ticketId':ticket is Map?ticket['id']:null,
          'lane':ticket is Map?ticket['lane']:null},school))) {
      throw StateError('Unverified original file handoff journal.');
    }
    if (authorized && !authorizedFile && (notice['action'] != 'managed/records' ||
        !{'write','delete'}.contains(notice['operation']) ||
        !{'pending','verified'}.contains(proof['driveState']) || ticket is! Map ||
        ticket['lane'] != 'records' ||
        exactStagedRecordTicket({
          'schoolId':school,'collection':notice['collection'],
          'documentId':notice['id'],'operationId':notice['originalOperationId'],
        },school) != ticket['id'])) {
      throw StateError('Unverified original record handoff journal.');
    }
    final review = completed && notice['action'] == 'managed/records/batch' && proof['batchComplete'] != true;
    if (completed && notice['action'] == 'managed/file/upload' &&
        (proof['committed'] != true || proof['fileId'] is! String || (proof['fileId'] as String).isEmpty)) {
      throw StateError('File bytes have no verified Drive completion.');
    }
    if (!completed && (!(proof['driveState'] == 'pending' ||
        (authorizedFile || authorizedRecord) && providerVerified) || ticket is! Map ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(ticket['id']?.toString() ?? '') ||
        !(ticket['lane'] == 'records' || ticket['lane'] == 'file-${ticket['id']}'))) {
      throw StateError('Unverified Cloudflare staging ticket.');
    }
    final db = FirebaseFirestore.instance, profile = db.activeProfileId;
    if (notice['profileId'] != profile) {
      throw StateError('School profile changed during Cloudflare delivery.');
    }
    _scope(school, profile);
    final operationId = 'edge-$source', ref = db.collection(collection).doc('edge-$source');
    final old = (await ref.get()).data();
    _scope(school, profile);
    if (old != null) {
      if (old['schoolId'] != school || old['edgeDeliveryVersion'] != 1 ||
          old['action'] != notice['action'] ||
          (old['originalOperationId']!=null &&
           notice['originalOperationId']!=null &&
           old['originalOperationId']!=notice['originalOperationId']) ||
          ticket is Map && old['ticketId'] != null && (old['ticketId'] != ticket['id'] || old['lane'] != ticket['lane'])) {
        throw StateError('Cloudflare staging receipt identity changed.');
      }
      if (const ['completed', 'needsAttention'].contains(old['state'])) return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
      () => ref.set({
        'schoolId': school, 'operationId': operationId, 'edgeDeliveryVersion': 1,
        'action': notice['action'], 'cloudflareAccepted': true,
        if (authorized || old?['handoffAuthorized'] == true)
          'handoffAuthorized': true,
        if (authorizedFile) 'fileSha256': notice['fileSha256'],
        if ((authorizedFile || authorizedRecord) && providerVerified)
          'providerVerifiedAwaitingLocalCas': true,
        if (authorizedFile && notice['mediaSourceHash'] is String)
          'mediaSourceHash': notice['mediaSourceHash'],
        if(notice['originalOperationId'] is String)
          'originalOperationId':notice['originalOperationId'],
        if(notice['originalOperationId'] is! String &&
           old?['originalOperationId'] is String)
          'originalOperationId':old!['originalOperationId'],
        if (notice['operation'] == 'write' || notice['operation'] == 'delete') 'operation': notice['operation'],
        'collection': notice['collection'] is String ? notice['collection'] : 'school_files',
        'id': notice['id'] is String ? notice['id'] : source.substring(0, 8),
        if (ticket is Map) 'ticketId': ticket['id'],
        if (ticket is Map) 'lane': ticket['lane'],
        if (ticket is! Map && old != null && old['ticketId'] != null) 'ticketId': old['ticketId'],
        if (ticket is! Map && old != null && old['lane'] != null) 'lane': old['lane'],
        'state': review ? 'needsAttention' : completed ? 'completed' : 'pending',
        'acceptedAt': old?['acceptedAt'] ?? now,
        'completedAt': completed && !review ? now : 0,
        if (completed && !review && proof['driveDurationMillis'] is int &&
            proof['driveDurationMillis'] >= 0)
          'driveDurationMillis': proof['driveDurationMillis'],
      }),
    );
    _scope(school, profile);
    changed.value++;
  }

  /// Restore a document's local handoff CAS without reading or uploading
  /// the file again. Both existing local generation rows must agree.
  static Future<bool> recoverDocumentHandoff(
      DocumentReference<Map<String,dynamic>> ref,
      Map<String,dynamic> original,Map journal,String school) async {
    final db=FirebaseFirestore.instance,profile=db.activeProfileId;
    ref.requireOriginProfile();
    _scope(school,profile);
    if(ref.collectionPath!='_windows_document_outbox' ||
        !recoverableStagedDocumentJournal(original,journal,school,ref.id))return false;
    final local=db.collection('_local_student_documents').doc(ref.id);
    final row=(await local.get()).data();
    _scope(school,profile);
    if(row==null || row['schoolId']!=school ||
       row['documentRevision']!=original['documentRevision'] ||
       row['contentHash']!=original['contentHash'] ||
       row['localPath']!=original['localPath'] ||
       row['deleted']==true)return false;
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() async {
      _scope(school,profile);
      final batch=db.batch();
      batch.requireUnchanged(ref,original);
      batch.requireUnchanged(local,row);
      batch.set(ref,{
        'syncState':'cloudAccepted',
        'cloudTicketId':journal['ticketId'],
        'cloudTicketLane':journal['lane'],
        'cloudContentHash':journal['fileSha256'],
        'cloudAcceptedAt':journal['acceptedAt'] is int
            ? journal['acceptedAt']:DateTime.now().millisecondsSinceEpoch,
      },const SetOptions(merge:true));
      batch.set(local,{'syncState':'CloudflareSaved'},const SetOptions(merge:true));
      await batch.commit();
    });
    _scope(school,profile);
    return true;
  }

  /// Bind the separate Drive proof to the exact accepted cloud operation.
  /// A canonical live record or a boolean alone cannot prove a Drive write.
  static bool verifiedBackupReceipt(Map journal, Map receipt) {
    final revision = receipt['driveRevision'];
    return receipt['liveProtocol'] == 1 &&
        receipt['schoolId'] == journal['schoolId'] &&
        receipt['operationId'] == journal['operationId'] &&
        receipt['recordRevision'] == journal['recordRevision'] &&
        receipt['cloudState'] == 'committed' &&
        receipt['backupState'] == 'verified' &&
        revision is String &&
        isDriveRecoveryRevision(revision);
  }

  /// Recreate only an absent *poll journal*, not a record, file or Cloudflare
  /// upload. An exact persisted handoff CAS plus an authenticated ticket-status
  /// read is required before inserting a new reviewable receipt.
  static Future<bool> recoverMissingReceiptJournals(
    String school, {
    required LiveSyncCall call,
    bool Function()? canAdmit,
    int limit=3,
  }) async {
    final db=FirebaseFirestore.instance,profile=db.activeProfileId;
    _scope(school,profile);
    if(limit<1 || limit>3)throw ArgumentError('Bounded recovery required');
    final journal=(await db.collection(collection).get()).docs;
    _scope(school,profile);
    final recordRows=(await db.collection('_windows_firebase_outbox').get()).docs;
    _scope(school,profile);
    final documentRows=(await db.collection('_windows_document_outbox').get()).docs;
    _scope(school,profile);
    final originals=<Map<String,dynamic>>[
      for(final row in recordRows)
        if(acceptedCloudflareTicketBinding(row.data(),school)!=null)
          acceptedCloudflareTicketBinding(row.data(),school)!,
      for(final row in documentRows)
        if(acceptedCloudflareTicketBinding(row.data(),school,queueId:row.id)!=null)
          acceptedCloudflareTicketBinding(row.data(),school,queueId:row.id)!,
    ];
    final seen=<String>{};
    var repaired=false,reads=0;
    for(final binding in originals){
      if(canAdmit?.call()==false||reads>=limit)break;
      _scope(school,profile);
      final id=binding['ticketId'] as String,lane=binding['lane'] as String;
      if(!seen.add('$lane/$id'))continue;
      // A pending or reviewable journal belongs to the original receipt
      // owner. Do not clear, reset or duplicate its backoff/review state.
      if(journal.any((row) {
        final j=row.data();
        return j['schoolId']==school && j['ticketId']==id &&
            j['lane']==lane && j['state']!='completed';
      }))continue;
      reads++;
      try {
        final proof=await call('managed/cloudflare/operation',{'lane':lane,'id':id});
        _scope(school,profile);
        if(proof['success']!=true || proof['schoolId']!=school ||
            proof['cloudflareAccepted']!=true ||
            !{'pending','verified'}.contains(proof['driveState']))
          continue;
        final remoteTicket=proof['delivery'];
        if(proof['driveState']=='pending' &&
            (remoteTicket is! Map ||
             remoteTicket['id']!=id || remoteTicket['lane']!=lane))continue;
        if(remoteTicket is Map &&
            (remoteTicket['id']!=id || remoteTicket['lane']!=lane))continue;
        final source=sha256.convert(utf8.encode(jsonEncode([
          school,'missing-receipt-v1',lane,id,binding['originalOperationId'],
        ]))).toString();
        await retainEdge({
          ...binding,
          'source':source,'profileId':profile,'handoffAuthorized':true,
          'proof':{'success':true,'schoolId':school,
            'edgeDeliveryVersion':1,'cloudflareAccepted':true,
            'driveState':proof['driveState'],
            'delivery':{'lane':lane,'id':id}},
        });
        _scope(school,profile);
        repaired=true;
      } catch (_) {
        _scope(school,profile);
        // No local marker changes on an unverified status response. The
        // original cloud-owned outbox is still durable for a later read.
      }
    }
    return repaired;
  }

  /// Original-operation status reads only. At most ten due receipts per pass;
  /// errors/backoff survive restart and never re-send a business mutation.
  static Future<void> poll(
    String school, {
    required LiveSyncCall call,
    bool Function()? canAdmit,
    DateTime Function()? clock,
    VoidCallback? onLocalSettlement,
  }) async {
    if (_busy || canAdmit?.call() == false) return;
    final now = clock ?? DateTime.now;
    final db = FirebaseFirestore.instance,
        profile = FirebaseFirestore.instance.activeProfileId;
    _scope(school, profile);
    _busy = true;
    try {
      // Recover a missing read-only receipt from the already persisted local
      // Cloudflare ticket; never generate a second business upload.
      await recoverMissingReceiptJournals(school,call:call,canAdmit:canAdmit);
      _scope(school,profile);
      final rows = (await db.collection(collection).get()).docs;
      _scope(school, profile);
      Future<void> pollLive() async {
        final due =
            rows.where((row) {
              final item = row.data();
              return item['schoolId'] == school &&
                  item['liveProtocol'] == 1 && item['edgeDeliveryVersion'] != 1 &&
                  item['state'] == 'pending' &&
                  (item['nextPollAt'] as num? ?? 0) <=
                      now().millisecondsSinceEpoch;
            }).toList()..sort(
              (a, b) => (a.data()['nextPollAt'] as num? ?? 0).compareTo(
                b.data()['nextPollAt'] as num? ?? 0,
              ),
            );
        for (final row in due.take(10)) {
          if (canAdmit?.call() == false) break;
          _scope(school, profile);
          final item = row.data();
          if (item['operationId'] is! String ||
              !RegExp(r'^[A-Za-z0-9_-]{16,100}$')
                  .hasMatch(item['operationId'] as String)) {
            throw StateError('Invalid retained Drive operation receipt.');
          }
          var values = <String, dynamic>{};
          var quota = false;
          try {
            final proof = await call('managed/live/operationReceipt', {
              'liveProtocol': 1,
              'operationId': item['operationId'],
            });
            _scope(school, profile);
            final receipt = proof['receipt'];
            if (proof['success'] != true ||
                proof['liveProtocol'] != 1 ||
                proof['schoolId'] != school ||
                proof['operationId'] != item['operationId'] ||
                proof['found'] != true ||
                receipt is! Map ||
                receipt['schoolId'] != school ||
                receipt['operationId'] != item['operationId'] ||
                receipt['recordRevision'] != item['recordRevision']) {
              throw StateError('Unverified Drive operation status.');
            }
            if (verifiedBackupReceipt(item, receipt)) {
              values = {
                'state': 'completed',
                'completedAt': now().millisecondsSinceEpoch,
                'nextPollAt': 0,
                'failureCode': null,
                'driveRevision': receipt['driveRevision'],
              };
            } else if (receipt['backupState'] == 'verified' ||
                proof['deliveryState'] == 'review' ||
                receipt['backupState'] == 'review') {
              values = {
                'state': 'needsAttention',
                'failureCode': 'DRIVE_ACK_REVIEW_REQUIRED',
              };
            } else {
              final retryAt = proof['retryAtMillis'];
              values = {
                'nextPollAt':
                    retryAt is int &&
                        retryAt > now().millisecondsSinceEpoch + 15000
                    ? retryAt
                    : now().millisecondsSinceEpoch + 15000,
              };
            }
          } catch (error) {
            _scope(school, profile);
            final attempts = (item['attempts'] as num? ?? 0).toInt() + 1;
            // Authentication/licence and transient status failures can recover.
            // Only an invalid retained request or an authenticated review state
            // requires review; a temporary403 never strands the receipt forever.
            final review = error is CentralCloudException && error.status == 400;
            quota = error is CentralCloudException && error.status == 429;
            final backoff = (15000 * (1 << attempts.clamp(0, 8).toInt()))
                .clamp(15000, 3600000)
                .toInt();
            final floor = error is CentralCloudException ? error.retryAfterMs : 0;
            values = {
              'state': review ? 'needsAttention' : 'pending',
              'attempts': attempts,
              'failureCode': review
                  ? 'DRIVE_DELIVERY_REVIEW_REQUIRED'
                  : 'DRIVE_DELIVERY_RETRY',
              'nextPollAt':
                  now().millisecondsSinceEpoch +
                  (floor > backoff ? floor : backoff),
            };
          }
          await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
            () => row.reference.set(values, const SetOptions(merge: true)),
          );
          _scope(school, profile);
          if (quota) break;
        }
      }
      Future<void> pollEdge() async {
        // Read-only status on the original, school-bound Cloudflare ticket.
        // Never re-submit a mutation or clear the original business outbox.
        final edgeDue = rows.where((row) {
          final v = row.data();
          return v['schoolId'] == school && v['edgeDeliveryVersion'] == 1 &&
              v['state'] == 'pending' &&
              (v['nextPollAt'] as num? ?? 0) <= now().millisecondsSinceEpoch;
        }).toList()..sort((a,b) =>
            (a.data()['nextPollAt'] as num? ?? 0)
                .compareTo(b.data()['nextPollAt'] as num? ?? 0));
        for (final row in edgeDue.take(3)) {
          if (canAdmit?.call() == false) break;
          _scope(school, profile);
          final item = row.data(), id = item['ticketId'], lane = item['lane'];
          if (id is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
              lane is! String ||
              !(lane == 'records' || lane == 'file-$id')) continue;
          Map<String,dynamic> values;
          var quota = false, settledLocal = false;
          try {
            final proof = await call('managed/cloudflare/operation', {
              'lane': lane, 'id': id,
            });
            _scope(school, profile);
            if (proof['success'] != true || proof['schoolId'] != school ||
                proof['cloudflareAccepted'] != true ||
                !const ['pending', 'verified'].contains(proof['driveState'])) {
              throw StateError('Unverified school Drive delivery progress.');
            }
            final ticket = proof['delivery'];
            if (proof['driveState'] == 'pending' &&
                (ticket is! Map || ticket['id'] != id || ticket['lane'] != lane)) {
              throw StateError('Drive delivery ticket changed.');
            }
            final deliveryStatus = proof['deliveryStatus'];
            final retryAt = deliveryStatus is Map ? deliveryStatus['retryAtMillis'] : null;
            final earliest = now().millisecondsSinceEpoch + 5000;
            values = {
              'attempts': 0,
              'failureCode': null,
              'nextPollAt': retryAt is int && retryAt > earliest
                  ? retryAt : earliest,
            };
            final progress = proof['driveProgress'];
            if (lane == 'file-$id' && proof['driveState'] == 'pending' &&
                progress is Map && progress['version'] == 1 &&
                progress['acknowledgedBytes'] is int &&
                progress['totalBytes'] is int &&
                progress['totalBytes'] > 0 &&
                progress['acknowledgedBytes'] >= 0 &&
                progress['acknowledgedBytes'] < progress['totalBytes']) {
              final old = item['driveProgress'];
              if (old is! Map || old['totalBytes'] == progress['totalBytes'] &&
                  (old['acknowledgedBytes'] as num? ?? 0) <=
                      progress['acknowledgedBytes']) {
                values['driveProgress'] = Map<String,dynamic>.from(progress);
              }
            }
            if (proof['driveState'] == 'verified') {
              // The original staged mutation stays in durable local CAS outbox
              // until this exact broker-owned ticket proves its final revision.
              if (lane=='records'&&item['originalOperationId'] is String) {
                final originals=(await db.collection('_windows_firebase_outbox').get()).docs
                    .where((row) {
                      final data=row.data(), prior=data['priorCloudWrite'];
                      return data['schoolId']==school &&
                          (data['operationId']==item['originalOperationId'] ||
                           prior is Map && prior['operationId']==item['originalOperationId'] &&
                           prior['schoolId']==school && prior['collection']==data['collection'] &&
                           prior['documentId']==data['documentId']);
                    }).toList();
                _scope(school, profile);
                if(originals.length>1) {
                  throw StateError('Multiple original record owners detected.');
                }
                if(originals.length==1) {
                  final current=originals.single.data();
                  final nested=current['priorCloudWrite'];
                  var original=current['operationId']==item['originalOperationId']
                      ? current : Map<String,dynamic>.from(nested as Map);
                  // Recover a crash between journal and local CAS only if
                  // that exact first-phase admission was explicitly authorized.
                  if (recoverableStagedRecordJournal(original,item,school)) {
                    await db.recordOutboxCloudHandoff(originals.single.reference,
                      original,ticketId:id);
                    _scope(school, profile);
                    final reread=(await originals.single.reference.get()).data();
                    _scope(school, profile);
                    if(reread==null||reread['operationId']!=item['originalOperationId'])
                      throw StateError('Original changed during handoff recovery.');
                    original=reread;
                  }
                  if(!verifiedStagedRecordFinal(original,item,proof,school))
                    throw StateError('Canonical staged record revision unverified; original retained.');
                  await db.acknowledgeOutbox(originals.single.reference,original,
                      revision:proof['recordRevision']);
                  _scope(school, profile);
                  settledLocal = true;
                }
              }
              if (lane == 'file-$id' &&
                  (proof['committed'] != true ||
                   proof['fileId'] is! String ||
                   (proof['fileId'] as String).isEmpty)) {
                throw StateError('Drive file completion unverified.');
              }
              if (lane == 'file-$id' &&
                  item['action'] == 'managed/record/media/stage/resumable') {
                final media=proof['mediaRecord'];
                if (media is! Map ||
                    media['collection'] != item['collection'] ||
                    media['id'] != item['id'] ||
                    media['operationId'] != item['originalOperationId'] ||
                    media['fileId'] != proof['fileId'] ||
                    media['fileSha256'] != proof['sha256'] ||
                    media['recordRevision'] is! String ||
                    (media['recordRevision'] as String).isEmpty) {
                  throw StateError('Original photo record has no verified Google proof.');
                }
                final matches=(await db.collection('_windows_firebase_outbox').get())
                    .docs.where((entry)=>
                      entry.data()['operationId']==item['originalOperationId'] &&
                      entry.data()['collection']==item['collection'] &&
                      entry.data()['documentId']==item['id'] &&
                      entry.data()['schoolId']==school).toList();
                _scope(school, profile);
                if(matches.length>1) {
                  throw StateError('Multiple original photo record owners detected.');
                }
                if(matches.length==1) {
                  var original=matches.single.data();
                  if(recoverableStagedPhotoJournal(original,item,school)) {
                    await db.recordOutboxCloudHandoff(matches.single.reference,
                      original,ticketId:id,lane:lane,
                      mediaSourceHash:item['mediaSourceHash'] as String,
                      mediaFileSha256:item['fileSha256'] as String);
                    _scope(school,profile);
                    final reread=(await matches.single.reference.get()).data();
                    _scope(school,profile);
                    if(reread==null||reread['operationId']!=item['originalOperationId'])
                      throw StateError('Portrait generation changed during recovery.');
                    original=reread;
                  }
                  if(original['syncState']!='cloudAccepted' &&
                      original['cloudTicketId']==null) {
                    throw StateError('Original portrait Cloudflare CAS not yet committed.');
                  }
                  if(!verifiedStagedPhotoRecordFinal(original,item,proof,school)) {
                    throw StateError('Photo record Drive and original CAS proof mismatch.');
                  }
                  await db.acknowledgeOutbox(matches.single.reference,original,
                    revision:media['recordRevision'] as String);
                  _scope(school, profile);
                  settledLocal = true;
                }
              }
              if (lane == 'file-$id' &&
                  item['action'] == 'managed/document/stage/resumable') {
                final document = proof['documentRecord'];
                final docId = item['id'], opId = item['originalOperationId'];
                if (docId is! String || docId.isEmpty ||
                    opId is! String ||
                    document is! Map ||
                    document['id'] != docId ||
                    document['operationId'] != opId ||
                    document['fileId'] != proof['fileId'] ||
                    document['recordRevision'] is! String ||
                    (document['recordRevision'] as String).isEmpty ||
                    document['contentHash'] is! String ||
                    !RegExp(r'^[a-f0-9]{64}$')
                        .hasMatch(document['contentHash'] as String)) {
                  throw StateError('Document metadata requires exact Google record proof.');
                }
                final ref = db.collection('_windows_document_outbox').doc(docId);
                final snapshot = await ref.get();
                _scope(school, profile);
                var original = snapshot.data();
                if (original != null && original['schoolId'] == school &&
                    original['documentRevision'] == opId) {
                  if(recoverableStagedDocumentJournal(original,item,school,docId)) {
                    await recoverDocumentHandoff(ref,original,item,school);
                    _scope(school,profile);
                    original=(await ref.get()).data();
                    _scope(school,profile);
                    if(original==null || original['documentRevision']!=opId)
                      throw StateError('Document generation changed during recovery.');
                  }
                  if (original['syncState'] != 'cloudAccepted' ||
                      original['cloudTicketId'] != id ||
                      original['cloudTicketLane'] != lane ||
                      original['contentHash'] != document['contentHash'] ||
                      original['cloudContentHash'] != document['contentHash']) {
                    throw StateError('Original document handoff has not yet committed.');
                  }
                  final local = db.collection('_local_student_documents').doc(docId);
                  final localSnapshot = await local.get();
                  _scope(school, profile);
                  final localRow = localSnapshot.data();
                  if (localRow?['schoolId'] != school ||
                      localRow?['documentRevision'] != opId ||
                      localRow?['contentHash'] != document['contentHash']) {
                    throw StateError('Document local generation changed; retain exact original.');
                  }
                  await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
                    () async {
                      _scope(school, profile);
                      final batch = db.batch();
                      // Exact local generation compare-and-swap inside the
                      // SQLite writer. A concurrent replacement must survive.
                      batch.requireUnchanged(ref, original);
                      batch.requireUnchanged(local, localRow);
                      batch.set(local, {
                        'syncState': 'Synced',
                        'cloudFileUrl': proof['fileUrl'],
                        'cloudRevision': opId,
                        'cloudRecordRevision': document['recordRevision'],
                        'cloudUploadedAt': localRow?['uploadedAt'],
                      }, const SetOptions(merge: true));
                      batch.delete(ref);
                      await batch.commit();
                    },
                  );
                  _scope(school, profile);
                  settledLocal = true;
                }
              }
              values = {
                'state': 'completed',
                'completedAt': now().millisecondsSinceEpoch,
                'nextPollAt': 0,
                'attempts': 0,
                'failureCode': null,
                if (proof['driveDurationMillis'] is int &&
                    proof['driveDurationMillis'] >= 0)
                  'driveDurationMillis': proof['driveDurationMillis'],
                'driveProgress': null,
              };
            }
          } catch (error) {
            _scope(school, profile);
            final attempts = (item['attempts'] as num? ?? 0).toInt() + 1;
            quota = error is CentralCloudException && error.status == 429;
            final backoff = (5000 * (1 << attempts.clamp(0, 8).toInt()))
                .clamp(5000, 3600000).toInt();
            final floor = error is CentralCloudException ? error.retryAfterMs : 0;
            // Only an authenticated, explicit owner-review state is terminal
            // to automatic polling. An unverified/malformed response remains
            // eligible for bounded readback; neither case clears original data.
            final review = error is CentralCloudException &&
                error.status == 409 &&
                error.diagnosticCode == 'EDGE_DELIVERY_REVIEW_REQUIRED';
            values = {
              'state': review ? 'needsAttention' : 'pending',
              'attempts': attempts,
              'failureCode': review
                  ? 'EDGE_DELIVERY_REVIEW_REQUIRED'
                  : quota ? 'SCRIPT_QUOTA_EXCEEDED' : 'DRIVE_DELIVERY_RETRY',
              'nextPollAt': now().millisecondsSinceEpoch +
                  (floor > backoff ? floor : backoff),
            };
          }
          await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
            () => row.reference.set(values, const SetOptions(merge:true)),
          );
          _scope(school, profile);
          // Notify the original scheduler only after durable local settlement.
          // An old receipt or status-only poll never wakes a mutation pass.
          if (settledLocal) {
            try { onLocalSettlement?.call(); } catch (_) {}
          }
          if (quota) break;
        }
      }
      // Each lane is serial and bounded internally, but a slow live receipt
      // cannot block edge receipt reconciliation (or vice versa). No business
      // mutation is submitted by either lane. Drain both before releasing busy.
      await Future.wait<void>([pollLive(), pollEdge()], eagerError: false);
      _scope(school, profile);
      changed.value++;
    } finally {
      _busy = false;
    }
  }

  static List<Map<String, dynamic>> serverHistory(Map value, String school) {
    final entries = value['entries'];
    if (value['success'] != true ||
        value['schoolId'] != school ||
        value['liveProtocol'] != 1 ||
        entries is! List ||
        entries.length > 25)
      throw StateError('Unverified school Drive history.');
    final result = <Map<String, dynamic>>[];
    for (final row in entries) {
      if (row is! Map ||
          row['operationId'] is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{16,100}$')
              .hasMatch(row['operationId'] as String) ||
          row['collection'] is! String ||
          !liveSyncCollections.contains(row['collection']) ||
          row['id'] is! String ||
          (row['id'] as String).isEmpty ||
          (row['id'] as String).length > 200 ||
          !const [
            'pending',
            'retry',
            'processing',
            'verified',
            'review',
          ].contains(row['state']) ||
          row['acceptedAt'] is! int ||
          row['acceptedAt'] < 0) {
        throw StateError('Unverified school Drive history entry.');
      }
      final verifiedAt = row['verifiedAt'];
      if (row['state'] == 'verified' &&
          (verifiedAt is! int ||
              verifiedAt <= 0 ||
              !isDriveRecoveryRevision(row['driveRevision']))) {
        throw StateError('Drive completion history has no verified revision.');
      }
      result.add({
        'id': row['operationId'],
        'cloudflareAccepted': true,
        'collection': row['collection'],
        'recordId': row['id'],
        'state': row['state'] == 'verified'
            ? 'completed'
            : row['state'] == 'review'
            ? 'needsAttention'
            : 'pending',
        'acceptedAt': row['acceptedAt'],
        'completedAt': row['state'] == 'verified' ? verifiedAt : 0,
      });
    }
    return result;
  }

  static Future<List<Map<String, dynamic>>> history(String school) async {
    final db = FirebaseFirestore.instance,
        profile = FirebaseFirestore.instance.activeProfileId;
    _scope(school, profile);
    final rows = (await db.collection(collection).get()).docs;
    _scope(school, profile);
    final entries = [
      for (final row in rows)
        if (row.data()['schoolId'] == school)
          Map<String, dynamic>.from(row.data()),
    ];
    entries.sort(
      (a, b) => (b['acceptedAt'] as num? ?? 0).compareTo(
        a['acceptedAt'] as num? ?? 0,
      ),
    );
    return entries
        .take(25)
        .map(
          (row) => {
            'id': row['operationId'],
            if (row['edgeDeliveryVersion'] == 1 || row['cloudflareAccepted'] == true)
              'cloudflareAccepted': true,
            'state': row['state'],
            'acceptedAt': row['acceptedAt'],
            'completedAt': row['completedAt'],
            'collection': row['collection'],
            'recordId': row['id'],
            if (row['operation'] == 'write' || row['operation'] == 'delete') 'operation': row['operation'],
            if (row['driveProgress'] is Map) 'driveProgress': row['driveProgress'],
            if (row['driveDurationMillis'] is int)
              'driveDurationMillis': row['driveDurationMillis'],
          },
        )
        .toList();
  }
}

import 'windows_shared_repair_knowledge.dart';
import 'windows_sync_comparison.dart';
import 'windows_local_firestore.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_sync_recovery.dart';

/// Durable automatic repair evidence. Never an upload receipt or cloud ACK.
class WindowsIdCardReviews {
  static const collection = '_windows_id_card_reviews';
  static void guard(String profile, String school) {
    final db = FirebaseFirestore.instance;
    if (db.activeProfileId != profile || db.activeProfileIdentity['schoolSyncId'] != school) {
      throw StateError('School changed during automatic card repair.');
    }
  }
  static Future<void> retain(PublishedIdInputConflict error, String name) async {
    final db = FirebaseFirestore.instance, profile = db.activeProfileId;
    final school = error.schoolId, id = error.documentId;
    if (school == null || id == null || error.inputRevision == null || error.cloudRevision == null) throw error;
    guard(profile, school);
    final ref = db.collection(collection).doc(id);
    final prior = (await ref.get()).data();
    guard(profile, school);
    // Re-observing identical protected evidence must not erase learned cooldown
    // or turn a previously verified retain decision into a new review.
    if (prior?['schoolId'] == school && prior?['documentId'] == id &&
        prior?['inputRevision'] == error.inputRevision && prior?['cloudRevision'] == error.cloudRevision &&
        prior?['personId'] == error.personId && prior?['personDocId'] == error.personDocId &&
        prior?['ownerRole'] == error.ownerRole) return;
    await ref.set({
      'schoolId': school, 'documentId': id, 'name': name, 'ownerRole': error.ownerRole,
      'personId': error.personId, 'personDocId': error.personDocId,
      'inputRevision': error.inputRevision, 'cloudRevision': error.cloudRevision,
      'status': 'needsReview', 'observedAt': DateTime.now().millisecondsSinceEpoch,
    });
    guard(profile, school);
  }
  static Future<bool> held(String school, String id, String inputRevision, Object? cachedRevision) async {
    final db = FirebaseFirestore.instance, profile = db.activeProfileId;
    guard(profile, school);
    final row = (await db.collection(collection).doc(id).get()).data();
    guard(profile, school);
    return row?['schoolId'] == school && row?['documentId'] == id &&
      row?['inputRevision'] == inputRevision && {'keepPublished', 'autoRetained'}.contains(row?['status']) &&
      (cachedRevision == null || row?['cloudRevision'] == cachedRevision);
  }
  static Future<List<Map<String, dynamic>>> pending(String school) async {
    final db = FirebaseFirestore.instance, profile = db.activeProfileId;
    if (db.activeProfileIdentity['schoolSyncId'] != school || school.isEmpty) return [];
    final rows = await db.collection(collection).get();
    guard(profile, school);
    final pending = <Map<String, dynamic>>[];
    for (final doc in rows.docs) {
      final item = doc.data();
      if (item['schoolId'] != school || item['status'] != 'needsReview') continue;
      final cached = (await db.collection('documents').doc(doc.id).get()).data();
      guard(profile, school);
      if (cached?['schoolId'] == school && (cached?['_syncDeleted'] == true ||
          cached?['_syncRevision'] != null && cached?['_syncRevision'] != item['cloudRevision'])) continue;
      pending.add({...item, 'documentId': doc.id});
    }
    return pending;
  }
  static Future<void> supersede(String school, String id) async {
    final db = FirebaseFirestore.instance, profile = db.activeProfileId;
    guard(profile, school);
    final ref = db.collection(collection).doc(id), row = (await ref.get()).data();
    guard(profile, school);
    if (row?['schoolId'] == school) await ref.update({'status': 'superseded'});
  }
  /// Adopt only signed, same-school, same-owner published evidence. A mismatch
  /// on a receiving PC is not authority to overwrite an existing cloud card.
  /// Failed verification remains durable and retries on the next sync cycle.
  static Future<void> repairPending(String school,
      {Future<Map<String, dynamic>> Function()? read, void Function(Map<String, dynamic>)? onRepair,
       bool explicitRetry = false, DateTime Function()? now}) async {
    final db = FirebaseFirestore.instance, profile = db.activeProfileId;
    final items = await pending(school);
    final clock = now ?? DateTime.now;
    items.sort((a,b) => ((a['lastRepairAttempt'] as num?)?.toInt() ?? 0).compareTo((b['lastRepairAttempt'] as num?)?.toInt() ?? 0));
    Future<Map<String, dynamic>>? inventory;
    var probes = 0;
    for (final item in items) {
      if (probes >= 20) break;
      guard(profile, school);
      final at = clock().millisecondsSinceEpoch;
      final signature = syncPayloadHash({for (final k in ['schoolId','documentId',
        'inputRevision','cloudRevision','personId','personDocId','ownerRole']) k: item[k]});
      final same = item['repairScope'] == signature;
      final attempts = same ? (item['repairAttempts'] as num? ?? 0).toInt().clamp(0, 1000000) : 0;
      if (!explicitRetry && same && (attempts >= 5 ||
          (item['nextRepairAt'] as num? ?? 0) > at)) continue;
      final ref = db.collection(collection).doc(item['documentId'] as String);
      final current = (await ref.get()).data();
      guard(profile, school);
      if (current?['status'] != 'needsReview' ||
          ['schoolId','inputRevision','cloudRevision','personId','personDocId','ownerRole']
            .any((k) => current?[k] != item[k])) continue;
      probes++;
      final learnedFloor=WindowsSharedRepairKnowledge.value('card_probe_cooldown',school,
        module:'documents',category:'idCardInputs')??120;
      final normalDelay=Duration(minutes:(2*(1<<attempts.clamp(0,5).toInt())).clamp(2,60).toInt()).inSeconds;
      final delaySeconds=(normalDelay>learnedFloor?normalDelay:learnedFloor).clamp(120,3600).toInt();
      await ref.update({'repairScope': signature, 'repairAttempts': attempts + 1,
        'lastRepairAttempt': at, 'nextRepairAt': at + Duration(seconds:delaySeconds).inMilliseconds});
      guard(profile, school);
      try {
        await keepPublished(profile, item, read: () => inventory ??= read?.call() ??
          ManagedSchoolSession.callForSchool(school, 'managed/records',
            {'operation': 'read', 'collection': 'documents', 'syncProtocol': 2}));
        onRepair?.call({'schoolId': school, 'stage': 'repairDiagnosed',
          'failureCategory': 'idCardInputs', 'outcome': 'verified_published_card_retained',
          'collection': 'documents', 'documentId': item['documentId'],
          'inputRevision': item['inputRevision'], 'at': clock().millisecondsSinceEpoch});
      } catch (error) {
        guard(profile, school);
        final ref = db.collection(collection).doc(item['documentId'] as String);
        final current = (await ref.get()).data();
        guard(profile, school);
        if (current?['status'] == 'needsReview' &&
            current?['inputRevision'] == item['inputRevision'] &&
            current?['cloudRevision'] == item['cloudRevision']) {
          await ref.update({'lastRepairAttempt': clock().millisecondsSinceEpoch,
            'repair': attempts + 1 >= 5
              ? 'Automatic repair budget reached; review the retained evidence or use manual Sync Now.'
              : 'Published evidence unavailable or changed; retry after the stored cooldown.'});
          onRepair?.call({'schoolId': school, 'stage': 'repairDiagnosed',
            'failureCategory': 'idCardInputs', 'outcome': attempts + 1 >= 5
              ? 'probe_budget_exhausted' : 'probe_deferred',
            'collection': 'documents', 'documentId': item['documentId'],
            'inputRevision': item['inputRevision'], 'at': clock().millisecondsSinceEpoch});
        }
      }
    }
  }
  static Future<void> keepPublished(String profile, Map<String, dynamic> captured,
      {Future<Map<String, dynamic>> Function()? read}) async {
    final school = captured['schoolId'] as String, id = captured['documentId'] as String;
    guard(profile, school);
    final reply = await (read?.call() ?? ManagedSchoolSession.callForSchool(school, 'managed/records',
      {'operation': 'read', 'collection': 'documents', 'syncProtocol': 2, 'id': id}));
    guard(profile, school);
    final row = (reply['records'] as Map?)?[id];
    if (reply['schoolId'] != school || reply['syncProtocol'] != 2 || row is! Map ||
        row['schoolId'] != school || row['id'] != null && row['id'] != id ||
        row['documentId'] != null && row['documentId'] != id ||
        row['_syncDeleted'] == true || row['documentKind'] != 'idCard' ||
        row['ownerRole'] != captured['ownerRole'] || row['studentId'] != captured['personDocId'] ||
        row['personId'] != captured['personId'] || row['_syncRevision'] != captured['cloudRevision'] ||
        row['contentHash'] is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(row['contentHash'])) {
      throw StateError('Published card changed or identity is unverified. Both versions remain protected.');
    }
    final ref = FirebaseFirestore.instance.collection(collection).doc(id), current = (await ref.get()).data();
    guard(profile, school);
    if (current?['schoolId'] != school || current?['inputRevision'] != captured['inputRevision'] ||
        current?['cloudRevision'] != captured['cloudRevision'] || current?['status'] != 'needsReview') {
      throw StateError('Card repair evidence changed; retry with the current revision.');
    }
    await ref.update({'status': 'autoRetained', 'repairedAt': DateTime.now().millisecondsSinceEpoch,
      'repair': 'Verified published card retained; no new generation or cloud write.'});
    guard(profile, school);
  }
}

import 'live_sync_protocol.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_local_firestore.dart';

/// This is a receipt journal, not a second record outbox. A committed live
/// operation leaves device-sync pending only after this journal is durable.
/// Drive completion never changes the canonical live revision or clears work.
class WindowsDriveDeliveryQueue {
  static const collection = '_windows_drive_deliveries';
  static bool _busy = false;
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
        'state': verified ? 'completed' : 'pending',
        'acceptedAt': DateTime.now().millisecondsSinceEpoch,
        'completedAt': verified ? DateTime.now().millisecondsSinceEpoch : 0,
        'attempts': 0,
        'nextPollAt': 0,
        if (verified) 'driveRevision': ack['driveRevision'],
      }),
    );
    _scope(school, profile);
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

  /// Original-operation status reads only. At most ten due receipts per pass;
  /// errors/backoff survive restart and never re-send a business mutation.
  static Future<void> poll(
    String school, {
    required LiveSyncCall call,
    bool Function()? canAdmit,
    DateTime Function()? clock,
  }) async {
    if (_busy || canAdmit?.call() == false) return;
    final now = clock ?? DateTime.now;
    final db = FirebaseFirestore.instance,
        profile = FirebaseFirestore.instance.activeProfileId;
    _scope(school, profile);
    _busy = true;
    try {
      final rows = (await db.collection(collection).get()).docs;
      _scope(school, profile);
      final due =
          rows.where((row) {
            final item = row.data();
            return item['schoolId'] == school &&
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
            'state': row['state'],
            'acceptedAt': row['acceptedAt'],
            'completedAt': row['completedAt'],
            'collection': row['collection'],
            'recordId': row['id'],
          },
        )
        .toList();
  }
}

import 'windows_sync_comparison.dart';
import 'school_profile_policy.dart';
import 'student_inventory_policy.dart';
import 'document_processing_engine.dart';
import 'school_qr_link.dart';
import 'id_card_engine.dart';

import 'package:crypto/crypto.dart' as crypto;

import 'dart:typed_data';

import 'document_pipeline.dart';
import 'windows_school_image_cache.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_school_map.dart';
import 'windows_connect/central_school_cloud.dart';
import 'windows_connect/google_authorization.dart';

import 'dart:async';
import 'dart:convert';
import 'windows_sync_projection.dart';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'windows_local_firestore.dart';
import 'windows_local_settings.dart';
import 'windows_local_storage.dart';
import 'windows_service_status.dart';
import 'windows_firebase_sync.dart';
import 'school_backend_transport.dart';
import 'windows_sync_recovery.dart';
import 'sync_recovery_policy.dart';

class WindowsBackendBridge {
  /// The exam editor is available even before a school connects its backend.
  /// Uses durable school-scoped storage and never labels a local save as cloud ACK.
  static Future<Map<String, dynamic>> localExamAction(
    Map<String, dynamic> body,
  ) async {
    final action = body['action']?.toString() ?? '';
    if (!const {
      'list_exam_center',
      'save_exam',
      'save_exam_result',
    }.contains(action)) {
      throw ArgumentError('Not an offline exam action');
    }
    await FirebaseFirestore.instance.ensureDurableSchoolRecords();
    return {
      ...await _handleLocal(action, body),
      'windowsLocalFallback': true,
      'sessionOnly': !await FirebaseFirestore.instance
          .localPersistenceEnabled(),
    };
  }

  WindowsBackendBridge._();

  // Response's default Latin-1 encoder rejects multilingual JSON metadata.
  static http.Response _jsonResponse(
    String body,
    int status, {
    Map<String, String>? headers,
  }) => http.Response.bytes(
    utf8.encode(body),
    status,
    headers: {...?headers, 'content-type': 'application/json; charset=utf-8'},
  );

  static String? normalizedDocumentPath(dynamic value) {
    if (value is! String) return null;
    final path = value.trim();
    if (path.isEmpty || path.startsWith('{') || path.startsWith('[') ||
        RegExp(r'[\x00-\x1f]').hasMatch(path) ||
        RegExp(r'[\uD800-\uDFFF]', unicode: true).hasMatch(path) ||
        RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://').hasMatch(path)) return null;
    if (Platform.isWindows) {
      if (!RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(path) &&
          !RegExp(r'^\\\\[^\\/]+[\\/][^\\/]+[\\/]').hasMatch(path)) return null;
      if (RegExp(r'[<>"|?*]').hasMatch(path.substring(2)) ||
          path.substring(2).contains(':')) return null;
    } else if (!path.startsWith('/')) {
      return null;
    }
    return File(path).absolute.path;
  }

  static Future<void> _documentTail = Future<void>.value();
  static bool _documentDraining = false;
  static Future<T> _documentWrite<T>(Future<T> Function() action) {
    final next = _documentTail.then((_) => action());
    _documentTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next;
  }

  static Future<void> changeLocalStorageLocation(String path) => _documentWrite(
    () => FirebaseFirestore.instance.changeLocalStorageLocation(path),
  );

  /// Lazy authenticated asset restore. Stable revision/hash filename avoids
  /// repeatedly downloading unchanged files; originals on this PC remain intact.
  static final Map<String, Future<Uint8List>> _documentRestores = {};
  static Future<Uint8List> documentBytes(
    Map<String, dynamic> document, {
    Future<Map<String, dynamic>> Function(String school, String fileId)? fetch,
  }) async {
    final profile = FirebaseFirestore.instance.activeProfileId;
    final key = jsonEncode([
      profile,
      document['schoolId'],
      document['fileId'],
      document['fileUrl'],
      document['documentRevision'],
      document['uploadedAt'],
      document['contentHash'],
      document['originalPath'],
      document['localPath'],
    ]);
    final existing = _documentRestores[key];
    if (existing != null) return existing;
    final pending = _restoreDocumentBytes(document, fetch: fetch);
    _documentRestores[key] = pending;
    try {
      return await pending;
    } finally {
      if (identical(_documentRestores[key], pending))
        _documentRestores.remove(key);
    }
  }

  static Future<Uint8List> _restoreDocumentBytes(
    Map<String, dynamic> document, {
    Future<Map<String, dynamic>> Function(String school, String fileId)? fetch,
  }) async {
    final db = FirebaseFirestore.instance,
        origin = FirebaseFirestore.instance.activeProfileId;
    final saved = await CentralSchoolCloud.saved(),
        school = saved['schoolId']?.toString() ?? '';
    void own() {
      if (db.activeProfileId != origin ||
          db.activeProfileIdentity['schoolSyncId'] != school ||
          document['schoolId'] != school)
        throw StateError('Foreign school document blocked.');
    }

    own();
    if (!await db.localPersistenceEnabled())
      throw StateError('Verified local school context required.');
    final root = await WindowsLocalStorage.localFilesDirectory();
    final schoolRoot = Directory(
      '${root.path}${Platform.pathSeparator}${_safeFileName(origin)}',
    );
    for (final source in [document['originalPath'], document['localPath']]) {
      final local = normalizedDocumentPath(source);
      if (local == null) continue;
      try {
        if (!await File(local).exists()) continue;
        final canonical = await File(local).resolveSymbolicLinks(),
            safeRoot = await schoolRoot.resolveSymbolicLinks();
        // A legacy/other-PC path is metadata, not permission to read that file.
        // Recover via the authenticated own-school cloud file instead.
        if (!canonical.startsWith('$safeRoot${Platform.pathSeparator}')) continue;
        own();
        final bytes = await File(canonical).readAsBytes();
        own();
        if (bytes.isNotEmpty) return bytes;
      } on FileSystemException { /* Retain the path; try authenticated restore. */ }
    }
    final id =
        document['fileId']?.toString() ??
        schoolDriveFileIdForDocument(document['fileUrl']?.toString() ?? '');
    if (!RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(id))
      throw StateError('Document cloud file is not available yet.');
    final key = crypto.sha256
        .convert(
          utf8.encode(
            '$school:$id:${document['documentRevision'] ?? document['uploadedAt']}',
          ),
        )
        .toString();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}${_safeFileName(origin)}${Platform.pathSeparator}restored_documents',
    );
    final cached = File('${directory.path}${Platform.pathSeparator}$key');
    if (await cached.exists()) {
      own();
      final bytes = await cached.readAsBytes();
      final hash = document['contentHash'];
      if (bytes.isNotEmpty &&
          bytes.length <= 20 * 1024 * 1024 &&
          (hash is! String ||
              crypto.sha256.convert(bytes).toString() == hash)) {
        own();
        return bytes;
      }
      // Retain a corrupt cache for diagnosis; replace it only after a valid download.
    }
    final result =
        await (fetch ??
            ((s, id) => ManagedSchoolSession.callForSchool(
              s,
              'managed/file/read',
              {'fileId': id},
            )))(school, id);
    own();
    if (result['success'] != true ||
        result['schoolId'] != school ||
        result['base64'] is! String)
      throw StateError('School document restore failed.');
    final bytes = Uint8List.fromList(base64Decode(result['base64']));
    if (bytes.isEmpty || bytes.length > 20 * 1024 * 1024)
      throw StateError('Invalid restored document size.');
    if (document['contentHash'] is String &&
        crypto.sha256.convert(bytes).toString() != document['contentHash'])
      throw StateError('Document hash mismatch.');
    await directory.create(recursive: true);
    own();
    final pending = File('${cached.path}.pending');
    await pending.writeAsBytes(bytes, flush: true);
    own();
    await pending.rename(cached.path);
    own();
    return bytes;
  }

  static String schoolDriveFileIdForDocument(String source) {
    final uri = Uri.tryParse(source);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host != 'drive.google.com' ||
        uri.userInfo.isNotEmpty)
      return '';
    return RegExp(
          r'^/file/d/([A-Za-z0-9_-]{1,200})/view$',
        ).firstMatch(uri.path)?.group(1) ??
        '';
  }

  /// Read-only proof from the owner-managed immutable local generation.
  static Future<Map<String, dynamic>> documentReviewPayload(
    String id,
    Map<String, dynamic> record,
  ) async {
    final db = FirebaseFirestore.instance,
        origin = FirebaseFirestore.instance.activeProfileId;
    if (record['schoolId'] != db.activeProfileIdentity['schoolSyncId'] ||
        record['deleted'] == true) {
      throw StateError(
        'Live same-school document required. Original retained.',
      );
    }
    final path = (record['optimizedPath'] ?? record['localPath'])?.toString() ?? '';
    if (path.isEmpty) throw StateError('Pending document file is missing.');
    final bytes = await File(path).readAsBytes();
    if (db.activeProfileId != origin)
      throw StateError('School changed. Reopen review.');
    return {
      ...record,
      'documentId': id,
      'action': 'upload_student_document',
      'contentHash': crypto.sha256.convert(bytes).toString(),
      'fileName': record['optimizedFileName'] ?? record['fileName'],
      'mimeType': record['optimizedMimeType'] ?? record['mimeType'],
    };
  }

  /// Explicit administrator readback resolution. Never uploads or changes cloud files.
  static Future<void> recordVerifiedDocumentReview(
    String id,
    Map<String, dynamic> expected,
  ) async {
    final db = FirebaseFirestore.instance,
        origin = FirebaseFirestore.instance.activeProfileId;
    final payload = await documentReviewPayload(id, expected);
    final reply = await ManagedSchoolSession.callForSchool(
      expected['schoolId'] as String,
      'managed/records',
      {'operation': 'read', 'collection': 'documents', 'syncProtocol': 2},
    );
    if (reply['syncProtocol'] != 2) throw const MissingSyncAcknowledgement();
    final cloud = (reply['records'] as Map?)?[id];
    final result = documentAcknowledgementFromReadback(payload, reply);
    if (!verifiedDocumentAcknowledgement(payload, result))
      throw const MissingSyncAcknowledgement();
    await _documentWrite(() async {
      if (db.activeProfileId != origin) throw StateError('School changed. Reopen review.');
      final queueRef = db.collection('_windows_document_outbox').doc(id);
      final current = (await queueRef.get()).data();
      if (current == null || syncPayloadHash(current) != syncPayloadHash(expected)) {
        throw StateError('Pending generation changed. Verify again.');
      }
      final freshPayload = await documentReviewPayload(id,current);
      if (!identicalDocumentPayload(freshPayload,cloud as Map)) throw const MissingSyncAcknowledgement();
      final localRef = db.collection('_local_student_documents').doc(id);
      final local = (await localRef.get()).data();
      if (local?['documentRevision'] != expected['documentRevision'] || local?['localPath'] != expected['localPath']) {
        throw StateError('Local generation changed. Verify again.');
      }
      final key = 'document-$id-${expected['documentRevision']}';
      final batch = db.batch();
      batch.set(db.collection('_windows_sync_conflict_history').doc(key), {
        ...expected,
        'verifiedCloud': cloud,
        'resolution': 'identical authenticated readback',
      });
      batch.set(db.collection('_windows_sync_receipts').doc(key), {
        'schoolId': expected['schoolId'],
        'operationId': expected['documentRevision'],
        'documentId': id,
        'collection': 'documents',
        'recordRevision': cloud['_syncRevision'],
        'contentHash': freshPayload['contentHash'],
        'verification': 'authenticated readback',
        'acknowledgedAt': DateTime.now().millisecondsSinceEpoch,
      });
      batch.set(localRef, {
        'syncState': 'Synced',
        'cloudFileUrl': cloud['fileUrl'],
        'cloudRevision': cloud['documentRevision'],
        'cloudUploadedAt': cloud['uploadedAt'],
      }, SetOptions(merge: true));
      batch.delete(
        queueRef,
      ); // Exact owner-locked acknowledged row only; original file retained.
      await batch.commit();
    });
  }

  /// Explicit same-school owner decision. No cloud write occurs here; local
  /// choice only queues a new immutable operation through the existing owner.
  static Future<void> resolveReviewedDocument({
    required String id,
    required Map<String, dynamic> expected,
    required Map<String, dynamic> reviewedCloud,
    required String choice,
    required String reason,
    required String reviewedLocalHash,
    Future<Map<String, dynamic>> Function()? readCloud,
    Future<Uint8List> Function(Map<String, dynamic>)? fetchBytes,
  }) async {
    final db = FirebaseFirestore.instance,
        origin = FirebaseFirestore.instance.activeProfileId;
    void guard() {
      if (db.activeProfileId != origin ||
          db.activeProfileIdentity['schoolSyncId'] != expected['schoolId'] ||
          db.activeProfileIdentity['blocked'] == true) {
        throw StateError('School changed or blocked. Reopen review.');
      }
    }

    guard();
    if (!{'local', 'cloud'}.contains(choice) ||
        reason.trim().isEmpty ||
        reason.length > 1000 ||
        expected['syncState'] != 'conflict' ||
        expected['deleted'] == true ||
        !await db.localPersistenceEnabled()) {
      throw StateError('Explicit live document conflict review required.');
    }
    final localProof = await documentReviewPayload(id, expected);
    if (localProof['contentHash'] != reviewedLocalHash)
      throw StateError('Local bytes changed since review. Verify again.');
    Future<Map<String, dynamic>> currentCloud() async {
      guard();
      final reply =
          await (readCloud?.call() ??
              ManagedSchoolSession.callForSchool(
                expected['schoolId'] as String,
                'managed/records',
                {
                  'operation': 'read',
                  'collection': 'documents',
                  'syncProtocol': 2,
                },
              ));
      guard();
      final row = (reply['records'] as Map?)?[id];
      if (reply['syncProtocol'] != 2 ||
          reply['schoolId'] != expected['schoolId'] ||
          row is! Map) {
        throw StateError('Authenticated same-school cloud readback required.');
      }
      final cloud = {...Map<String, dynamic>.from(row), 'id': id};
      if (row['id'] != null && row['id'] != id ||
          cloud['schoolId'] != expected['schoolId'] ||
          cloud['_syncDeleted'] == true ||
          cloud['studentId'] != expected['studentId'] ||
          cloud['documentKind'] != expected['documentKind'] ||
          cloud['ownerRole'] != expected['ownerRole'] ||
          cloud['personId'] != expected['personId'] ||
          cloud['documentRevision'] is! String ||
          cloud['documentRevision'].isEmpty ||
          cloud['_syncRevision'] is! String ||
          cloud['_syncRevision'].isEmpty ||
          cloud['contentHash'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(cloud['contentHash']) ||
          jsonEncode(cloud) != jsonEncode(reviewedCloud)) {
        throw StateError(
          'Cloud version or document ownership changed. Verify again.',
        );
      }
      return cloud;
    }

    final cloud = await currentCloud();
    Uint8List? bytes;
    if (choice == 'cloud') {
      // Remote paths are untrusted metadata, never a local read capability.
      final source = {...cloud}
        ..remove('localPath')
        ..remove('originalPath');
      bytes = await (fetchBytes?.call(source) ?? documentBytes(source));
      guard();
      if (bytes.isEmpty ||
          bytes.length > 20 * 1024 * 1024 ||
          crypto.sha256.convert(bytes).toString() != cloud['contentHash']) {
        throw StateError(
          'Selected cloud bytes failed verification. Original retained.',
        );
      }
      await currentCloud();
    }
    await _documentWrite(() async {
      guard();
      final queueRef = db.collection('_windows_document_outbox').doc(id);
      final localRef = db.collection('_local_student_documents').doc(id);
      final current = (await queueRef.get()).data(),
          local = (await localRef.get()).data();
      if (current == null ||
          syncPayloadHash(current) != syncPayloadHash(expected) ||
          local?['documentRevision'] != expected['documentRevision'] ||
          local?['localPath'] != expected['localPath']) {
        throw StateError('Pending generation changed. Verify again.');
      }
      final freshProof = await documentReviewPayload(id, current);
      if (freshProof['contentHash'] != localProof['contentHash']) {
        throw StateError('Local bytes changed. Verify again.');
      }
      final historyKey = 'document-$id-${expected['documentRevision']}';
      late Map<String, dynamic> replacement;
      if (choice == 'local') {
        // New operation identity prevents uncertain old attempts from being
        // replayed with a changed CAS baseline. Both generations remain archived.
        replacement =
            {
                ...current,
                'documentRevision': secureSetupToken(24),
                'baseCloudRevision': cloud['documentRevision'],
                'baseCloudUploadedAt': cloud['uploadedAt'],
                'syncState': 'Pending',
                'retryCount': 0,
                'retryAtMillis': 0,
                'uploadedAt': DateTime.now().millisecondsSinceEpoch,
                'reviewedRecordRevision': cloud['_syncRevision'],
                'reviewHistoryId': historyKey,
              }
              ..remove('lastError')
              ..remove('failureCategory');
      } else {
        final root = await WindowsLocalStorage.localFilesDirectory();
        final directory = Directory(
          '${root.path}/${_safeFileName(origin)}/reviewed_documents',
        );
        await directory.create(recursive: true);
        guard();
        final extension=switch(cloud['mimeType']){'application/pdf'=>'pdf','image/png'=>'png','image/jpeg'=>'jpg',_=>'bin'};
        final file = File('${directory.path}/${secureSetupToken(24)}.$extension');
        await file.writeAsBytes(bytes!, flush: true);
        guard();
        final diskHash=await crypto.sha256.bind(file.openRead()).first;
        if(await file.length()!=bytes!.length || diskHash.toString()!=cloud['contentHash'])throw StateError('Retained cloud copy failed independent disk verification. Originals retained.');
        guard();
        // A chosen cloud copy is a readback, never an ACK of the rejected local upload.
        replacement = {
          ...cloud,
          'documentId': id,
          'localPath': file.path,
          'originalPath': file.path,
          'optimizedPath': file.path,
          'processedPath': file.path,
          'optimizedFileName': cloud['fileName'],
          'optimizedMimeType': cloud['mimeType'],
          'fileUrl': Uri.file(file.path).toString(),
          'cloudFileUrl': cloud['fileUrl'],
          'cloudRevision': cloud['documentRevision'],
          'cloudUploadedAt': cloud['uploadedAt'],
          'baseCloudRevision': cloud['documentRevision'],
          'baseCloudUploadedAt': cloud['uploadedAt'],
          'syncState': 'Synced',
          'deleted': false,
          if (expected['inputRevision'] is String)
            'ownerCloudChoiceInputRevision': expected['inputRevision'],
          'reviewHistoryId': historyKey,
          'retainedPaths': [
            ...(local?['retainedPaths'] as List? ?? []),
            expected['localPath'],
          ],
        };
      }
      guard();
      await db.commitReviewedDocument(
        id: id,
        expected: expected,
        remote: cloud,
        selected: replacement,
        choice: choice,
        reason: reason,
        localHash: reviewedLocalHash,
      );
    });
    onLocalDocumentCommitted?.call();
  }

  // Retries reuse one durable deletion identity; later deletes after restore do not.
  static String documentDeleteOperationId(String id, Map data) => crypto.sha256
      .convert(utf8.encode('$id:${data['documentRevision'] ?? data['baseCloudRevision'] ?? ''}:delete'))
      .toString();

  static Future<bool> _prepareOwnerDocumentDeletion(String id, Map<String,dynamic> record, {Future<Map<String,dynamic>> Function(String)? readCloud}) async {
    final db = FirebaseFirestore.instance, origin = FirebaseFirestore.instance.activeProfileId;
    Future<Map<String,dynamic>?> evidence() async {
      final proof = (await db.collection('_windows_local_deletions').doc(record['parentDeletionOperationId']).get()).data();
      if (db.activeProfileId != origin || proof?['schoolId'] != record['schoolId'] ||
          proof?['operationId'] != record['parentDeletionOperationId'] ||
          proof?['collection'] != record['parentCollection'] || proof?['documentId'] != record['parentPersonId'] ||
          proof?['cloudDeletionVerified'] != true || proof?['deletedRevision'] is! String ||
          (proof!['deletedRevision'] as String).isEmpty ||
          (await db.collection(record['parentCollection']).doc(record['parentPersonId']).get()).exists) return null;
      return proof;
    }
    if (await evidence() == null) return false; // Wait for the parent's verified tombstone.
    // A separately admitted metadata operation must settle before the file owner deletes.
    final metadataQueue = await db.collection('_windows_firebase_outbox').get();
    if (metadataQueue.docs.any((d) => d.data()['collection'] == 'documents' &&
        d.data()['documentId'] == id)) return false;
    if (record['ownerDeleteBaselineVerified'] == true) return true;
    final reply = await (readCloud?.call(record['schoolId'] as String) ?? ManagedSchoolSession.callForSchool(record['schoolId'] as String,
      'managed/records', {'operation':'read','collection':'documents','syncProtocol':2}));
    if (db.activeProfileId != origin || reply['success'] != true || reply['syncProtocol'] != 2 ||
        reply['schoolId'] != record['schoolId'] || reply['records'] is! Map)
      throw const MissingSyncAcknowledgement();
    final remote = (reply['records'] as Map)[id];
    final role = record['parentCollection'] == 'students_directory' ? 'student' : 'teacher';
    final tombstone = remote is Map && remote['_syncDeleted'] == true;
    if (remote != null && (remote is! Map || remote['schoolId'] != record['schoolId'] ||
        (remote['id'] != null && remote['id'] != id) || (remote['documentId'] != null && remote['documentId'] != id) ||
        (!tombstone && (remote['studentId'] != record['studentId'] || remote['personId'] != record['personId'] ||
        (remote['ownerRole'] ?? (remote['studentId'] != null ? 'student' : null)) != role)) ||
        remote['_syncRevision'] is! String || (remote['_syncRevision'] as String).isEmpty ||
        (tombstone && remote['documentRevision'] != null && remote['documentRevision'] is! String) ||
        (!tombstone && (remote['documentRevision'] is! String || (remote['documentRevision'] as String).isEmpty))))
      throw StateError('Cloud document ownership changed. Review required.');
    return _documentWrite(() async {
      if (await evidence() == null) return false;
      final ref = db.collection('_windows_document_outbox').doc(id);
      final current = (await ref.get()).data();
      if (current == null || syncPayloadHash(current) != syncPayloadHash(record) || db.activeProfileId != origin) return false;
      final baseline = <String,dynamic>{
        'baseCloudRevision':remote is Map ? remote['documentRevision'] ?? '' : '',
        'baseCloudUploadedAt':remote is Map ? remote['uploadedAt'] : null,
        'reviewedRecordRevision':remote is Map ? remote['_syncRevision'] : '',
        'ownerDeleteBaselineVerified':true,
      };
      final batch = db.batch();
      batch.set(db.collection('_windows_sync_conflict_history').doc('owner-delete-cloud-$id-${record['documentRevision']}'), {
        'schoolId':record['schoolId'],'parentDeletionOperationId':record['parentDeletionOperationId'],
        'verifiedCloud':remote, 'resolution':'verified parent deletion; document tombstone queued',
      });
      batch.set(ref, baseline, SetOptions(merge:true));
      batch.set(db.collection('_local_student_documents').doc(id), baseline, SetOptions(merge:true));
      await batch.commit();
      record.addAll(baseline);
      return true;
    });
  }

  /// Same document writer as Save/ACK: a reconnect cannot overwrite a newer file.
  static Future<int> resumeNetworkDocuments(String profile, String school) =>
      _documentWrite(() async {
    final db=FirebaseFirestore.instance;
    if(db.activeProfileId!=profile)return 0;
    var resumed=0;
    final rows=await db.collection('_windows_document_outbox').get();
    for(final row in rows.docs) {
      final item=row.data();
      if(item['schoolId']!=school || !networkRecoveryCandidate(item))continue;
      if(db.activeProfileId!=profile)return resumed;
      await row.reference.set({...item,'syncState':'retry','retryCount':0,
        'retryAtMillis':DateTime.now().millisecondsSinceEpoch});
      resumed++;
    }
    return resumed;
  });

  static Future<void> flushDocumentPending({
    Future<Map<String,dynamic>> Function(String)? readDeletionCloud,
    Future<Map<String, dynamic>> Function(Map<String, dynamic>)? send,
    bool Function()? canAdmit,
    bool respectBackoff = false,
    bool Function(String, Map<String, dynamic>)? admitRow,
    void Function(Map<String, dynamic>)? onActivity,
  }) async {
    if (_documentDraining) return;
    _documentDraining = true;
    final origin = FirebaseFirestore.instance.activeProfileId;
    Object? firstDocumentFailure;
    StackTrace? documentFailureStack;
    try {
      await FirebaseFirestore.instance.reconcileDeletedOwnerDocuments();
      final queue = await FirebaseFirestore.instance
          .collection('_windows_document_outbox')
          .get();
      for (final queued in queue.docs) {
        if (canAdmit?.call() == false) break;
        if (FirebaseFirestore.instance.activeProfileId != origin)
          throw StateError('School changed during document sync.');
        final record = queued.data();
        if (admitRow?.call(queued.id, record) == false) continue;
        if (respectBackoff && admitRow == null && (record['retryAtMillis'] as num? ?? 0) > DateTime.now().millisecondsSinceEpoch) continue;
        void report(String stage, {String? category, DateTime? retryAt}) {
          try {
            onActivity?.call({
              'queueCollection': '_windows_document_outbox',
              'queueId': queued.id,
              'operationId': record['documentRevision'],
              'schoolId': record['schoolId'],
              'stage': stage,
              'at': DateTime.now().millisecondsSinceEpoch,
              'isRetryable':
                  stage == 'retry' &&
                  {'networkPath', 'timeout', 'server'}.contains(category),
              if (category != null) 'failureCategory': category,
              if (retryAt != null) 'retryAt': retryAt.millisecondsSinceEpoch,
            });
          } catch (_) {}
        }

        if (record['syncState'] == 'conflict' ||
            record['syncState'] == 'needsAttention')
          continue;
        var failureStage = 'prepare';
        try {
          final identity = await CentralSchoolCloud.saved();
          if (record['schoolId'] != identity['schoolId'] ||
              FirebaseFirestore.instance.activeProfileId != origin)
            throw StateError('Pending document belongs to another school.');
          if(smartSyncDecision(record,school:identity['schoolId'] as String,
              nowMillis:DateTime.now().millisecondsSinceEpoch,
              respectBackoff:respectBackoff&&admitRow==null)['canAttempt']!=true)continue;
          if (record['parentDeletionOperationId'] is String) {
            if (!await _prepareOwnerDocumentDeletion(queued.id, record, readCloud:readDeletionCloud)) continue;
          }
          failureStage = 'readLocalFile';
          final path =
              record['optimizedPath']?.toString() ??
              record['localPath']?.toString() ??
              '';
          final generationPath = record['localPath'];
          if (path.isEmpty && record['deleted'] != true)
            throw StateError('Pending document file is missing.');
          final bytes = record['deleted'] == true
              ? <int>[]
              : await File(path).readAsBytes();
          if (FirebaseFirestore.instance.activeProfileId != origin)
            throw StateError('School changed before upload.');
          final payload = <String, dynamic>{
            for (final key in [
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
            ])
              key: record[key],
            'action': record['deleted'] == true
                ? 'delete_student_document'
                : 'upload_student_document',
            'fileName': record['optimizedFileName'] ?? record['fileName'],
            'mimeType': record['optimizedMimeType'] ?? record['mimeType'],
            'documentId': queued.id,
            if (record['deleted'] == true) 'deleteOperationId':documentDeleteOperationId(queued.id, record),
            'schoolId': record['schoolId'],
            'documentRevision': record['documentRevision'],
            if (record['uploadedAt'] is num && record['uploadedAt'] > 0) 'uploadedAt':record['uploadedAt'],
            'sizeBytes': record['sizeBytes'],
            'sourceBytes': record['sourceBytes'],
            'contentHash': crypto.sha256.convert(bytes).toString(),
            'cleanupStatus': record['cleanupStatus'],
            'targetMet': record['targetMet'],
            'baseCloudRevision': record['baseCloudRevision'] ?? '',
            'baseCloudUploadedAt': record['baseCloudUploadedAt'],
            if (record['reviewedRecordRevision'] is String)
              'reviewedRecordRevision': record['reviewedRecordRevision'],
            'fileBase64': base64Encode(bytes),
          };
          // A pause can arrive while preparing file bytes. Finish an admitted
          // upload and its ACK atomically, but do not start another request.
          if (canAdmit?.call() == false) break;
          if (admitRow?.call(queued.id, record) == false) continue;
          report('cloudRequest');
          failureStage = 'requestAndReadback';
          final response = (send ?? _handleCentral)(payload);
          report('waitingForAck');
          final result = await response;
          failureStage = 'verifyAcknowledgement';
          if (!verifiedDocumentAcknowledgement(payload, result))
            throw const MissingSyncAcknowledgement();
          failureStage = 'commitLocalReceipt';
          await _documentWrite(() async {
            if (FirebaseFirestore.instance.activeProfileId != origin)
              throw StateError('School changed during document sync.');
            final ref = FirebaseFirestore.instance
                .collection('_local_student_documents')
                .doc(queued.id);
            final current = (await ref.get()).data();
            final receiptId = 'document-${queued.id}-${record['documentRevision']}';
            await FirebaseFirestore.instance.collection('_windows_sync_receipts').doc(receiptId).set({
              'schoolId':record['schoolId'], 'operationId':record['documentRevision'],
              'collection':'documents', 'documentId':queued.id,
              'recordRevision':result['document']['_syncRevision'],
              'contentHash':payload['contentHash'], 'verification':result['verification'] ?? 'authenticated readback',
              'acknowledgedAt':DateTime.now().millisecondsSinceEpoch,
            });
            if (current?['documentRevision'] != record['documentRevision'] ||
                current?['localPath'] != generationPath ||
                current?['deleted'] != record['deleted']) {
              // The earlier version reached the cloud, but the replacement is
              // still pending. Advance only its compare-and-set baseline.
              if (current != null &&
                  current['baseCloudRevision'] == record['baseCloudRevision']) {
                final baseline = result['document'] is Map
                    ? result['document']['documentRevision']
                    : null;
                if (baseline != null) {
                  final batch = FirebaseFirestore.instance.batch();
                  batch.set(ref, {
                    'cloudRevision': baseline,
                    'baseCloudRevision': baseline,
                  }, SetOptions(merge: true));
                  batch.set(
                    FirebaseFirestore.instance
                        .collection('_windows_document_outbox')
                        .doc(queued.id),
                    {'baseCloudRevision': baseline},
                    SetOptions(merge: true),
                  );
                  await batch.commit();
                }
              }
              return;
            }
            final batch = FirebaseFirestore.instance.batch();
            batch.set(ref, {
              'cloudFileUrl': result['fileUrl'],
              'cloudRevision': result['document'] is Map
                  ? result['document']['documentRevision']
                  : record['baseCloudRevision'],
              'cloudUploadedAt': result['document'] is Map
                  ? result['document']['uploadedAt']
                  : record['baseCloudUploadedAt'],
              'syncState': 'Synced',
            }, SetOptions(merge: true));
            batch.delete(
              FirebaseFirestore.instance
                  .collection('_windows_document_outbox')
                  .doc(queued.id),
            );
            await batch.commit();
          });
          report('verified');
        } catch (error, stack) {
          final decision = windowsSyncRecovery(error);
          final attempts = (record['retryCount'] as num? ?? 0).toInt() + 1;
          final retryAt = decision.retry
              ? DateTime.now().add(decision.delay(attempts))
              : null;
          report(
            decision.kind == SyncFailureKind.conflict
                ? 'conflict'
                : decision.kind == SyncFailureKind.authorization
                ? 'unauthorized'
                : decision.retry
                ? 'retry'
                : 'needsAttention',
            category: decision.kind.name,
            retryAt: retryAt,
          );
          if (FirebaseFirestore.instance.activeProfileId == origin)
            await _documentWrite(() async {
              final current = (await queued.reference.get()).data();
              if (current != null &&
                  current['documentRevision'] == record['documentRevision'] &&
                  current['localPath'] == record['localPath']) {
                final conflict = decision.kind == SyncFailureKind.conflict;
                await queued.reference.set({
                  'syncState': conflict ? 'conflict' : decision.retry ? 'retry' : 'needsAttention',
                  'failureCategory':decision.kind.name,
                  ...documentFailureDiagnostic(error, failureStage),
                  if(retryAt!=null)'retryAtMillis':retryAt.millisecondsSinceEpoch,
                  'retryCount':
                      (current['retryCount'] as num? ?? 0).toInt() + 1,
                  'lastError': error is MissingSyncAcknowledgement ? error.toString() : decision.message,
                }, SetOptions(merge: true));
              }
            });
          final isolatedFileFailure=failureStage=='readLocalFile' && decision.kind==SyncFailureKind.fileMissing;
          if (isolatedFileFailure || failureStage!='commitLocalReceipt' && independentDocumentFailure(error)) {
            firstDocumentFailure ??= isolatedFileFailure ? const PendingDocumentFileFailure() : error;
            documentFailureStack ??= stack;
            continue; // Retain the failed row; independent documents may still sync.
          }
          rethrow;
        }
      }
      if (firstDocumentFailure != null) Error.throwWithStackTrace(firstDocumentFailure, documentFailureStack!);
    } finally {
      _documentDraining = false;
    }
  }

  static FutureOr<void> Function()? onRemoteAvailable;
  static FutureOr<void> Function()? onLocalDocumentCommitted;

  static const Set<String> _mutatingActions = <String>{
    'add_student',
    'edit_student',
    'delete_student',
    'change_student_class',
    'add_teacher',
    'edit_teacher',
    'delete_teacher',
    'update_teacher_schedule',
    'save_fee_payment',
    'upload_student_document',
    'delete_student_document',
    'save_exam',
    'save_exam_result',
    'mark_attendance',
    'mark_student_attendance',
    'mark_teacher_attendance',
    'save_school_profile',
  };

  static Future<http.Response> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) async {
    final status = WindowsServiceStatus.instance;
    final originProfile = FirebaseFirestore.instance.activeProfileId;
    final savedIdentity = await CentralSchoolCloud.saved();
    final localAction = _decodeBody(body);
    if (savedIdentity['managed'] == true &&
        {
          'list_student_documents',
          'upload_student_document',
          'delete_student_document',
        }.contains(localAction['action'])) {
      if (FirebaseFirestore.instance.activeProfileIdentity['blocked'] == true ||
          FirebaseFirestore.instance.activeProfileId != originProfile ||
          FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'] !=
              savedIdentity['schoolId'])
        throw StateError('School changed. Reopen documents.');
      if (localAction['action'] == 'list_student_documents') {
        final remote = await FirebaseFirestore.instance
            .collection('documents')
            .where('studentId', isEqualTo: localAction['studentId'])
            .get();
        final local = await FirebaseFirestore.instance
            .collection('_local_student_documents')
            .where('studentId', isEqualTo: localAction['studentId'])
            .get();
        if (FirebaseFirestore.instance.activeProfileId != originProfile)
          throw StateError('School changed while loading documents.');
        final manifest =
            (await FirebaseFirestore.instance
                    .collection('_windows_sync_manifest')
                    .get())
                .docs
                .where((d) => d.data()['collection'] == 'documents')
                .expand((d) => d.data()['deletedIds'] as List? ?? [])
                .toSet();
        final rows = <String, Map<String, dynamic>>{
          for (final d in remote.docs) d.id: {...d.data(), 'documentId': d.id},
          for (final d in local.docs)
            d.id:
                d.data()['syncState'] == 'Synced' &&
                    remote.docs.any((r) => r.id == d.id)
                ? {
                    ...d.data(),
                    ...remote.docs.firstWhere((r) => r.id == d.id).data(),
                    if (d.data()['cloudRevision'] !=
                        remote.docs
                            .firstWhere((r) => r.id == d.id)
                            .data()['documentRevision']) ...{
                      'originalPath': null,
                      'localPath': null,
                    },
                  }
                : d.data(),
        };
        return _jsonResponse(
          jsonEncode({
            'success': true,
            'documents': rows.values
                .where(
                  (r) =>
                      StudentInventoryPolicy.visible(r) &&
                      r['deleted'] != true &&
                      r['_syncDeleted'] != true &&
                      !(r['syncState'] == 'Synced' &&
                          manifest.contains(r['documentId'])),
                )
                .toList(),
            'localFirst': true,
          }),
          200,
        );
      }
      if (!await FirebaseFirestore.instance.localPersistenceEnabled())
        throw StateError(
          'Current school durable document storage is unavailable.',
        );
      if (localAction['action'] == 'delete_student_document') {
        final result = await _documentWrite(() async {
          if (FirebaseFirestore.instance.activeProfileId != originProfile)
            throw StateError('School changed before document removal.');
          final id = localAction['documentId']?.toString() ?? '';
          if (id.isEmpty || id.contains('/'))
            throw StateError('Invalid document ID.');
          final ref = FirebaseFirestore.instance
              .collection('_local_student_documents')
              .doc(id);
          final old =
              (await ref.get()).data() ??
              (await FirebaseFirestore.instance
                      .collection('documents')
                      .doc(id)
                      .get())
                  .data();
          if (old == null) return {'success': true};
          if (old['studentId'] != localAction['studentId'])
            throw StateError('Document belongs to another student.');
          final metadata = {
            ...old,
            'documentId': id,
            'schoolId': savedIdentity['schoolId'],
            'deleted': true,
            'baseCloudRevision':
                old['cloudRevision'] ??
                old['baseCloudRevision'] ??
                old['documentRevision'] ??
                '',
            'baseCloudUploadedAt':
                old['cloudUploadedAt'] ??
                old['baseCloudUploadedAt'] ??
                old['uploadedAt'],
            'localPath': old['localPath'] ?? '',
            'syncState': 'Pending',
          };
          final batch = FirebaseFirestore.instance.batch();
          batch.set(ref, metadata);
          batch.set(
            FirebaseFirestore.instance
                .collection('_windows_document_outbox')
                .doc(id),
            metadata,
          );
          await batch.commit();
          return {'success': true, 'cloudSyncPending': true};
        });
        onLocalDocumentCommitted?.call();
        return _jsonResponse(jsonEncode(result), 200);
      }
      final result = await _documentWrite(() {
        if (FirebaseFirestore.instance.activeProfileId != originProfile)
          throw StateError('School changed before document save.');
        return _saveLocalStudentDocument({...localAction, '_queueCloud': true});
      });
      onLocalDocumentCommitted?.call();
      return _jsonResponse(
        jsonEncode({...result, 'cloudSyncPending': true}),
        200,
      );
    }
    if (savedIdentity['managed'] == true &&
        {
          'add_student',
          'edit_student',
          'delete_student',
          'change_student_class',
          'add_teacher',
          'edit_teacher',
          'delete_teacher',
          'update_teacher_schedule',
        }.contains(localAction['action'])) {
      if (FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'] !=
          savedIdentity['schoolId']) {
        throw StateError('School changed. Reopen the directory.');
      }
      if (!await FirebaseFirestore.instance.localPersistenceEnabled())
        throw StateError('Current school durable storage is unavailable.');
      final currentIdentity = await CentralSchoolCloud.saved();
      if (FirebaseFirestore.instance.activeProfileId != originProfile ||
          currentIdentity['schoolId'] != savedIdentity['schoolId'] ||
          currentIdentity['uid'] != savedIdentity['uid'])
        throw StateError('School changed. Reopen the directory.');
      // Directory screens commit the final record to the local database and
      // durable outbox. Keep photos local until that background sync uploads them.
      final raw = localAction['photoBase64']?.toString() ?? '';
      final photo = raw.isEmpty
          ? localAction['photoUrl']?.toString() ?? ''
          : raw.startsWith('data:')
          ? raw
          : 'data:${localAction['photoMimeType'] ?? 'image/jpeg'};base64,$raw';
      return _jsonResponse(
        jsonEncode({
          'success': true,
          'windowsLocalFallback': true,
          'cloudSyncPending': true,
          'schoolId': savedIdentity['schoolId'],
          'photoUrl': photo,
          if (localAction['action'] == 'add_teacher')
            'teacherId':
                localAction['teacherId'] ?? 'T-${secureSetupToken(12)}',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    status.checking(
      WindowsServiceType.googleDrive,
      'Google Drive / Apps Script request chal raha hai...',
    );

    // Hard isolation guard: a stale page/profile is never allowed to send a
    // request to an old school's Apps Script after the active Drive changes.
    final activeUrl = await WindowsExternalConnections.googleScriptUrl();
    if (activeUrl.isEmpty ||
        _normalizedUrl(activeUrl) != _normalizedUrl(url.toString())) {
      status.unhealthy(
        WindowsServiceType.googleDrive,
        'Inactive/old Google backend blocked by school isolation.',
      );
      return _localFallback(
        body,
        remoteError: 'Inactive Google backend blocked',
      );
    }

    final central = await CentralSchoolCloud.saved();
    if (central.isNotEmpty) {
      try {
        return _jsonResponse(
          jsonEncode(await _handleCentral(_decodeBody(body))),
          200,
          headers: {'content-type': 'application/json'},
        );
      } catch (_) {
        return _jsonResponse(
          jsonEncode({
            'success': false,
            'message': 'School cloud operation failed. Reconnect or retry the same school. Existing files are retained.',
          }),
          503,
          headers: {'content-type': 'application/json'},
        );
      }
    }
    Object? requestBody = body;
    try {
      final decoded = _decodeBody(body);
      final schoolSyncId =
          FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']
              ?.toString()
              .trim() ??
          '';
      if (schoolSyncId.isNotEmpty) {
        decoded['_windowsSchoolSyncId'] = schoolSyncId;
        requestBody = jsonEncode(decoded);
      }
    } catch (_) {
      // Keep the original body; normal validation/fallback will handle it.
    }

    try {
      final response = await _postFollowingAppsScriptRedirects(
        url,
        headers: headers,
        body: requestBody,
        encoding: encoding,
      ).timeout(const Duration(seconds: 30));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map) {
            final result = Map<String, dynamic>.from(decoded);
            final code = result['code']?.toString().trim().toUpperCase() ?? '';

            if (result['success'] == false) {
              status.unhealthy(
                WindowsServiceType.googleDrive,
                result['message']?.toString() ??
                    'School backend rejected the request.',
              );
              return response;
            }

            final school = await WindowsFirebaseRemote.status();
            if (!school.authenticated ||
                result['projectId'] != school.projectId) {
              status.unhealthy(
                WindowsServiceType.googleDrive,
                'School identity mismatch or secure Google backend update required.',
              );
              return _jsonResponse(
                jsonEncode({
                  'success': false,
                  'code': 'SCHOOL_PROJECT_MISMATCH',
                  'message': 'Connect the matching school Firebase and updated Google backend.',
                }),
                409,
                headers: {'content-type': 'application/json'},
              );
            }

            if (code == 'SCHOOL_SYNC_ID_MISMATCH') {
              status.unhealthy(
                WindowsServiceType.googleDrive,
                'Google backend blocked: School Sync ID mismatch.',
              );
              return response;
            }

            status.healthy(
              WindowsServiceType.googleDrive,
              'Google backend actual response OK (${response.statusCode}).',
            );

            final callback = onRemoteAvailable;
            if (callback != null) {
              Future<void>.microtask(() async {
                try {
                  await callback();
                } catch (_) {}
              });
            }

            return response;
          }
        } catch (_) {}

        status.unhealthy(
          WindowsServiceType.googleDrive,
          'Google backend response JSON invalid hai.',
        );
        return _localFallback(
          requestBody,
          remoteError: 'Invalid JSON response',
        );
      }

      status.unhealthy(
        WindowsServiceType.googleDrive,
        'Google backend HTTP ${response.statusCode}. Local fallback active hai.',
      );

      await _queueFailedMutation(url, headers: headers, body: requestBody);

      return _localFallback(
        requestBody,
        remoteError: 'HTTP ${response.statusCode}',
      );
    } catch (e) {
      status.unhealthy(
        WindowsServiceType.googleDrive,
        'Google backend unavailable: $e. Local fallback active hai.',
      );

      await _queueFailedMutation(url, headers: headers, body: requestBody);

      return _localFallback(requestBody, remoteError: e.toString());
    }
  }

  static Future<int> pendingMutationCount() async {
    final snapshot = await FirebaseFirestore.instance
        .collection('_windows_google_outbox')
        .get();
    return snapshot.docs.length;
  }

  static Future<int> flushPending({bool Function()? canAdmit, bool respectBackoff = false,
    void Function(Map<String, dynamic>)? onActivity,
    Future<String> Function()? readActiveUrl,
    Future<http.Response> Function(Uri, Map<String, String>, String)? send,
  }) async {
    final snapshot = await FirebaseFirestore.instance
        .collection('_windows_google_outbox')
        .get();

    if (snapshot.docs.isEmpty) {
      return 0;
    }

    var completed = 0;
    final activeUrl = await (readActiveUrl ?? WindowsExternalConnections.googleScriptUrl)();

    final docs = snapshot.docs.toList()
      ..sort((a, b) {
        final av = _millis(a.data()['queuedAt']);
        final bv = _millis(b.data()['queuedAt']);
        return av.compareTo(bv);
      });

    for (final queued in docs) {
      if (canAdmit?.call() == false) break;
      final data = queued.data();
      final urlText = data['url']?.toString().trim() ?? '';
      final bodyData = data['body'];
      void report(String stage, {String? category}) {
        try {
          onActivity?.call({
            'queueCollection': '_windows_google_outbox',
            'queueId': queued.id,
            'operationId': bodyData is Map ? bodyData['operationId'] : null,
            'schoolId': bodyData is Map ? bodyData['schoolId'] : null,
            'stage': stage,
            'at': DateTime.now().millisecondsSinceEpoch,
            'isRetryable': false,
            if (category != null) 'failureCategory': category,
          });
        } catch (_) {}
      }

      if (urlText.isEmpty || bodyData is! Map) {
        await queued.reference.update({
          'syncState': 'needsAttention',
          'lastError': 'Invalid pending request retained for administrator review.',
        });
        continue;
      }
      if (data['syncState'] == 'needsAttention' || data['syncState'] == 'conflict') continue;
      if(respectBackoff && (data['retryAtMillis'] as num? ?? 0)>DateTime.now().millisecondsSinceEpoch) continue;

      if (activeUrl.isEmpty ||
          _normalizedUrl(urlText) != _normalizedUrl(activeUrl)) {
        // Queue belongs to a different Drive profile. Never replay it into
        // the currently active school's backend.
        continue;
      }

      final headersRaw = data['headers'];
      final headers = <String, String>{};

      if (headersRaw is Map) {
        for (final entry in headersRaw.entries) {
          headers[entry.key.toString()] = entry.value.toString();
        }
      }

      try {
        if (canAdmit?.call() == false) break;
        report('cloudRequest');
        final requestHeaders = headers.isEmpty
            ? const {'Content-Type': 'text/plain;charset=utf-8'}
            : headers;
        final requestBody = jsonEncode(Map<String, dynamic>.from(bodyData));
        final pendingResponse =
            (send != null
                    ? send(Uri.parse(urlText), requestHeaders, requestBody)
                    : _postFollowingAppsScriptRedirects(
                        Uri.parse(urlText),
                        headers: requestHeaders,
                        body: requestBody,
                      ))
                .timeout(const Duration(seconds: 30));
        report('waitingForAck');
        final response = await pendingResponse;

        if (response.statusCode < 200 || response.statusCode >= 300) {
          final decision = SyncRecoveryDecision.classify(
            status: response.statusCode,
          );
          report(
            decision.retry ? 'retry' : 'needsAttention',
            category: decision.kind.name,
          );
          break;
        }

        final decoded = jsonDecode(response.body);

        if (decoded is! Map) {
          break;
        }

        final result = Map<String, dynamic>.from(decoded);

        final action = data['action']?.toString() ?? '';

        if (!_replayApplied(action, result)) {
          await queued.reference.update({
            'syncState': 'needsAttention',
            'lastError':
                'Legacy response did not verify the original mutation. Administrator review required.',
          });
          report('needsAttention', category: 'unknown');
          break;
        }
        final current=(await queued.reference.get()).data();
        if(current==null || jsonEncode(current['body'])!=jsonEncode(bodyData) || current['url']!=data['url']) {
          report('needsAttention',category:'unknown');
          break;
        }

        await queued.reference.delete();
        completed++;
        report('verified');
      } catch (error) {
        final decision = windowsSyncRecovery(error);
        report(
          decision.retry ? 'retry' : 'needsAttention',
          category: decision.kind.name,
        );
        break;
      }
    }

    return completed;
  }

  static Future<void> _queueFailedMutation(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
  }) async {
    Map<String, dynamic> decoded;

    try {
      decoded = _decodeBody(body);
    } catch (_) {
      return;
    }

    final action = decoded['action']?.toString().trim() ?? '';

    if (!_mutatingActions.contains(action)) {
      return;
    }

    final reference = FirebaseFirestore.instance
        .collection('_windows_google_outbox')
        .doc();

    await reference.set(<String, dynamic>{
      'action': action,
      'url': url.toString(),
      'headers':
          headers ??
          const <String, String>{'Content-Type': 'text/plain;charset=utf-8'},
      'body': decoded,
      'queuedAt': FieldValue.serverTimestamp(),
    });
  }

  static bool _replayApplied(String action, Map<String, dynamic> result) {
    if (result['success'] == true) {
      return true;
    }

    // Duplicate and missing-record text cannot verify the original intent.
    // Retain it for explicit authoritative readback rather than guessing ACK.
    return false;
  }

  static int _millis(dynamic value) {
    if (value is Timestamp) {
      return value.millisecondsSinceEpoch;
    }

    if (value is DateTime) {
      return value.millisecondsSinceEpoch;
    }

    if (value is num) {
      return value.toInt();
    }

    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static Future<http.Response> _postFollowingAppsScriptRedirects(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Encoding? encoding,
  }) async {
    // Proof is refreshed only for the outgoing request and is never stored in
    // the offline mutation queue or exposed through an ID-card QR.
    Object? verifiedBody = body;
    try {
      final data = _decodeBody(body);
      final school = await WindowsFirebaseRemote.status();
      if (school.authenticated) {
        data['schoolAdminIdToken'] = await WindowsFirebaseRemote.freshIdToken();
        data['schoolProjectId'] = school.projectId;
        verifiedBody = jsonEncode(data);
      }
    } catch (_) {}
    final client = http.Client();
    try {
      Future<http.Response> sendPost(Uri target) async {
        requireSchoolBackendUri(target);
        final request = http.Request('POST', target);
        if (headers != null) request.headers.addAll(headers);
        if (verifiedBody is String) {
          request.body = verifiedBody;
          if (encoding != null) request.encoding = encoding;
        } else if (verifiedBody is List<int>) {
          request.bodyBytes = verifiedBody;
        } else if (verifiedBody is Map<String, String>) {
          request.bodyFields = verifiedBody;
          if (encoding != null) request.encoding = encoding;
        } else if (verifiedBody != null) {
          request.body = verifiedBody.toString();
          if (encoding != null) request.encoding = encoding;
        }
        request.followRedirects = false;
        final streamed = await client.send(request);
        return http.Response.fromStream(streamed);
      }

      Future<http.Response> sendGet(Uri target) async {
        requireSchoolBackendUri(target);
        final request = http.Request('GET', target);
        request.headers['Accept'] = 'application/json,text/plain,*/*';
        request.followRedirects = false;
        final streamed = await client.send(request);
        return http.Response.fromStream(streamed);
      }

      var current = url;
      var response = await sendPost(current);
      for (var redirectCount = 0; redirectCount < 8; redirectCount++) {
        final code = response.statusCode;
        final isRedirect =
            code == 301 ||
            code == 302 ||
            code == 303 ||
            code == 307 ||
            code == 308;
        if (!isRedirect) return response;
        final location = response.headers['location']?.trim() ?? '';
        if (location.isEmpty) return response;
        current = current.resolve(location);
        response = (code == 301 || code == 302 || code == 303)
            ? await sendGet(current)
            : await sendPost(current);
      }
      return response;
    } finally {
      client.close();
    }
  }

  static Future<bool> testRemote(Uri url) async {
    final central = await CentralSchoolCloud.saved();
    if (central.isNotEmpty) {
      if (url.toString() != await WindowsExternalConnections.googleScriptUrl())
        return false;
      final cloud = CentralSchoolCloud(endpoint: central['endpoint']);
      try {
        if (central['managed'] == true) {
          final result = await ManagedSchoolSession.call(
            'managed/storage/check',
          );
          return result['storageReady'] == true;
        }
        final token = await cloud.googleToken(central);
        final folder = await cloud.send(
          'GET',
          url.replace(queryParameters: {'fields': 'id,trashed,appProperties'}),
          token: token,
        );
        return folder['trashed'] != true &&
            folder['appProperties']?['schoolId'] == central['schoolId'];
      } catch (_) {
        return false;
      } finally {
        cloud.close();
      }
    }
    final status = WindowsServiceStatus.instance;

    status.checking(
      WindowsServiceType.googleDrive,
      'Google Drive + Apps Script health check chal raha hai...',
    );

    try {
      // Use the same real health endpoint that is verified in the browser.
      // Existing Website / Android POST actions are untouched.
      final healthUrl = url.replace(
        queryParameters: <String, String>{
          ...url.queryParameters,
          'action': 'health_check',
          '_t': DateTime.now().millisecondsSinceEpoch.toString(),
        },
      );

      final response = await http
          .get(
            healthUrl,
            headers: const {
              'Accept': 'application/json',
              'Cache-Control': 'no-cache',
            },
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode < 200 || response.statusCode >= 300) {
        status.unhealthy(
          WindowsServiceType.googleDrive,
          'Google health check HTTP ${response.statusCode}.',
        );
        return false;
      }

      final decoded = jsonDecode(response.body);

      if (decoded is! Map) {
        throw const FormatException(
          'Google health-check response JSON map nahi hai.',
        );
      }

      final data = Map<String, dynamic>.from(decoded);

      final success = data['success'] == true;
      final working = data['working'] == true;
      final rootAccessible = data['rootFolderAccessible'] != false;

      if (!success || !working || !rootAccessible) {
        final message = data['error']?.toString().trim().isNotEmpty == true
            ? data['error'].toString()
            : data['message']?.toString().trim().isNotEmpty == true
            ? data['message'].toString()
            : 'Google Drive health check failed.';

        status.unhealthy(WindowsServiceType.googleDrive, message);
        return false;
      }

      final version = data['version']?.toString().trim() ?? '';

      status.healthy(
        WindowsServiceType.googleDrive,
        version.isEmpty
            ? 'Google Apps Script + Google Drive actual health check successful.'
            : 'Google Apps Script + Google Drive working • $version',
      );

      return true;
    } catch (e) {
      status.unhealthy(
        WindowsServiceType.googleDrive,
        'Google Drive health check fail: $e',
      );
      return false;
    }
  }

  static Future<http.Response> _localFallback(
    Object? rawBody, {
    required String remoteError,
  }) async {
    try {
      if (!await FirebaseFirestore.instance.localPersistenceEnabled()) {
        return _jsonResponse(
          jsonEncode({
            'success': false,
            'message': 'Local Data OFF hai; local fallback/save disabled.',
            'windowsLocalFallback': false,
            'remoteError': remoteError,
          }),
          200,
          headers: const {'content-type': 'application/json'},
        );
      }
      final body = _decodeBody(rawBody);
      final action = body['action']?.toString().trim() ?? '';
      final result = await _handleLocal(action, body);
      return _jsonResponse(
        jsonEncode({
          ...result,
          'windowsLocalFallback': true,
          'remoteError': remoteError,
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    } catch (e) {
      return _jsonResponse(
        jsonEncode({
          'success': false,
          'message': 'Local fallback error: $e',
          'windowsLocalFallback': true,
          'remoteError': remoteError,
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
  }

  static Map<String, dynamic> _decodeBody(Object? rawBody) {
    if (rawBody is Map) {
      return Map<String, dynamic>.from(rawBody);
    }
    final text = rawBody?.toString() ?? '';
    if (text.trim().isEmpty) return <String, dynamic>{};
    final decoded = jsonDecode(text);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw const FormatException('Request body JSON map nahi hai.');
  }

  static Future<Map<String, dynamic>> _handleCentral(
    Map<String, dynamic> body,
  ) async {
    final connection = await CentralSchoolCloud.saved();
    final school = connection['schoolId'];
    if (body['schoolId'] != null && body['schoolId'] != school)
      throw StateError('Document school mismatch.');
    if (FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'] !=
        school)
      throw StateError('Inactive school profile blocked.');
    final cloud = CentralSchoolCloud(
      endpoint: connection['endpoint'],
      expectedSchoolId: school,
    );
    final token = await WindowsFirebaseRemote.freshIdToken();
    Future<void> ensureSchool() async {
      if ((await CentralSchoolCloud.saved())['schoolId'] != school ||
          FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'] !=
              school)
        throw StateError('School changed during operation.');
    }

    final action = body['action']?.toString() ?? '';
    Map<String, dynamic>? initialDocumentRead;
    Map<String, dynamic>? documentWriteAck;
    if (connection['managed'] == true &&
        {'upload_student_document', 'delete_student_document'}.contains(action)) {
      final requestedId = (body['documentId'] ?? body['replaceDocumentId'])?.toString() ?? '';
      final checks = await Future.wait<Map<String, dynamic>>([
        cloud.api({'action': 'managed/storage/check', 'schoolId': school}, token: token),
        if (action == 'upload_student_document' && requestedId.isNotEmpty &&
            requestedId.length <= 200 && !requestedId.contains('/'))
          readManagedDocument(school, requestedId),
      ]);
      await ensureSchool();
      if (checks.first['documentVersions'] != 1)
        throw StateError('School storage needs the version-safe document adapter upgrade. Local originals and pending changes are retained.');
      if (checks.length > 1) initialDocumentRead = checks[1];
    }
    Future<Map<String, dynamic>> read(String collection) =>
        WindowsFirebaseRemote.readCollection(
          projectId: connection['projectId'],
          idToken: token,
          collection: collection,
        );
    Future<Map<String, dynamic>> documentReceipt(String id, Map payload, {Map? deleteAcknowledgement}) async {
      if (connection['managed'] != true)
        throw const MissingSyncAcknowledgement();
      final reply = await readManagedDocument(school, id);
      await ensureSchool();
      final receipt = documentAcknowledgementFromReadback(
        {...payload, 'schoolId': school, 'documentId': id}, reply, deleteAcknowledgement:deleteAcknowledgement,
      );
      if (!verifiedDocumentAcknowledgement({
        ...payload,
        'schoolId': school,
        'documentId': id,
      }, receipt, action:action)) {
        throw const MissingSyncAcknowledgement();
      }
      return receipt;
    }

    Future<void> save(
      String collection,
      String id,
      Map<String, dynamic> data, {
      String? expectedRevision,
      num? expectedUploadedAt,
      String? recordRevision,
    }) async {
      if ((await CentralSchoolCloud.saved())['schoolId'] != school ||
          FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'] !=
              school)
        throw StateError('School changed during operation.');
      await WindowsFirebaseRemote.writeDocument(
        projectId: connection['projectId'],
        idToken: token,
        collection: collection,
        documentId: id,
        data: data,
        expectedRevision: expectedRevision,
        expectedUploadedAt: expectedUploadedAt,
        reviewedRecordRevision: recordRevision,
        onManagedAcknowledgement: collection == 'documents'
          ? (ack) => documentWriteAck = ack : null,
      );
      await ensureSchool();
      await FirebaseFirestore.instance.applySyncedDocument(
        FirebaseFirestore.instance.collection(collection).doc(id),
        centralSchoolData(data, school),
      );
    }

    try {
      final data = Map<String, dynamic>.from(body)..remove('action');
      if (action == 'add_teacher' &&
          (data['teacherId']?.toString() ?? '').isEmpty)
        data['teacherId'] = 'T-${secureSetupToken(12)}';
      if ((data['photoBase64']?.toString() ?? '').isNotEmpty) {
        final file = await cloud.upload(
          data['photoFileName']?.toString() ?? 'School_Photo.jpg',
          data['photoMimeType']?.toString() ?? 'image/jpeg',
          data['photoBase64'],
          uploadKey: CentralSchoolCloud.uploadIdentity(school,
            (data['teacherId'] ?? data['studentId'] ?? data['personId'] ?? data['id'] ?? '').toString(),
            'photo', data['photoBase64'].toString()),
        );
        data.addAll({
          'photoUrl': file['fileUrl'],
          'photoFileId': file['fileId'],
        });
      }
      if (action == 'save_school_profile') {
        final existing =
            (await read('school_config'))['school_profile_cache'] ?? {};
        requireSchoolProfile(data);
        final profile = mergeSchoolProfileSafely(
          Map<String, dynamic>.from(existing),
          data,
        );
        for (final prefix in ['logo', 'seal', 'principalSignature']) {
          final raw = data['${prefix}Base64']?.toString() ?? '';
          if (raw.isNotEmpty) {
            final file = await cloud.upload(
              data['${prefix}FileName']?.toString() ?? '$prefix.png',
              data['${prefix}MimeType']?.toString() ?? 'image/png',
              raw,
              uploadKey: CentralSchoolCloud.uploadIdentity(school, 'school_profile', prefix, raw),
            );
            profile['${prefix}Url'] = file['fileUrl'];
            profile['${prefix}FileId'] = file['fileId'];
          }
        }
        final latitude = double.tryParse(profile['latitude']?.toString() ?? '');
        final longitude = double.tryParse(
          profile['longitude']?.toString() ?? '',
        );
        if (latitude == null ||
            longitude == null ||
            !SchoolMapPin(latitude, longitude).valid) {
          throw StateError('Valid school exact location required.');
        }
        final radius = parseSchoolAttendanceRadius(
          profile['attendanceRadiusMeters'] ?? schoolAttendanceRadiusMeters,
        );
        if (radius == null)
          throw StateError('School attendance range must be 25–200 metres.');
        profile['attendanceRadiusMeters'] = radius;
        final safe = centralSchoolData(profile, school);
        await save('school_config', 'school_profile_cache', safe);
        await save('school_settings', 'school_location', {
          'latitude': latitude,
          'longitude': longitude,
          'radiusMeters': radius,
        });
        return {'success': true, 'profile': safe};
      }
      if (action == 'get_school_profile')
        return {
          'success': true,
          'profile':
              (await read('school_config'))['school_profile_cache'] ?? {},
        };
      if (action == 'upload_student_document') {
        final requestedId =
            (data['documentId'] ?? data['replaceDocumentId'])?.toString() ?? '';
        final id = requestedId.isEmpty
            ? 'DOC-${secureSetupToken(18)}'
            : requestedId;
        if (id.contains('/') || id.length > 200)
          throw StateError('Invalid document ID.');
        final old = connection['managed'] == true
          ? ((initialDocumentRead ?? await readManagedDocument(school, id))['records'] as Map)[id]
          : (await read('documents'))[id];
        if (old != null && old['studentId'] != data['studentId'])
          throw StateError('Document belongs to another student.');
        final revision = data['documentRevision']?.toString() ?? '';
        if (revision.isEmpty || revision.length > 100)
          throw StateError('Document revision missing.');
        if (old?['documentRevision'] == revision) {
          if (!identicalDocumentPayload({...data, 'schoolId':school}, old!)) {
            throw StateError('Sync operation ID conflict');
          }
          return await documentReceipt(id, data);
        }
        final base = data['baseCloudRevision']?.toString() ?? '';
        if ((old?['documentRevision']?.toString() ?? '') != base)
          throw StateError(
            'Newer cloud document retained; resolve version conflict.',
          );
        final uploadKey = crypto.sha256
            .convert(utf8.encode('$id:$revision'))
            .toString();
        final file = await cloud.upload(
          'Document_$uploadKey.${data['mimeType'] == 'application/pdf' ? 'pdf' : 'jpg'}',
          data['mimeType']?.toString() ?? 'application/octet-stream',
          data['fileBase64']?.toString() ?? '',
          uploadKey: uploadKey,
        );
        final document = centralSchoolData({
          ...data,
          ...file,
          'documentId': id,
          // Use the durable generation time on replay, never rebuild its request identity.
          'uploadedAt': data['uploadedAt'] is num && data['uploadedAt'] > 0
              ? data['uploadedAt'] : DateTime.now().millisecondsSinceEpoch,
        }, school);
        await save(
          'documents',
          id,
          document,
          expectedRevision: base,
          recordRevision:
              data['reviewedRecordRevision'] as String? ??
              old?['_syncRevision'] as String? ??
              '',
          expectedUploadedAt: data['baseCloudUploadedAt'] as num?,
        );
        if (documentWriteAck != null) {
          final receipt = documentAcknowledgementFromWrite(
            {...data, ...file, 'documentId': id, 'schoolId': school}, documentWriteAck!);
          if (receipt != null) {
            await ensureSchool();
            await FirebaseFirestore.instance.applySyncedDocument(
              FirebaseFirestore.instance.collection('documents').doc(id),
              Map<String, dynamic>.from(receipt['document'] as Map));
            return receipt;
          }
        }
        return await documentReceipt(id, data);
      }
      if (action == 'delete_student_document') {
        final id = data['documentId']?.toString() ?? '';
        final old = (await read('documents'))[id];
        // Retry the remote delete even if standard reads already hide its tombstone.
        // A prior attempt may have committed metadata before file cleanup failed.
        if (old != null && old['studentId'] != data['studentId'])
          throw StateError('Document belongs to another student.');
        // The adapter writes a durable tombstone and removes only a verified,
        // exclusively owned immutable document upload. Shared/legacy files remain safe.
        final operationId = documentDeleteOperationId(id, data);
        Map<String,dynamic>? deleteAck;
        await WindowsFirebaseRemote.deleteDocument(
          projectId: connection['projectId'],
          idToken: token,
          collection: 'documents',
          documentId: id,
          expectedRevision: data['baseCloudRevision']?.toString() ?? '',
          operationId:operationId,
          onManagedAcknowledgement:(ack) => deleteAck = ack,
          expectedRecordRevision:data['reviewedRecordRevision'] as String? ?? old?['_syncRevision'] as String? ?? '',
          expectedUploadedAt: data['baseCloudUploadedAt'] as num?,
        );
        await ensureSchool();
        await FirebaseFirestore.instance.applySyncedDocument(
          FirebaseFirestore.instance
              .collection('documents')
              .doc(data['documentId']),
          null,
        );
        return await documentReceipt(id, {...data,'deleteOperationId':operationId}, deleteAcknowledgement:deleteAck);
      }
      final lists = {
        'list_student_documents': ('documents', 'documents'),
        'list_fee_payments': ('fee_payments', 'payments'),
        'list_school_expenses': ('school_expenses', 'expenses'),
      };
      if (lists.containsKey(action)) {
        final pair = lists[action]!;
        final rows = (await read(
          pair.$1,
        )).entries.map((e) => {'documentId': e.key, ...e.value});
        return {
          'success': true,
          pair.$2: rows
              .where(
                (e) =>
                    action != 'list_student_documents' ||
                    (e['studentId'] == data['studentId'] && StudentInventoryPolicy.visible(e)),
              )
              .toList(),
        };
      }
      if (action == 'delete_school_expense') {
        final id = data['expenseId']?.toString() ?? '';
        await WindowsFirebaseRemote.deleteDocument(
          projectId: connection['projectId'],
          idToken: token,
          collection: 'school_expenses',
          documentId: id,
        );
        await ensureSchool();
        await FirebaseFirestore.instance
            .collection('school_expenses')
            .doc(id)
            .delete();
        return {'success': true};
      }
      if (action == 'save_school_expense') {
        final id =
            data['expenseId']?.toString() ?? 'EXP-${secureSetupToken(12)}';
        await save('school_expenses', id, data);
        return {'success': true, 'expenseId': id};
      }
      if (action == 'save_fee_payment') {
        final id = data['paymentId']?.toString() ??
            data['receiptNo']?.toString() ?? 'FEE-${secureSetupToken(12)}';
        final file = await cloud.upload(
          '${data['receiptNo'] ?? id}.pdf',
          'application/pdf',
          data['pdfBase64']?.toString() ?? '',
          uploadKey: CentralSchoolCloud.uploadIdentity(school,
            id, 'fee_receipt', data['pdfBase64']?.toString() ?? ''),
        );
        await save('fee_payments', id, {...data, ...file, 'paymentId': id});
        return {'success': true, ...file, 'sheetUrl': ''};
      }
      if (action == 'save_exam' || action == 'save_exam_result') {
        final id = action == 'save_exam'
            ? data['examId']?.toString() ?? 'EXAM-${secureSetupToken(12)}'
            : '${data['examId']}_${data['studentId']}';
        final record = Map<String, dynamic>.from(data)..remove('pdfBase64');
        if (action == 'save_exam_result' &&
            (data['pdfBase64']?.toString().isNotEmpty ?? false)) {
          final file = await cloud.upload(
            'Report-$id.pdf',
            'application/pdf',
            data['pdfBase64'].toString(),
            uploadKey: CentralSchoolCloud.uploadIdentity(
              school, id, 'exam_report', data['pdfBase64'].toString()),
          );
          record['reportCardUrl'] = file['fileUrl'];
          record['reportCardFileId'] = file['fileId'];
        }
        await save(
          action == 'save_exam' ? 'exams' : 'exam_center_results',
          id,
          record,
        );
        return {
          'success': true,
          'examId': id,
          if (record['reportCardUrl'] != null)
            'reportCardUrl': record['reportCardUrl'],
        };
      }
      if (action == 'list_exam_center')
        return {
          'success': true,
          'exams': (await read(
            'exams',
          )).entries.map((e) => {'examId': e.key, ...e.value}).toList(),
          'results': (await read('exam_center_results')).values.toList(),
        };
      if (action == 'mark_teacher_attendance' ||
          action == 'mark_student_attendance' ||
          action == 'mark_attendance') {
        final person = data['teacherId'] ?? data['studentId'];
        final day = DateTime.now().toIso8601String().split('T').first;
        final id = '${person}_${day}_${data['mode'] ?? 'IN'}';
        await save(
          action == 'mark_teacher_attendance'
              ? 'teacher_attendance'
              : 'attendance_records',
          id,
          {
            ...data,
            'attendanceId': id,
            'date': day,
            'timestamp': DateTime.now().millisecondsSinceEpoch,
          },
        );
        return {
          'success': true,
          'attendanceId': id,
          'message': 'Attendance saved',
        };
      }
      // Directory screens already persist text through their tracked Firestore
      // writes. The adapter supplies uploaded Drive photo references.
      if ({
        'add_student',
        'edit_student',
        'delete_student',
        'change_student_class',
        'add_teacher',
        'edit_teacher',
        'delete_teacher',
        'update_teacher_schedule',
      }.contains(action)) {
        return {
          'success': true,
          if (data['teacherId'] != null) 'teacherId': data['teacherId'],
          if (data['studentId'] != null) 'studentId': data['studentId'],
          'photoUrl': data['photoUrl'] ?? '',
        };
      }
      throw StateError('Unsupported central school operation: $action');
    } finally {
      cloud.close();
    }
  }

  static Future<Map<String, dynamic>> _handleLocal(
    String action,
    Map<String, dynamic> body,
  ) async {
    switch (action) {
      case 'windows_sync_snapshot':
        return _localSyncSnapshot();

      case 'get_school_profile':
        final doc = await FirebaseFirestore.instance
            .collection('school_config')
            .doc('school_profile_cache')
            .get();
        return {'success': true, 'profile': doc.data() ?? <String, dynamic>{}};

      case 'save_school_profile':
        final profile = <String, dynamic>{
          'schoolName': body['schoolName'] ?? '',
          'principalName': body['principalName'] ?? '',
          'schoolContactNo': body['schoolContactNo'] ?? '',
          'updatedBy': body['updatedBy'] ?? 'Admin',
        };
        final old = await FirebaseFirestore.instance
            .collection('school_config')
            .doc('school_profile_cache')
            .get();
        requireSchoolProfile(profile);
        final merged = mergeSchoolProfileSafely(old.data() ?? {}, profile);
        await FirebaseFirestore.instance
            .collection('school_config')
            .doc('school_profile_cache')
            .set(merged, SetOptions(merge: true));
        return {'success': true, 'profile': merged};

      case 'list_exam_center':
        final exams = await FirebaseFirestore.instance.collection('exams').get();
        final legacyExams = await FirebaseFirestore.instance.collection('_local_exam_center_exams').get();
        final results = await FirebaseFirestore.instance.collection('exam_center_results').get();
        final legacyResults = await FirebaseFirestore.instance.collection('_local_exam_center_results').get();
        return {
          'success': true,
          'exams': {
            for (final d in legacyExams.docs)
              d.id: {'examId': d.id, ...d.data()},
            for (final d in exams.docs) d.id: {'examId': d.id, ...d.data()},
          }.values.toList(),
          'results': {
            for (final d in legacyResults.docs) d.id: d.data(),
            for (final d in results.docs) d.id: d.data(),
          }.values.toList(),
        };

      case 'save_exam':
        final examId = body['examId']?.toString().trim().isNotEmpty == true
            ? body['examId'].toString().trim()
            : 'EXAM-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9999).toString().padLeft(4, '0')}';
        final data = <String, dynamic>{
          ...body,
          'examId': examId,
          'timestamp':
              body['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
        }..remove('action');
        await FirebaseFirestore.instance
            .collection('exams')
            .doc(examId)
            .set(data, SetOptions(merge: true));
        return {'success': true, 'examId': examId};

      case 'save_exam_result':
        final examId = body['examId']?.toString() ?? '';
        final studentId = body['studentId']?.toString() ?? '';
        if (examId.isEmpty || studentId.isEmpty) {
          return {'success': false, 'message': 'Exam/Student ID missing.'};
        }
        final data =
            <String, dynamic>{
                ...body,
                'timestamp':
                    body['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
              }
              ..remove('action')
              ..remove('pdfBase64');
        await FirebaseFirestore.instance
            .collection('exam_center_results')
            .doc('${examId}_$studentId')
            .set(data, SetOptions(merge: true));
        return {'success': true};

      case 'list_fee_payments':
        final payments = await FirebaseFirestore.instance
            .collection('fee_payments')
            .get();
        return {
          'success': true,
          'payments': payments.docs.map((d) {
            final data = Map<String, dynamic>.from(d.data());
            data.putIfAbsent('studentClass', () => data['class'] ?? '');
            data.putIfAbsent('paymentId', () => d.id);
            return data;
          }).toList(),
        };

      case 'save_fee_payment':
        return {
          'success': true,
          'fileUrl': '',
          'sheetUrl': '',
          'message': 'Google unavailable; fee local database me save hoga.',
        };

      case 'list_student_documents':
        final studentId = body['studentId']?.toString() ?? '';
        final snapshot = await FirebaseFirestore.instance
            .collection('_local_student_documents')
            .where('studentId', isEqualTo: studentId)
            .get();
        return {
          'success': true,
          'documents': snapshot.docs.map((d) => d.data()).where(StudentInventoryPolicy.visible).toList(),
        };

      case 'upload_student_document':
        return _saveLocalStudentDocument(body);

      case 'delete_student_document':
        return _deleteLocalStudentDocument(body);

      case 'add_teacher':
        final teacherId =
            body['teacherId']?.toString().trim().isNotEmpty == true
            ? body['teacherId'].toString().trim()
            : 'T-${DateTime.now().millisecondsSinceEpoch}';
        return {
          'success': true,
          'teacherId': teacherId,
          'photoUrl': body['photoUrl']?.toString() ?? '',
        };

      case 'edit_teacher':
      case 'update_teacher_schedule':
        return {
          'success': true,
          'teacherId': body['teacherId']?.toString() ?? '',
          'photoUrl': body['photoUrl']?.toString() ?? '',
        };

      case 'delete_teacher':
      case 'add_student':
      case 'edit_student':
      case 'delete_student':
      case 'change_student_class':
        return {'success': true};

      default:
        return {
          'success': true,
          'message': 'Windows local fallback handled: $action',
        };
    }
  }

  static Future<Map<String, dynamic>> _localSyncSnapshot() async {
    Future<List<Map<String, dynamic>>> read(
      String collection, {
      String idField = 'id',
    }) async {
      final snapshot = await FirebaseFirestore.instance
          .collection(collection)
          .get();

      return snapshot.docs.map((doc) {
        final data = Map<String, dynamic>.from(doc.data());
        data.putIfAbsent(idField, () => doc.id);
        return data;
      }).toList();
    }

    final profile = await FirebaseFirestore.instance
        .collection('school_config')
        .doc('school_profile_cache')
        .get();

    return <String, dynamic>{
      'success': true,
      'windowsLocalFallback': true,
      'students': await read('students_directory', idField: 'documentId'),
      'teachers': await read('teachers_directory', idField: 'documentId'),
      'feePayments': await read('fee_payments', idField: 'paymentId'),
      'documents': await read(
        '_local_student_documents',
        idField: 'documentId',
      ),
      'studentAttendance': await read(
        '_local_student_attendance',
        idField: 'attendanceId',
      ),
      'teacherAttendance': await read(
        '_local_teacher_attendance',
        idField: 'attendanceId',
      ),
      'exams': await read('_local_exam_center_exams', idField: 'examId'),
      'results': await read(
        '_local_exam_center_results',
        idField: 'documentId',
      ),
      'schoolProfile': profile.data() ?? <String, dynamic>{},
    };
  }

  static String publishedIdCardOwnerId(String role, String personId) {
    if(!{'student','teacher'}.contains(role)||personId.isEmpty||personId.length>200||personId.contains('/'))throw StateError('Invalid ID owner.');
    return 'ID-${crypto.sha256.convert(utf8.encode('$role/$personId'))}';
  }

  /// A reused class/roll slot is a new owner, not permission to resurrect the
  /// retired owner's deleted card. Keep the original identity for legacy owners.
  static String publishedIdCardOwnerIdForPerson(String role, String personId, Map person) {
    final legacy=publishedIdCardOwnerId(role,personId);
    final generation=person['mobileStableId'];
    final retired=person['_syncRetiredStudentGenerations'];
    final previous=person['replacesStudentGeneration'];
    final pattern=RegExp(r'^p-[a-f0-9]{32,64}$');
    final replaced=retired is List && retired.any((value)=>value is String&&pattern.hasMatch(value)&&value!=generation) ||
        previous is String && pattern.hasMatch(previous)&&previous!=generation;
    if(!replaced)return legacy;
    if(generation is! String||!pattern.hasMatch(generation)||retired is List&&retired.contains(generation))
      throw StateError('Current ID owner generation requires review.');
    return 'ID-${crypto.sha256.convert(utf8.encode('$role/$personId/$generation'))}';
  }

  static String publishedIdCardId(String qr) {
    final link = SchoolLink.parse(qr);
    return publishedIdCardOwnerId(link.role,link.personId);
  }

  /// Restore the SAME retained PDF operation only after an authoritative read
  /// proves there is no cloud card. Never replace a published version/tombstone.
  static Future<void> requeueUnpublishedIdCard(String id, {
    required Future<Map<String, dynamic>> Function() readPublished,
  }) async {
    final db = FirebaseFirestore.instance, origin = FirebaseFirestore.instance.activeProfileId;
    final school = db.activeProfileIdentity['schoolSyncId'];
    final local = (await db.collection('_local_student_documents').doc(id).get()).data();
    if (local == null || local['schoolId'] != school || local['documentKind'] != 'idCard')
      throw StateError('Verified local ID required.');
    final reply = await readPublished();
    if (db.activeProfileId != origin || reply['schoolId'] != school || reply['syncProtocol'] != 2 || reply['records'] is! Map)
      throw StateError('School ID inventory verification failed.');
    final remote = (reply['records'] as Map)[id];
    if (remote != null) {
      if (remote is! Map || remote['schoolId'] != school)
        throw StateError('School ID inventory owner mismatch.');
      await db.applySyncedDocument(db.collection('documents').doc(id), Map<String, dynamic>.from(remote));
      return;
    }
    final path = local['localPath'];
    if (path is! String || !await File(path).exists())
      throw StateError('Original ID PDF requires school review; no replacement created.');
    var queued = false;
    await _documentWrite(() async {
      if (db.activeProfileId != origin) throw StateError('School changed during ID recovery.');
      final current = (await db.collection('_local_student_documents').doc(id).get()).data();
      final pending = (await db.collection('_windows_document_outbox').doc(id).get()).data();
      final cloud = (await db.collection('documents').doc(id).get()).data();
      if (current == null || current['documentRevision'] != local['documentRevision'] || current['localPath'] != path)
        throw StateError('Original ID changed during recovery.');
      if (holdAutomaticIdCard(current, pending, cloud, school as String) || pending != null || cloud != null) return;
      if (current['documentRevision'] is! String || (current['documentRevision'] as String).isEmpty)
        throw StateError('Original ID revision requires school review.');
      // Preserve original documentRevision, files and CAS baseline; no queue reset.
      final batch = db.batch();
      final retained = {...current, 'syncState': 'Pending'};
      batch.set(db.collection('_windows_document_outbox').doc(id), retained);
      batch.set(db.collection('_local_student_documents').doc(id), {'syncState': 'Pending'}, SetOptions(merge: true));
      await batch.commit(); queued = true;
    });
    if (queued) onLocalDocumentCommitted?.call();
  }

  /// A bounded owner read; the verified capability decides whether old Scripts
  /// retain their full-inventory path. Never infer absence from an invalid reply.
  static Future<Map<String, dynamic>> readManagedDocument(String school, String id) async {
    final point = WindowsFirebaseRemote.recordPointReadSupported;
    final reply = await ManagedSchoolSession.callForSchool(school, 'managed/records', {
      'operation': 'read', 'collection': 'documents', 'syncProtocol': 2,
      if (point) 'id': id,
    });
    if (reply['schoolId'] != school || reply['syncProtocol'] != 2 ||
        reply['records'] is! Map || point && (reply['pointRead'] != true ||
          (reply['records'] as Map).keys.any((key) => key != id))) {
      throw const MissingSyncAcknowledgement();
    }
    return reply;
  }

  static Future<void> publishIdCard({
    Uint8List? bytes,
    Future<Uint8List?> Function()? prepareBytes,
    required String qr,
    required String kind,
    required Map<String, dynamic> person,
    required String inputRevision,
    Future<Map<String, dynamic>> Function()? readPublished,
    bool automatic=false,
  }) async {
    final link = SchoolLink.parse(qr), db = FirebaseFirestore.instance;
    if (!link.managed ||
        link.schoolId != db.activeProfileIdentity['schoolSyncId'] ||
        person['mobileLinkToken'] != link.linkToken)
      throw StateError('Verified school ID owner required.');
    if (!await db.localPersistenceEnabled())
      throw StateError('Durable local school context required.');
    final id = publishedIdCardOwnerIdForPerson(link.role,link.personId,person), origin = db.activeProfileId;
    final captured =
        (await db.collection('_local_student_documents').doc(id).get()).data();
    final pendingBeforeRead=(await db.collection('_windows_document_outbox').doc(id).get()).data();
    final cachedBeforeRead=(await db.collection('documents').doc(id).get()).data();
    if(db.activeProfileId!=origin)throw StateError('School changed during ID publication.');
    if(automatic&&holdAutomaticIdCard(captured,pendingBeforeRead,cachedBeforeRead,link.schoolId))return;
    if(pendingBeforeRead!=null && (captured==null || {'conflict','needsAttention'}.contains(pendingBeforeRead['syncState'])))throw StateError('Existing ID generation requires owner review. Original queue retained.');
    Map<String, dynamic>? existingCloud;
    if (captured == null) {
      Map<String, dynamic>? reply;
      try {
        reply =
            await (readPublished?.call() ??
                readManagedDocument(link.schoolId, id));
      } on TimeoutException {
        /* Offline generation remains safely queued; CAS still required. */
      } on SocketException {
        /* No cloud evidence; never grant a replacement baseline. */
      } on CentralCloudException catch(error) {
        if(!{429,502,503,504}.contains(error.status))rethrow;
        // A retryable inventory outage cannot block durable offline generation.
        // The existing owner CAS must still prove absence before cloud creation.
      }
      if (db.activeProfileId != origin ||
          db.activeProfileIdentity['schoolSyncId'] != link.schoolId) {
        throw StateError('School changed during ID publication.');
      }
      if (reply != null) {
        if (reply['schoolId'] != link.schoolId ||
            reply['syncProtocol'] != 2 ||
            reply['records'] is! Map ||
            reply['unchanged'] == true) {
          throw StateError(
            'Published ID inventory not verified. Local originals retained.',
          );
        }
        final row = (reply['records'] as Map)[id];
        if (row != null) {
          if(automatic && row is Map && row['schoolId']==link.schoolId &&
              row['_syncDeleted']==true && row['_syncRevision'] is String &&
              (row['_syncRevision'] as String).isNotEmpty &&
              (row['id']==null||row['id']==id) &&
              (row['documentId']==null||row['documentId']==id))return;
          if (row is! Map ||
              row['schoolId'] != link.schoolId ||
              row['studentId'] != link.personId ||
              row['ownerRole'] != link.role ||
              row['personId'] != (person['mobileStableId'] ?? link.personId) ||
              row['documentKind'] != 'idCard' ||
              row['_syncDeleted'] == true ||
              row['documentRevision'] is! String || row['documentRevision'].isEmpty ||
              row['_syncRevision'] is! String || row['_syncRevision'].isEmpty ||
              row['contentHash'] is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(row['contentHash'])) {
            throw StateError('Existing cloud ID requires owner review.');
          }
          existingCloud = Map<String, dynamic>.from(row);
          if (automatic && existingCloud['inputRevision'] != inputRevision) {
            // A new device has no local generation proving that these inputs
            // supersede the published card. Do not manufacture a conflicting
            // PDF just because its first local fingerprint differs.
            throw PublishedIdInputConflict(schoolId: link.schoolId, documentId: id,
              ownerRole: link.role, personDocId: link.personId,
              personId: (person['mobileStableId'] ?? link.personId).toString(),
              inputRevision: inputRevision, cloudRevision: existingCloud['_syncRevision'] as String);
          }

        }
      }
    }
    // Decide whether an automatic receiver needs a package before rendering.
    // A verified existing card (or input conflict above) needs no new PDF.
    // Keep expensive rendering outside the document writer as well.
    final reuseCloud = captured == null && existingCloud?['inputRevision'] == inputRevision;
    final package = reuseCloud ? null : bytes ?? await prepareBytes?.call();
    if (!reuseCloud && (package == null || package.isEmpty)) {
      throw StateError('Selected ID renderer returned no package.');
    }
    // Cloud waits happen outside the local document writer, so another offline
    // document save can complete while this bounded inventory read is pending.
    var publicationQueued=false;
    await _documentWrite(() async {
      if (db.activeProfileId != origin)
        throw StateError('School changed during ID publication.');
      final old =
          (await db.collection('_local_student_documents').doc(id).get())
              .data();
      final retainedQueue =
          (await db.collection('_windows_document_outbox').doc(id).get())
              .data();
      final cached=(await db.collection('documents').doc(id).get()).data();
      if(automatic&&holdAutomaticIdCard(old,retainedQueue,cached,link.schoolId)){
        return;
      }
      if (retainedQueue != null &&
          (old == null ||
              {
                'conflict',
                'needsAttention',
              }.contains(retainedQueue['syncState']))) {
        throw StateError(
          'Existing ID generation requires owner review. Original queue retained.',
        );
      }
      if ((old?['inputRevision'] == inputRevision ||
              old?['ownerCloudChoiceInputRevision'] == inputRevision) &&
          old?['deleted'] != true)
        return;
      if (old == null && existingCloud?['inputRevision'] == inputRevision) {
        // Same inputs already published: metadata restore is not a byte ACK.
        await db.applySyncedDocument(
          db.collection('documents').doc(id),
          existingCloud!,
        );
        return;
      }
      if (package == null) {
        throw StateError('ID publication changed during preparation. Retry the current revision.');
      }
      await _saveLocalStudentDocument({
        '_queueCloud': true,
        if (old == null && existingCloud != null)
          '_cloudGenerationConflict': existingCloud,
        'replaceDocumentId': id,
        'studentId': link.personId,
        'studentName': person['name'],
        'studentClass': person['class'],
        'rollNo': person['rollNo'],
        'documentKind': 'idCard',
        'inventoryCategory': 'generatedIdCard',
        'ownerRole': link.role,
        'personId': person['mobileStableId'] ?? link.personId,
        'inputRevision': inputRevision,
        'qr': qr,
        'documentName': 'School ID card • Front & back',
        'fileName': '$id.pdf',
        'mimeType': 'application/pdf',
        'fileBase64': base64Encode(package),
      });
      publicationQueued = true;
    });
    if(publicationQueued)onLocalDocumentCommitted?.call();
  }

  static Future<Map<String, dynamic>> _saveLocalStudentDocument(
    Map<String, dynamic> body,
  ) async {
    final originProfile = FirebaseFirestore.instance.activeProfileId;
    final owner = body['_queueCloud'] == true
        ? await CentralSchoolCloud.saved()
        : <String, dynamic>{};
    final studentId = body['studentId']?.toString().trim() ?? '';
    if (studentId.isEmpty) {
      return {'success': false, 'message': 'Student ID missing.'};
    }

    final replaceId = body['replaceDocumentId']?.toString().trim() ?? '';
    final documentId = replaceId.isNotEmpty
        ? replaceId
        : 'DOC-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9999)}';
    final ref = FirebaseFirestore.instance
        .collection('_local_student_documents')
        .doc(documentId);
    final previous = (await ref.get()).data();
    final remoteBase =
        (await FirebaseFirestore.instance
                .collection('documents')
                .doc(documentId)
                .get())
            .data();
    if (previous != null && previous['studentId'] != studentId)
      throw StateError('Document belongs to another student.');
    final raw = body['fileBase64']?.toString() ?? '';
    final bytes = _decodeDataUri(raw);
    if (bytes.isEmpty || bytes.length > 50 * 1024 * 1024)
      throw StateError('Document must be between 1 byte and 50 MB.');
    final safeName = _safeFileName(
      body['fileName']?.toString() ?? '$documentId.bin',
    );

    final root = await WindowsLocalStorage.localFilesDirectory();
    final profileFolder = Directory(
      '${root.path}${Platform.pathSeparator}'
      '${_safeFileName(originProfile)}',
    );
    final studentFolder = Directory(
      '${profileFolder.path}${Platform.pathSeparator}${_safeFileName(studentId)}',
    );
    await studentFolder.create(recursive: true);
    final file = File(
      '${studentFolder.path}${Platform.pathSeparator}${_safeFileName(documentId)}_${secureSetupToken(12)}_$safeName',
    );
    Uint8List? optimized;
    Uint8List? highQuality;
    Map<String, dynamic> processing = {};
    String? processingWarning;
    try {
      if (body['documentKind'] == 'idCard') {
        await IdCardEngine.verifyExport(
          Uint8List.fromList(bytes),
          body['qr'].toString(),
        );
        processing = {
          'optimized': Uint8List.fromList(bytes),
          'highQuality': Uint8List.fromList(bytes),
          'mimeType': 'application/pdf',
          'targetMet': bytes.length <= DocumentProcessingEngine.setTarget ~/ 8,
          'cleanupStatus': 'Exact verified school-rendered front/back ID; vector/QR preserved',
        };
      } else
        processing = await DocumentPipeline.process(
          Uint8List.fromList(bytes),
          body['mimeType']?.toString() ?? '',
          scope: originProfile,
        );
      optimized = processing['optimized'] as Uint8List;
      highQuality = processing['highQuality'] as Uint8List;
    } catch (e) {
      if (body['_queueCloud'] == true) rethrow;
      processingWarning =
          'Processing unavailable; original retained. ${e.runtimeType}';
    }
    if (body['_queueCloud'] == true) {
      final current = await CentralSchoolCloud.saved();
      if (current['managed'] != true ||
          current['uid'] != owner['uid'] ||
          current['schoolId'] != owner['schoolId'] ||
          current['schoolId'] !=
              FirebaseFirestore
                  .instance
                  .activeProfileIdentity['schoolSyncId'] ||
          FirebaseFirestore.instance.activeProfileId != originProfile ||
          !await FirebaseFirestore.instance.localPersistenceEnabled()) {
        throw StateError('School changed before durable document save.');
      }
    }
    await file.writeAsBytes(bytes, flush: true);
    final optimizedExtension = processing['mimeType'] == 'application/pdf'
        ? 'pdf'
        : processing['mimeType'] == 'image/png'
        ? 'png'
        : 'jpg';
    final optimizedFile = body['documentKind'] == 'idCard' ? file : File('${file.path}.optimized.$optimizedExtension');
    final highFile = body['documentKind'] == 'idCard' ? file : File(
      '${file.path}.processed.${processing['mimeType'] == 'application/pdf' ? 'pdf' : 'jpg'}',
    );
    if (optimized != null && optimizedFile.path != file.path)
      await optimizedFile.writeAsBytes(optimized, flush: true);
    if (highQuality != null && highFile.path != file.path)
      await highFile.writeAsBytes(highQuality, flush: true);

    if (FirebaseFirestore.instance.activeProfileId != originProfile)
      throw StateError('School changed. Reopen documents.');
    final ownerRecord=body['documentKind']=='idCard'?null:
        (await FirebaseFirestore.instance.collection('students_directory').doc(studentId).get()).data();
    if (FirebaseFirestore.instance.activeProfileId != originProfile)
      throw StateError('School changed. Reopen documents.');
    // Immutable generations preserve the original and previous copy until an
    // explicit retention policy removes them; a failed metadata write rolls back.
    final metadata = <String, dynamic>{
      'documentId': documentId,
      if (ownerRecord?['mobileStableId'] is String) ...{
        'personId':ownerRecord!['mobileStableId'], 'ownerRole':'student',
      },
      if (body['documentKind'] == 'idCard') ...{
        'documentKind': 'idCard',
        'inventoryCategory': 'generatedIdCard',
        'ownerRole': body['ownerRole'],
        'personId': body['personId'],
        'inputRevision': body['inputRevision'],
      },
      'schoolId':
          FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId'],
      'studentId': studentId,
      'studentName': body['studentName'] ?? '',
      'studentClass': body['studentClass'] ?? '',
      'rollNo': body['rollNo'] ?? '',
      'documentName': body['documentName'] ?? 'Document',
      'fileName': safeName,
      'mimeType': body['mimeType'] ?? '',
      'sizeBytes': optimized?.length ?? bytes.length,
      'sourceBytes': bytes.length,
      'documentRevision': secureSetupToken(24),
      'baseCloudRevision':
          previous?['cloudRevision'] ??
          previous?['baseCloudRevision'] ??
          remoteBase?['documentRevision'] ??
          '',
      'baseCloudUploadedAt':
          previous?['cloudUploadedAt'] ??
          previous?['baseCloudUploadedAt'] ??
          remoteBase?['uploadedAt'],
      'cloudRevision':
          previous?['cloudRevision'] ?? remoteBase?['documentRevision'] ?? '',
      'optimizedPath': optimized != null ? optimizedFile.path : file.path,
      'processedPath': highQuality != null ? highFile.path : file.path,
      'optimizedMimeType': processing['mimeType'] ?? body['mimeType'],
      'optimizedFileName': optimized != null
          ? '$documentId.$optimizedExtension'
          : safeName,
      'targetMet': processing['targetMet'] == true,
      'cleanupStatus': processing['cleanupStatus'] ?? processingWarning,
      'optimizationReason': processing['optimizationReason'],
      'sourceRetained': processing['sourceRetained'] == true,
      'deleted': false,
      'syncState': body['_cloudGenerationConflict'] != null
          ? 'conflict'
          : body['_queueCloud'] == true
          ? 'Pending'
          : 'Local',
      if (body['_cloudGenerationConflict'] is Map) ...{
        'observedCloud': body['_cloudGenerationConflict'],
        'failureCategory': 'conflict',
        'lastError':
            'Existing published ID has different inputs; review both originals before upload.',
        'diagnosticId': 'ID_CLOUD_GENERATION_REVIEW_REQUIRED',
        'suspectedCause':
            'Missing local generation with an existing different cloud ID; revision order unknown.',
        'sourceFile': 'lib/windows_backend_bridge.dart',
        'requiredOwnerAction':
            'Sync details → Review → Verify cloud version → inspect PDFs and explicitly choose.',
      },
      'localPath': file.path,
      'originalPath': file.path,
      'retainedPaths': [
        ...(previous?['retainedPaths'] as List? ?? []),
        if (previous?['localPath'] is String) previous!['localPath'],
      ],
      'fileUrl': Uri.file(file.path).toString(),
      'uploadedBy': body['uploadedBy'] ?? 'Admin',
      'uploadedAt': DateTime.now().millisecondsSinceEpoch,
    };

    final batch = FirebaseFirestore.instance.batch();
    batch.set(ref, metadata, SetOptions(merge: true));
    if (body['_queueCloud'] == true)
      batch.set(
        FirebaseFirestore.instance
            .collection('_windows_document_outbox')
            .doc(documentId),
        metadata,
      );
    await batch.commit();

    return {
      'success': true,
      'documentId': documentId,
      'fileUrl': metadata['fileUrl'],
      'document': metadata,
    };
  }

  static Future<Map<String, dynamic>> _deleteLocalStudentDocument(
    Map<String, dynamic> body,
  ) async {
    final id = body['documentId']?.toString().trim() ?? '';
    if (id.isEmpty) return {'success': true};

    final ref = FirebaseFirestore.instance
        .collection('_local_student_documents')
        .doc(id);
    // Remove the index only; immutable original files remain available for recovery.
    await ref.delete();
    return {'success': true};
  }

  static List<int> _decodeDataUri(String value) {
    final clean = value.trim();
    final marker = clean.indexOf('base64,');
    final encoded = marker >= 0 ? clean.substring(marker + 7) : clean;
    if (encoded.isEmpty) return const <int>[];
    return base64Decode(encoded);
  }

  static String _normalizedUrl(String input) {
    final value = input.trim();
    final uri = Uri.tryParse(value);
    if (uri == null) return value;
    return uri.replace(fragment: '').toString();
  }

  static String _safeFileName(String input) {
    final value = input
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ');
    return value.isEmpty ? 'file' : value;
  }
}

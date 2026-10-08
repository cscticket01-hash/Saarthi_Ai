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
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'windows_local_firestore.dart';
import 'windows_local_settings.dart';
import 'windows_local_storage.dart';
import 'windows_service_status.dart';
import 'windows_firebase_sync.dart';
import 'school_backend_transport.dart';

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
  static http.Response _jsonResponse(String body, int status,
      {Map<String, String>? headers}) => http.Response.bytes(
    utf8.encode(body), status,
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

  static Future<void> changeLocalStorageLocation(String path) =>
      _documentWrite(()=>FirebaseFirestore.instance.changeLocalStorageLocation(path));
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
    return RegExp(r'^/file/d/([A-Za-z0-9_-]{1,200})/view$')
            .firstMatch(uri.path)
            ?.group(1) ??
        '';
  }

  static Future<void> flushDocumentPending({
    Future<Map<String, dynamic>> Function(Map<String, dynamic>)? send,
  }) async {
    if (_documentDraining) return;
    _documentDraining = true;
    final origin = FirebaseFirestore.instance.activeProfileId;
    try {
      final queue = await FirebaseFirestore.instance
          .collection('_windows_document_outbox')
          .get();
      for (final queued in queue.docs) {
        if (FirebaseFirestore.instance.activeProfileId != origin)
          throw StateError('School changed during document sync.');
        final record = queued.data();
        if (record['syncState'] == 'conflict' ||
            record['syncState'] == 'needsAttention')
          continue;
        try {
          final identity = await CentralSchoolCloud.saved();
          if (record['schoolId'] != identity['schoolId'] ||
              FirebaseFirestore.instance.activeProfileId != origin)
            throw StateError('Pending document belongs to another school.');
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
            'schoolId': record['schoolId'],
            'documentRevision': record['documentRevision'],
            'sizeBytes': record['sizeBytes'],
            'sourceBytes': record['sourceBytes'],
            'contentHash': crypto.sha256.convert(bytes).toString(),
            'cleanupStatus': record['cleanupStatus'],
            'targetMet': record['targetMet'],
            'baseCloudRevision': record['baseCloudRevision'] ?? '',
            'baseCloudUploadedAt': record['baseCloudUploadedAt'],
            'fileBase64': base64Encode(bytes),
          };
          final result = await (send ?? _handleCentral)(payload);
          if (result['success'] != true)
            throw StateError('Document sync failed. Original retained.');
          await _documentWrite(() async {
            if (FirebaseFirestore.instance.activeProfileId != origin)
              throw StateError('School changed during document sync.');
            final ref = FirebaseFirestore.instance
                .collection('_local_student_documents')
                .doc(queued.id);
            final current = (await ref.get()).data();
            if (current?['localPath'] != generationPath ||
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
        } catch (error) {
          if (FirebaseFirestore.instance.activeProfileId == origin)
            await _documentWrite(() async {
              final current = (await queued.reference.get()).data();
              if (current != null &&
                  current['documentRevision'] == record['documentRevision'] &&
                  current['localPath'] == record['localPath']) {
                final conflict = error.toString().toLowerCase().contains(
                  'conflict',
                );
                await queued.reference.set({
                  'syncState': conflict ? 'conflict' : 'retry',
                  'retryCount':
                      (current['retryCount'] as num? ?? 0).toInt() + 1,
                  'lastError': conflict
                      ? 'Document version conflict; local original retained.'
                      : 'Document synchronization failed; local original retained.',
                }, SetOptions(merge: true));
              }
            });
          rethrow;
        }
      }
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

  static Future<int> flushPending() async {
    final snapshot = await FirebaseFirestore.instance
        .collection('_windows_google_outbox')
        .get();

    if (snapshot.docs.isEmpty) {
      return 0;
    }

    var completed = 0;
    final activeUrl = await WindowsExternalConnections.googleScriptUrl();

    final docs = snapshot.docs.toList()
      ..sort((a, b) {
        final av = _millis(a.data()['queuedAt']);
        final bv = _millis(b.data()['queuedAt']);
        return av.compareTo(bv);
      });

    for (final queued in docs) {
      final data = queued.data();
      final urlText = data['url']?.toString().trim() ?? '';
      final bodyData = data['body'];

      if (urlText.isEmpty || bodyData is! Map) {
        await queued.reference.delete();
        completed++;
        continue;
      }

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
        final response = await _postFollowingAppsScriptRedirects(
          Uri.parse(urlText),
          headers: headers.isEmpty
              ? const {'Content-Type': 'text/plain;charset=utf-8'}
              : headers,
          body: jsonEncode(Map<String, dynamic>.from(bodyData)),
        ).timeout(const Duration(seconds: 30));

        if (response.statusCode < 200 || response.statusCode >= 300) {
          break;
        }

        final decoded = jsonDecode(response.body);

        if (decoded is! Map) {
          break;
        }

        final result = Map<String, dynamic>.from(decoded);

        final action = data['action']?.toString() ?? '';

        if (!_replayApplied(action, result)) {
          break;
        }

        await queued.reference.delete();
        completed++;
      } catch (_) {
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

    final code = result['code']?.toString().toUpperCase() ?? '';
    final message = result['message']?.toString().toLowerCase() ?? '';

    if (action == 'add_student' &&
        (code == 'STUDENT_ALREADY_EXISTS' ||
            message.contains('already exist'))) {
      return true;
    }

    if (action.startsWith('delete_') &&
        (message.contains('nahi mila') ||
            message.contains('not found') ||
            message.contains('already deleted'))) {
      return true;
    }

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
    if (connection['managed'] == true &&
        {
          'upload_student_document',
          'delete_student_document',
        }.contains(action)) {
      final health = await cloud.api({
        'action': 'managed/storage/check',
        'schoolId': school,
      }, token: token);
      if (health['documentVersions'] != 1)
        throw StateError(
          'School storage needs the version-safe document adapter upgrade. Local originals and pending changes are retained.',
        );
    }
    Future<Map<String, dynamic>> read(String collection) =>
        WindowsFirebaseRemote.readCollection(
          projectId: connection['projectId'],
          idToken: token,
          collection: collection,
        );
    Future<void> save(
      String collection,
      String id,
      Map<String, dynamic> data, {
      String? expectedRevision,
      num? expectedUploadedAt,
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
        );
        data.addAll({
          'photoUrl': file['fileUrl'],
          'photoFileId': file['fileId'],
        });
      }
      if (action == 'save_school_profile') {
        final existing =
            (await read('school_config'))['school_profile_cache'] ?? {};
        final profile = <String, dynamic>{...existing, ...data};
        for (final prefix in ['logo', 'seal', 'principalSignature']) {
          final raw = data['${prefix}Base64']?.toString() ?? '';
          if (raw.isNotEmpty) {
            final file = await cloud.upload(
              data['${prefix}FileName']?.toString() ?? '$prefix.png',
              data['${prefix}MimeType']?.toString() ?? 'image/png',
              raw,
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
        final old = (await read('documents'))[id];
        if (old != null && old['studentId'] != data['studentId'])
          throw StateError('Document belongs to another student.');
        final revision = data['documentRevision']?.toString() ?? '';
        if (revision.isEmpty || revision.length > 100)
          throw StateError('Document revision missing.');
        if (old?['documentRevision'] == revision)
          return {
            'success': true,
            'documentId': id,
            'fileUrl': old?['fileUrl'],
            'document': old,
          };
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
          'uploadedAt': DateTime.now().millisecondsSinceEpoch,
        }, school);
        await save(
          'documents',
          id,
          document,
          expectedRevision: base,
          expectedUploadedAt: data['baseCloudUploadedAt'] as num?,
        );
        return {
          'success': true,
          'documentId': id,
          'fileUrl': file['fileUrl'],
          'document': document,
        };
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
        await WindowsFirebaseRemote.deleteDocument(
          projectId: connection['projectId'],
          idToken: token,
          collection: 'documents',
          documentId: id,
          expectedRevision: data['baseCloudRevision']?.toString() ?? '',
          expectedUploadedAt: data['baseCloudUploadedAt'] as num?,
        );
        await ensureSchool();
        await FirebaseFirestore.instance.applySyncedDocument(
          FirebaseFirestore.instance
              .collection('documents')
              .doc(data['documentId']),
          null,
        );
        return {'success': true};
      }
      final lists = {
        'list_student_documents': ('documents', 'documents'),
        'list_fee_payments': ('fee_payments', 'payments'),
        'list_school_expenses': ('school_expenses', 'expenses'),
      };
      if (lists.containsKey(action)) {
        final pair = lists[action]!;
        final rows = (await read(pair.$1)).entries
            .map((e) => {'documentId': e.key, ...e.value});
        return {
          'success': true,
          pair.$2: rows
              .where(
                (e) =>
                    action != 'list_student_documents' ||
                    e['studentId'] == data['studentId'],
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
        final file = await cloud.upload(
          '${data['receiptNo'] ?? secureSetupToken(12)}.pdf',
          'application/pdf',
          data['pdfBase64']?.toString() ?? '',
        );
        final id =
            data['paymentId']?.toString() ??
            data['receiptNo']?.toString() ??
            'FEE-${secureSetupToken(12)}';
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
          'exams': (await read('exams')).entries
              .map((e) => {'examId': e.key, ...e.value})
              .toList(),
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
        final merged = <String, dynamic>{...?old.data(), ...profile};
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
          'exams': {for (final d in legacyExams.docs) d.id: {'examId': d.id, ...d.data()}, for (final d in exams.docs) d.id: {'examId': d.id, ...d.data()}}.values.toList(),
          'results': {for (final d in legacyResults.docs) d.id: d.data(), for (final d in results.docs) d.id: d.data()}.values.toList(),
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
          'documents': snapshot.docs.map((d) => d.data()).toList(),
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

  static String publishedIdCardId(String qr) {
    final link = SchoolLink.parse(qr);
    return 'ID-${crypto.sha256.convert(utf8.encode('${link.role}/${link.personId}'))}';
  }

  static Future<void> publishIdCard({
    required Uint8List bytes,
    required String qr,
    required String kind,
    required Map<String, dynamic> person,
    required String inputRevision,
  }) async {
    final link = SchoolLink.parse(qr), db = FirebaseFirestore.instance;
    if (!link.managed ||
        link.schoolId != db.activeProfileIdentity['schoolSyncId'] ||
        person['mobileLinkToken'] != link.linkToken)
      throw StateError('Verified school ID owner required.');
    if (!await db.localPersistenceEnabled())
      throw StateError('Durable local school context required.');
    final id = publishedIdCardId(qr);
    await _documentWrite(() async {
      final old =
          (await db.collection('_local_student_documents').doc(id).get())
              .data();
      if (old?['inputRevision'] == inputRevision && old?['deleted'] != true)
        return;
      await _saveLocalStudentDocument({
        '_queueCloud': true,
        'replaceDocumentId': id,
        'studentId': link.personId,
        'studentName': person['name'],
        'studentClass': person['class'],
        'rollNo': person['rollNo'],
        'documentKind': 'idCard',
        'ownerRole': link.role,
        'personId': person['mobileStableId'] ?? link.personId,
        'inputRevision': inputRevision,
        'qr': qr,
        'documentName': 'School ID card • Front & back',
        'fileName': '$id.pdf',
        'mimeType': 'application/pdf',
        'fileBase64': base64Encode(bytes),
      });
    });
    onLocalDocumentCommitted?.call();
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
    final optimizedFile = File('${file.path}.optimized.$optimizedExtension');
    final highFile = File(
      '${file.path}.processed.${processing['mimeType'] == 'application/pdf' ? 'pdf' : 'jpg'}',
    );
    if (optimized != null)
      await optimizedFile.writeAsBytes(optimized, flush: true);
    if (highQuality != null)
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
      'deleted': false,
      'syncState': body['_queueCloud'] == true ? 'Pending' : 'Local',
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

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'windows_local_firestore.dart';
import 'windows_local_settings.dart';
import 'windows_local_storage.dart';
import 'windows_runtime_flags.dart';
import 'windows_service_status.dart';
import 'windows_firebase_sync.dart';

class WindowsBackendBridge {
  WindowsBackendBridge._();

  static FutureOr<void> Function()?
      onRemoteAvailable;

  static const Set<String> _mutatingActions =
      <String>{
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
    status.checking(
      WindowsServiceType.googleDrive,
      'Google Drive / Apps Script request chal raha hai...',
    );

    // Hard isolation guard: a stale page/profile is never allowed to send a
    // request to an old school's Apps Script after the active Drive changes.
    final activeUrl = await WindowsExternalConnections.googleScriptUrl();
    if (activeUrl.isEmpty || _normalizedUrl(activeUrl) != _normalizedUrl(url.toString())) {
      status.unhealthy(
        WindowsServiceType.googleDrive,
        'Inactive/old Google backend blocked by school isolation.',
      );
      return _localFallback(
        body,
        remoteError: 'Inactive Google backend blocked',
      );
    }

    Object? requestBody = body;
    try {
      final decoded = _decodeBody(body);
      final schoolSyncId = FirebaseFirestore.instance
              .activeProfileIdentity['schoolSyncId']
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
                result['message']?.toString() ?? 'School backend rejected the request.',
              );
              return response;
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
        return _localFallback(requestBody, remoteError: 'Invalid JSON response');
      }

      status.unhealthy(
        WindowsServiceType.googleDrive,
        'Google backend HTTP ${response.statusCode}. Local fallback active hai.',
      );

      await _queueFailedMutation(
        url,
        headers: headers,
        body: requestBody,
      );

      return _localFallback(
        requestBody,
        remoteError: 'HTTP ${response.statusCode}',
      );
    } catch (e) {
      status.unhealthy(
        WindowsServiceType.googleDrive,
        'Google backend unavailable: $e. Local fallback active hai.',
      );

      await _queueFailedMutation(
        url,
        headers: headers,
        body: requestBody,
      );

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
      final urlText =
          data['url']?.toString().trim() ?? '';
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
          headers[entry.key.toString()] =
              entry.value.toString();
        }
      }

      try {
        final response = await _postFollowingAppsScriptRedirects(
          Uri.parse(urlText),
          headers: headers.isEmpty
              ? const {
                  'Content-Type': 'text/plain;charset=utf-8',
                }
              : headers,
          body: jsonEncode(
            Map<String, dynamic>.from(bodyData),
          ),
        ).timeout(const Duration(seconds: 30));

        if (response.statusCode < 200 ||
            response.statusCode >= 300) {
          break;
        }

        final decoded = jsonDecode(response.body);

        if (decoded is! Map) {
          break;
        }

        final result =
            Map<String, dynamic>.from(decoded);

        final action =
            data['action']?.toString() ?? '';

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

    final action =
        decoded['action']?.toString().trim() ?? '';

    if (!_mutatingActions.contains(action)) {
      return;
    }

    final reference = FirebaseFirestore.instance
        .collection('_windows_google_outbox')
        .doc();

    await reference.set(
      <String, dynamic>{
        'action': action,
        'url': url.toString(),
        'headers': headers ??
            const <String, String>{
              'Content-Type':
                  'text/plain;charset=utf-8',
            },
        'body': decoded,
        'queuedAt': FieldValue.serverTimestamp(),
      },
    );
  }

  static bool _replayApplied(
    String action,
    Map<String, dynamic> result,
  ) {
    if (result['success'] == true) {
      return true;
    }

    final code =
        result['code']?.toString().toUpperCase() ??
            '';
    final message =
        result['message']?.toString().toLowerCase() ??
            '';

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

    return int.tryParse(
          value?.toString() ?? '',
        ) ??
        0;
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
        final isRedirect = code == 301 ||
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
        final message =
            data['error']?.toString().trim().isNotEmpty == true
                ? data['error'].toString()
                : data['message']?.toString().trim().isNotEmpty == true
                    ? data['message'].toString()
                    : 'Google Drive health check failed.';

        status.unhealthy(
          WindowsServiceType.googleDrive,
          message,
        );
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
      if (!await WindowsRuntimeFlags.localStorageEnabled()) {
        return http.Response(
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
      return http.Response(
        jsonEncode({
          ...result,
          'windowsLocalFallback': true,
          'remoteError': remoteError,
        }),
        200,
        headers: const {'content-type': 'application/json'},
      );
    } catch (e) {
      return http.Response(
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
        return {
          'success': true,
          'profile': doc.data() ?? <String, dynamic>{},
        };

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
        final merged = <String, dynamic>{
          ...?old.data(),
          ...profile,
        };
        await FirebaseFirestore.instance
            .collection('school_config')
            .doc('school_profile_cache')
            .set(merged, SetOptions(merge: true));
        return {'success': true, 'profile': merged};

      case 'list_exam_center':
        final exams = await FirebaseFirestore.instance
            .collection('_local_exam_center_exams')
            .get();
        final results = await FirebaseFirestore.instance
            .collection('_local_exam_center_results')
            .get();
        return {
          'success': true,
          'exams': exams.docs.map((d) => {'examId': d.id, ...d.data()}).toList(),
          'results': results.docs.map((d) => d.data()).toList(),
        };

      case 'save_exam':
        final examId = body['examId']?.toString().trim().isNotEmpty == true
            ? body['examId'].toString().trim()
            : 'EXAM-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9999).toString().padLeft(4, '0')}';
        final data = <String, dynamic>{
          ...body,
          'examId': examId,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }..remove('action');
        await FirebaseFirestore.instance
            .collection('_local_exam_center_exams')
            .doc(examId)
            .set(data, SetOptions(merge: true));
        return {'success': true, 'examId': examId};

      case 'save_exam_result':
        final examId = body['examId']?.toString() ?? '';
        final studentId = body['studentId']?.toString() ?? '';
        if (examId.isEmpty || studentId.isEmpty) {
          return {'success': false, 'message': 'Exam/Student ID missing.'};
        }
        final data = <String, dynamic>{
          ...body,
          'timestamp': DateTime.now().millisecondsSinceEpoch,
        }..remove('action');
        await FirebaseFirestore.instance
            .collection('_local_exam_center_results')
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
        final teacherId = body['teacherId']?.toString().trim().isNotEmpty == true
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

  static Future<Map<String, dynamic>>
      _localSyncSnapshot() async {
    Future<List<Map<String, dynamic>>> read(
      String collection, {
      String idField = 'id',
    }) async {
      final snapshot = await FirebaseFirestore.instance
          .collection(collection)
          .get();

      return snapshot.docs.map((doc) {
        final data =
            Map<String, dynamic>.from(doc.data());
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
      'students': await read(
        'students_directory',
        idField: 'documentId',
      ),
      'teachers': await read(
        'teachers_directory',
        idField: 'documentId',
      ),
      'feePayments': await read(
        'fee_payments',
        idField: 'paymentId',
      ),
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
      'exams': await read(
        '_local_exam_center_exams',
        idField: 'examId',
      ),
      'results': await read(
        '_local_exam_center_results',
        idField: 'documentId',
      ),
      'schoolProfile':
          profile.data() ?? <String, dynamic>{},
    };
  }

  static Future<Map<String, dynamic>> _saveLocalStudentDocument(
    Map<String, dynamic> body,
  ) async {
    final studentId = body['studentId']?.toString().trim() ?? '';
    if (studentId.isEmpty) {
      return {'success': false, 'message': 'Student ID missing.'};
    }

    final replaceId = body['replaceDocumentId']?.toString().trim() ?? '';
    final documentId = replaceId.isNotEmpty
        ? replaceId
        : 'DOC-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9999)}';
    final raw = body['fileBase64']?.toString() ?? '';
    final bytes = _decodeDataUri(raw);
    final safeName = _safeFileName(body['fileName']?.toString() ?? '$documentId.bin');

    final root = await WindowsLocalStorage.localFilesDirectory();
    final profileFolder = Directory(
      '${root.path}${Platform.pathSeparator}'
      '${_safeFileName(FirebaseFirestore.instance.activeProfileId)}',
    );
    final studentFolder = Directory(
      '${profileFolder.path}${Platform.pathSeparator}${_safeFileName(studentId)}',
    );
    await studentFolder.create(recursive: true);
    final file = File(
      '${studentFolder.path}${Platform.pathSeparator}${documentId}_$safeName',
    );
    await file.writeAsBytes(bytes, flush: true);

    if (replaceId.isNotEmpty) {
      final old = await FirebaseFirestore.instance
          .collection('_local_student_documents')
          .doc(replaceId)
          .get();
      final oldPath = old.data()?['localPath']?.toString() ?? '';
      if (oldPath.isNotEmpty && oldPath != file.path) {
        try {
          final oldFile = File(oldPath);
          if (await oldFile.exists()) await oldFile.delete();
        } catch (_) {}
      }
    }

    final metadata = <String, dynamic>{
      'documentId': documentId,
      'studentId': studentId,
      'studentName': body['studentName'] ?? '',
      'studentClass': body['studentClass'] ?? '',
      'rollNo': body['rollNo'] ?? '',
      'documentName': body['documentName'] ?? 'Document',
      'fileName': safeName,
      'mimeType': body['mimeType'] ?? '',
      'sizeBytes': bytes.length,
      'localPath': file.path,
      'fileUrl': Uri.file(file.path).toString(),
      'uploadedBy': body['uploadedBy'] ?? 'Admin',
      'uploadedAt': DateTime.now().millisecondsSinceEpoch,
    };

    await FirebaseFirestore.instance
        .collection('_local_student_documents')
        .doc(documentId)
        .set(metadata, SetOptions(merge: true));

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
    final old = await ref.get();
    final path = old.data()?['localPath']?.toString() ?? '';
    if (path.isNotEmpty) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
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

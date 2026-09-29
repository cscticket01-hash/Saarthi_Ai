import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

import 'windows_local_firestore.dart';
import 'windows_local_storage.dart';
import 'windows_service_status.dart';

class WindowsBackendBridge {
  WindowsBackendBridge._();

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

    try {
      final response = await http
          .post(
            url,
            headers: headers,
            body: body,
            encoding: encoding,
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        try {
          final decoded = jsonDecode(response.body);
          if (decoded is Map) {
            status.healthy(
              WindowsServiceType.googleDrive,
              'Google backend actual response OK (${response.statusCode}).',
            );
            return response;
          }
        } catch (_) {}

        status.unhealthy(
          WindowsServiceType.googleDrive,
          'Google backend response JSON invalid hai.',
        );
        return _localFallback(body, remoteError: 'Invalid JSON response');
      }

      status.unhealthy(
        WindowsServiceType.googleDrive,
        'Google backend HTTP ${response.statusCode}. Local fallback active hai.',
      );
      return _localFallback(
        body,
        remoteError: 'HTTP ${response.statusCode}',
      );
    } catch (e) {
      status.unhealthy(
        WindowsServiceType.googleDrive,
        'Google backend unavailable: $e. Local fallback active hai.',
      );
      return _localFallback(body, remoteError: e.toString());
    }
  }

  static Future<bool> testRemote(Uri url) async {
    final status = WindowsServiceStatus.instance;
    status.checking(
      WindowsServiceType.googleDrive,
      'Google Drive actual backend test chal raha hai...',
    );

    try {
      final response = await http
          .post(
            url,
            headers: const {
              'Content-Type': 'text/plain;charset=utf-8',
            },
            body: jsonEncode(const {'action': 'get_school_profile'}),
          )
          .timeout(const Duration(seconds: 25));

      if (response.statusCode != 200) {
        status.unhealthy(
          WindowsServiceType.googleDrive,
          'Google backend HTTP ${response.statusCode}.',
        );
        return false;
      }

      final decoded = jsonDecode(response.body);
      if (decoded is! Map) {
        throw const FormatException('Backend JSON invalid hai.');
      }

      status.healthy(
        WindowsServiceType.googleDrive,
        'Google Drive / Apps Script actual request successful.',
      );
      return true;
    } catch (e) {
      status.unhealthy(
        WindowsServiceType.googleDrive,
        'Google Drive test fail: $e',
      );
      return false;
    }
  }

  static Future<http.Response> _localFallback(
    Object? rawBody, {
    required String remoteError,
  }) async {
    try {
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
    final studentFolder = Directory(
      '${root.path}${Platform.pathSeparator}${_safeFileName(studentId)}',
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

  static String _safeFileName(String input) {
    final value = input
        .trim()
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ');
    return value.isEmpty ? 'file' : value;
  }
}

import 'promotion_session_policy.dart';
import 'windows_connect/central_school_cloud.dart';

import 'dart:convert';
import 'dart:math';

import 'windows_backend_bridge.dart';
import 'windows_firebase_sync.dart';
import 'platform/platform_config.dart';
import 'windows_connection_center.dart';
import 'windows_local_firestore.dart';
import 'windows_exam_policy.dart';

/// Local exam definitions/marks remain usable while school services are offline.
/// Pending edits belong to the current profile; they never migrate to another.
class WindowsExamService {
  static Future<Map<String, dynamic>> request(Map<String, dynamic> body) async {
    final profile = FirebaseFirestore.instance.activeProfileId;
    final action = body['action'];
    if (action != 'list_exam_center' &&
        action != 'save_exam' &&
        action != 'save_exam_result') {
      throw ArgumentError('Unsupported exam action');
    }
    final request = <String, dynamic>{...body};
    if (action == 'save_exam' &&
        (request['examId']?.toString().isEmpty ?? true)) {
      request['examId'] =
          'EXAM-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
    }
    if (action == 'save_exam') {
      final existing =
          (await FirebaseFirestore.instance
                  .collection('exams')
                  .doc(request['examId'].toString())
                  .get())
              .data();
      request['academicSession'] =
          existing?['academicSession'] ??
          request['academicSession'] ??
          PromotionSessionPolicy.label(
            DateTime.now(),
            await PromotionSessionPolicy.rolloverMonth(),
          );
      _requireProfile(profile);
    }
    // A normal Save is a record-only operation, even if a legacy caller
    // supplies old PDF bytes. Historical documents remain readable, but no
    // marks-save path is allowed to render, upload, or enqueue a PDF.
    if (action == 'save_exam_result') {
      request.remove('pdfBase64');
      final examId = request['examId']?.toString() ?? '';
      final studentId = request['studentId']?.toString() ?? '';
      if (examId.isEmpty || studentId.isEmpty) {
        throw StateError('Exam and student IDs are required.');
      }
      final exam = (await FirebaseFirestore.instance
          .collection('exams').doc(examId).get()).data();
      _requireProfile(profile);
      if (exam != null && exam['subjects'] is List &&
          request['marks'] is Map) {
        final full = WindowsExamPolicy.finiteNumber(exam['fullMarks']);
        final pass = WindowsExamPolicy.finiteNumber(exam['passMarks']);
        if (full == null || pass == null) {
          throw StateError('Invalid saved exam marks configuration.');
        }
        final subjects = WindowsExamPolicy.subjects(exam['subjects'] as List);
        final marks = WindowsExamPolicy.validateMarks(
          request['marks'] as Map,
          subjects: subjects,
          fullMarks: full,
          passMarks: pass,
        );
        final decision = WindowsExamPolicy.decision(marks, pass);
        if (request['result'] != null && request['result'] != decision) {
          throw StateError('Result does not match the subject marks.');
        }
        final maximum = WindowsExamPolicy.maximum(subjects.length, full);
        final total = WindowsExamPolicy.total(marks);
        request.addAll({
          'marks': marks,
          'result': decision,
          'fullMarks': full,
          'passMarks': pass,
          'totalMarks': total,
          'maximum': maximum,
          'percentage': maximum > 0 ? total / maximum * 100 : 0,
          'academicSession': exam['academicSession'],
        });
      }
    }
    final cloud = await CentralSchoolCloud.saved();
    _requireProfile(profile);
    final local = await WindowsBackendBridge.localExamAction(request);
    _requireProfile(profile);
    if (local['success'] != true) return local;
    // Managed saves use the original durable record/document queues.
    // Never duplicate them into a manual legacy exam queue.
    if (cloud['managed'] == true) {
      _requireProfile(profile);
      return {...local, 'cloudSyncPending': action != 'list_exam_center'};
    }
    final connection = await WindowsConnectionCenter.reload();
    _requireProfile(profile);
    if (action != 'list_exam_center') {
      await FirebaseFirestore.instance
          .collection('_windows_exam_pending')
          .doc(
            action == 'save_exam'
                ? request['examId'].toString()
                : '${request['examId']}_${request['studentId']}',
          )
          .set(request);
    }
    if (!connection.remoteReady) return local;
    try {
      // Only this profile's pending exam work is replayed, using stable IDs.
      final pending = await FirebaseFirestore.instance
          .collection('_windows_exam_pending')
          .get();
      for (final doc in pending.docs) {
        _requireProfile(profile);
        final sent = await _remote(connection.googleScriptUrl, doc.data());
        _requireProfile(profile);
        if (sent['success'] != true || sent['windowsLocalFallback'] == true)
          return local;
        await doc.reference.delete();
      }
      final remote = await _remote(connection.googleScriptUrl, {
        'action': 'list_exam_center',
      });
      _requireProfile(profile);
      if (remote['success'] != true || remote['windowsLocalFallback'] == true)
        return local;
      if (action == 'list_exam_center') {
        // A successful remote read seeds the offline cache without queueing it.
        await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() async {
          for (final exam
              in (remote['exams'] as List? ?? []).whereType<Map>()) {
            _requireProfile(profile);
            await WindowsBackendBridge.localExamAction({
              'action': 'save_exam',
              ...Map<String, dynamic>.from(exam),
            });
          }
          for (final result
              in (remote['results'] as List? ?? []).whereType<Map>()) {
            _requireProfile(profile);
            await WindowsBackendBridge.localExamAction({
              'action': 'save_exam_result',
              ...Map<String, dynamic>.from(result),
            });
          }
        });
        return {
          ...await WindowsBackendBridge.localExamAction(request),
          'windowsLocalFallback': false,
        };
      }
      return {...local, 'windowsLocalFallback': false};
    } catch (_) {
      _requireProfile(profile);
      return local;
    }
  }

  /// Only unused class exams may be removed. Failed verification keeps data.
  static Future<void> deleteUnusedExam(String examId) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{3,128}$').hasMatch(examId)) {
      throw StateError('Invalid exam identifier.');
    }
    final profile = FirebaseFirestore.instance.activeProfileId;
    final identity = FirebaseFirestore.instance.activeProfileIdentity;
    final schoolId = identity['schoolSyncId']?.toString() ?? '';
    final managed = await CentralSchoolCloud.saved();
    _requireProfile(profile);
    if (managed['managed'] != true || managed['schoolId'] != schoolId) {
      throw StateError(
        'Exam deletion requires the verified managed school connection. '
        'Legacy/offline records were preserved.',
      );
    }
    final local = await WindowsBackendBridge.localExamAction({
      'action': 'list_exam_center',
    });
    _requireProfile(profile);
    if (local['success'] != true) throw StateError('Exam list not verified.');
    final exams = (local['exams'] as List? ?? []).whereType<Map>();
    if (!exams.any((row) => row['examId']?.toString() == examId)) {
      throw StateError('Exam no longer exists. Refresh the screen.');
    }
    final results = (local['results'] as List? ?? []).whereType<Map>();
    if (results.any((row) => row['examId']?.toString() == examId)) {
      throw StateError('Saved marks exist. Delete is blocked to protect report cards.');
    }
    // Signed remote results must also be empty; offline deletes fail closed.
    final idToken = await CentralSchoolCloud.firebaseToken();
    for (final collection in const ['exam_center_results', 'exam_results']) {
      _requireProfile(profile);
      final remote = await WindowsFirebaseRemote.readCollection(
        projectId: platformProjectId, idToken: idToken, collection: collection,
      );
      if (remote.values.any((row) => row['examId']?.toString() == examId)) {
        throw StateError('Cloud marks exist; deleting this exam is not allowed.');
      }
    }
    _requireProfile(profile);
    final current = await CentralSchoolCloud.saved();
    if (current['schoolId'] != schoolId || current['uid'] != managed['uid']) {
      throw StateError('School identity changed. Delete cancelled.');
    }
    // Existing sync-tombstone tracking propagates this deletion to peer PCs.
    final db = FirebaseFirestore.instance;
    final batch = db.batch();
    // Atomic local delete avoids half-removed definitions in this PC.
    // The existing outbox still tracks cloud tombstones for peers.
    batch.delete(db.collection('exams').doc(examId));
    batch.delete(db.collection('_local_exam_center_exams').doc(examId));
    batch.delete(db.collection('school_settings').doc('exam_$examId'));
    _requireProfile(profile);
    await batch.commit();
  }

  static void _requireProfile(String profile) {
    if (FirebaseFirestore.instance.activeProfileId != profile) {
      throw StateError(
        'School changed during exam work. Reopen the exam screen.',
      );
    }
  }

  static Future<Map<String, dynamic>> _remote(
    String url,
    Map<String, dynamic> body,
  ) async {
    final response = await WindowsBackendBridge.post(
      Uri.parse(url),
      headers: const {'Content-Type': 'text/plain;charset=utf-8'},
      body: jsonEncode(body),
    );
    if (response.statusCode != 200) throw StateError('Exam sync failed');
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }
}

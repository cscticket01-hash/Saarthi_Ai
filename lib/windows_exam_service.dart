import 'dart:convert';
import 'dart:math';
import 'windows_backend_bridge.dart';
import 'windows_connection_center.dart';
import 'windows_local_firestore.dart';

/// Local exam definitions/marks remain usable while school services are offline.
/// Pending edits belong to the current profile; they never migrate to another.
class WindowsExamService {
  static Future<Map<String, dynamic>> request(Map<String, dynamic> body) async {
    final profile = FirebaseFirestore.instance.activeProfileId;
    final action = body['action'];
    if (action != 'list_exam_center' && action != 'save_exam' && action != 'save_exam_result') {
      throw ArgumentError('Unsupported exam action');
    }
    final request = <String, dynamic>{...body};
    if (action == 'save_exam' && (request['examId']?.toString().isEmpty ?? true)) {
      request['examId'] = 'EXAM-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
    }
    final local = await WindowsBackendBridge.localExamAction(request);
    _requireProfile(profile);
    if (local['success'] != true) return local;
    final connection = await WindowsConnectionCenter.reload();
    _requireProfile(profile);
    if (action != 'list_exam_center') {
      await FirebaseFirestore.instance.collection('_windows_exam_pending').doc(
        action == 'save_exam' ? request['examId'].toString() : '${request['examId']}_${request['studentId']}',
      ).set(request);
    }
    if (!connection.remoteReady) return local;
    try {
      // Only this profile's pending exam work is replayed, using stable IDs.
      final pending = await FirebaseFirestore.instance.collection('_windows_exam_pending').get();
      for (final doc in pending.docs) {
        _requireProfile(profile);
        final sent = await _remote(connection.googleScriptUrl, doc.data());
        _requireProfile(profile);
        if (sent['success'] != true || sent['windowsLocalFallback'] == true) return local;
        await doc.reference.delete();
      }
      final remote = await _remote(connection.googleScriptUrl, {'action': 'list_exam_center'});
      _requireProfile(profile);
      if (remote['success'] != true || remote['windowsLocalFallback'] == true) return local;
      if (action == 'list_exam_center') {
        // A successful remote read seeds the offline cache without queueing it.
        await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() async {
          for (final exam in (remote['exams'] as List? ?? []).whereType<Map>()) {
            _requireProfile(profile);
            await WindowsBackendBridge.localExamAction({'action': 'save_exam', ...Map<String, dynamic>.from(exam)});
          }
          for (final result in (remote['results'] as List? ?? []).whereType<Map>()) {
            _requireProfile(profile);
            await WindowsBackendBridge.localExamAction({'action': 'save_exam_result', ...Map<String, dynamic>.from(result)});
          }
        });
        return {...await WindowsBackendBridge.localExamAction(request), 'windowsLocalFallback': false};
      }
      return {...local, 'windowsLocalFallback': false};
    } catch (_) {
      _requireProfile(profile);
      return local;
    }
  }

  static void _requireProfile(String profile) {
    if (FirebaseFirestore.instance.activeProfileId != profile) {
      throw StateError('School changed during exam work. Reopen the exam screen.');
    }
  }

  static Future<Map<String, dynamic>> _remote(String url, Map<String, dynamic> body) async {
    final response = await WindowsBackendBridge.post(Uri.parse(url),
      headers: const {'Content-Type': 'text/plain;charset=utf-8'}, body: jsonEncode(body));
    if (response.statusCode != 200) throw StateError('Exam sync failed');
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }
}

import 'promotion_session_policy.dart';
import 'windows_connect/central_school_cloud.dart';

import 'dart:convert';
import 'dart:math';

import 'windows_backend_bridge.dart';
import 'windows_firebase_sync.dart';
import 'platform/platform_config.dart';
import 'windows_connection_center.dart';
import 'windows_local_firestore.dart';
import 'windows_document_templates.dart';
import 'windows_connect/atomic_bundle_pilot.dart';
import 'school_media_budgets.dart';
import 'dart:typed_data';

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
    final cloud=await CentralSchoolCloud.saved();
    _requireProfile(profile);
    Map<String,dynamic> local;
    if(action=='save_exam_result' && cloud['managed']==true &&
       AtomicBundlePilot.buildEnabled) {
      final db=FirebaseFirestore.instance;
      final school=db.activeProfileIdentity['schoolSyncId']?.toString()??'';
      final examId=request['examId']?.toString().trim()??'';
      final studentId=request['studentId']?.toString().trim()??'';
      final marks=request['marks'];
      if(cloud['schoolId']!=school||
         (request['schoolId']!=null&&request['schoolId']!=school))
        throw StateError('Exam Save belongs to another school.');
      final student=studentId.isEmpty?null:
        (await db.collection('students_directory').doc(studentId).get()).data();
      final exam=examId.isEmpty?null:
        (await db.collection('exams').doc(examId).get()).data();
      _requireProfile(profile);
      if(student!=null&&exam!=null&&marks is Map&&marks.isNotEmpty&&
         student['mobileStableId'] is String&&
         (student['mobileStableId'] as String).isNotEmpty&&
         student['deleted']!=true&&student['_syncDeleted']!=true&&
         (student['schoolId']==null||student['schoolId']==school)&&
         (exam['schoolId']==null||exam['schoolId']==school)) {
        final raw=request['pdfBase64']?.toString().trim()??'';
        Uint8List? pdf;
        if(raw.isNotEmpty) {
          // Caller supplied one exact school-generated PDF; its digest and
          // immutable bytes are validated again by the original local owner.
          if(raw.length>220000)throw StateError('Marksheet is too large.');
          pdf=Uint8List.fromList(base64Decode(
            raw.startsWith('data:application/pdf;base64,')?
              raw.substring('data:application/pdf;base64,'.length):raw));
        } else {
          pdf=await WindowsDocumentTemplates.selected('reportCard',{
            ...student,...exam,...request,
            'schoolId':school,'examId':examId,'studentId':studentId,
            'personId':student['mobileStableId'],
            'studentName':request['studentName']??student['name'],
            'examName':request['examName']??exam['examName'],
          });
        }
        _requireProfile(profile);
        if(pdf==null)throw StateError('Marksheet template unavailable.');
        SchoolMediaBudgets.verifyGeneratedPdf('marksheet',pdf);
        local={
          ...await WindowsBackendBridge.saveExamResultWithMarksheet(
            profileId:profile,result:request,pdfBytes:pdf),
          'windowsLocalFallback':true,'sessionOnly':false,
        };
      } else {
        // Old/offline/legacy records are never rewritten under a second
        // exam collection just to satisfy the isolated new-bundle pilot.
        local=await WindowsBackendBridge.localExamAction(request);
      }
    }else{
      local=await WindowsBackendBridge.localExamAction(request);
    }
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
    await FirebaseFirestore.instance.collection('exams').doc(examId).delete();
    _requireProfile(profile);
    await FirebaseFirestore.instance.collection('_local_exam_center_exams')
        .doc(examId).delete();
    _requireProfile(profile);
    await FirebaseFirestore.instance.collection('school_settings')
        .doc('exam_$examId').delete();
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

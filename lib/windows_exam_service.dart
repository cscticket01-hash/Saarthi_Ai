import 'promotion_session_policy.dart';
import 'windows_connect/central_school_cloud.dart';

import 'dart:convert';
import 'dart:math';

import 'windows_backend_bridge.dart';
import 'windows_connect/managed_school_session.dart';
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
    final school = FirebaseFirestore.instance.activeProfileIdentity['schoolSyncId']
        ?.toString() ?? '';
    if (school.isNotEmpty) {
      if (request['schoolId'] != null && request['schoolId'] != school) {
        throw StateError('Cannot save another school\'s exam data.');
      }
      request['schoolId'] = school;
    }
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
          .collection('exams').doc(examId).get()).data() ??
          (await FirebaseFirestore.instance
          .collection('_local_exam_center_exams').doc(examId).get()).data();
      _requireProfile(profile);
      if (exam == null ||
          exam['schoolId'] != null && exam['schoolId'] != school) {
        throw StateError('A verified same-school exam must exist before saving marks.');
      }
      if (request['marks'] is! Map) {
        throw StateError('Enter complete marks before saving an exam result.');
      }
      // A final result that already changed the student's class cannot be
      // silently rewritten. An explicit audited correction workflow is needed.
      if (exam?['isFinal'] == true || request['isFinal'] == true) {
        final pupil = (await FirebaseFirestore.instance
            .collection('students_directory').doc(studentId).get()).data();
        _requireProfile(profile);
        if (pupil?['promotionExamId'] == examId &&
            {'PROMOTED','FORCE_PROMOTED','GRADUATED'}
                .contains(pupil?['classMovement'])) {
          throw StateError(
            'This Final Exam promotion is already approved. '
            'Use an audited correction before changing its marks.');
        }
      }
      if (exam['subjects'] is List) {
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
      } else {
        throw StateError('Exam subjects must be configured before marks can be saved.');
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

  /// All new class definitions are committed in one durable local transaction
  /// before the sync engine admits any individual Cloudflare record.
  /// Legacy schools retain their existing compatibility route.
  static Future<List<String>> createClassExamGroup(
    List<Map<String, dynamic>> configs,
  ) async {
    if (configs.isEmpty) return [];
    final db = FirebaseFirestore.instance;
    final profile = db.activeProfileId;
    final schoolId =
        db.activeProfileIdentity['schoolSyncId']?.toString() ?? '';
    final connection = await CentralSchoolCloud.saved();
    _requireProfile(profile);
    if (connection['managed'] != true ||
        connection['schoolId'] != schoolId) {
      final created = <String>[];
      for (final payload in configs) {
        final result = await request({'action': 'save_exam', ...payload});
        _requireProfile(profile);
        if (result['success'] != true) {
          throw StateError('Legacy exam Save failed after ${created.length} records.');
        }
        created.add(result['examId']?.toString() ?? '');
      }
      return created;
    }

    await db.ensureDurableSchoolRecords();
    _requireProfile(profile);
    final existing = await db.collection('exams').get();
    _requireProfile(profile);
    final seen = <String>{};
    final batch = db.batch();
    final ids = <String>[];
    for (final row in configs) {
      final id = row['examId']?.toString().trim() ?? '';
      final name = row['examName']?.toString().trim() ?? '';
      final studentClass = row['studentClass']?.toString().trim() ?? '';
      final session = row['academicSession']?.toString().trim() ?? '';
      final subjectsRaw = row['subjects'];
      final full = WindowsExamPolicy.finiteNumber(row['fullMarks']);
      final pass = WindowsExamPolicy.finiteNumber(row['passMarks']);
      if (!RegExp(r'^[A-Za-z0-9_-]{3,128}$').hasMatch(id) ||
          name.isEmpty || studentClass.isEmpty || session.isEmpty ||
          subjectsRaw is! List || full == null || full <= 0 ||
          pass == null || pass < 0 || pass > full) {
        throw StateError('Incomplete class exam definition.');
      }
      final subjects = WindowsExamPolicy.subjects(subjectsRaw);
      final uniqueness = '${name.toLowerCase()}|${studentClass.toLowerCase()}|$session';
      if (!seen.add(uniqueness)) {
        throw StateError('Repeated class configuration in one exam group.');
      }
      if (existing.docs.any((doc) {
        final old = doc.data();
        if (doc.id == id || old['deleted'] == true ||
            old['_syncDeleted'] == true) return false;
        return old['examName']?.toString().trim().toLowerCase() ==
                   name.toLowerCase() &&
            old['studentClass']?.toString().trim().toLowerCase() ==
                   studentClass.toLowerCase() &&
            old['academicSession'] == session;
      })) {
        throw StateError('$name already exists for $studentClass ($session).');
      }
      batch.set(db.collection('exams').doc(id), {
        ...row,
        'schoolId': schoolId,
        'examId': id,
        'examName': name,
        'studentClass': studentClass,
        'academicSession': session,
        'subjects': subjects,
        'fullMarks': full,
        'passMarks': pass,
        'timestamp': row['timestamp'] ?? DateTime.now().millisecondsSinceEpoch,
      });
      ids.add(id);
    }
    _requireProfile(profile);
    final current = await CentralSchoolCloud.saved();
    if (current['schoolId'] != schoolId ||
        current['uid'] != connection['uid']) {
      throw StateError('School changed before exam group Save.');
    }
    await batch.commit();
    _requireProfile(profile);
    return ids;
  }


  static Future<void> completeExam(String examId) async {
    if (!RegExp(r'^[A-Za-z0-9_-]{3,128}$').hasMatch(examId)) {
      throw StateError('Invalid exam identifier.');
    }
    final db = FirebaseFirestore.instance;
    final profile = db.activeProfileId;
    final ref = db.collection('exams').doc(examId);
    final exam = (await ref.get()).data();
    if (exam == null || exam['deleted'] == true || exam['_syncDeleted'] == true) {
      throw StateError('Exam no longer exists.');
    }
    if (exam['completedAt'] != null) return;
    final className = exam['studentClass']?.toString() ?? '';
    if (className.isEmpty) throw StateError('Exam class is missing.');
    final students = await db.collection('students_directory')
        .where('class', isEqualTo: className).get();
    final snapshot = await WindowsBackendBridge.localExamAction({
      'action': 'list_exam_center',
    });
    _requireProfile(profile);
    if (snapshot['success'] != true) throw StateError('Exam results unavailable.');
    final results = (snapshot['results'] as List? ?? []).whereType<Map>()
        .where((row) => row['examId'] == examId && row['deleted'] != true &&
            row['_syncDeleted'] != true &&
            (row['result'] == 'PASS' || row['result'] == 'FAIL'))
        .map((row) => row['studentId']?.toString()).whereType<String>().toSet();
    final active = students.docs
        .where((doc) => WindowsExamPolicy.activeStudent(doc.data()))
        .map((doc) => doc.id);
    final expected = int.tryParse(exam['expectedStudentCount']?.toString() ?? '') ?? 0;
    if (results.isEmpty || results.length < expected ||
        active.any((id) => !results.contains(id))) {
      throw StateError('Save all pending marks before completing this exam.');
    }
    final batch = db.batch();
    batch.requireUnchanged(ref, exam);
    batch.set(ref, {'completedAt': DateTime.now().millisecondsSinceEpoch},
        SetOptions(merge: true));
    await batch.commit();
  }

  /// Remove a class exam and its verified saved marks together.
  static Future<void> deleteExamWithResults(String examId) async {
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
    bool hasSavedMarks(Map row) =>
        row['examId']?.toString() == examId &&
        row['deleted'] != true && row['_syncDeleted'] != true;
    final remoteMatches = <String, Map<String, Map>>{};
    // Ask the managed broker for a complete read from each current owner.
    for (final collection in const ['exam_center_results', 'exam_results']) {
      _requireProfile(profile);
      final reply = await ManagedSchoolSession.callForSchool(
        schoolId, 'managed/records', {
          'operation': 'read',
          'collection': collection,
          'syncProtocol': 2,
          'liveProtocol': 1,
        },
      );
      _requireProfile(profile);
      final records = reply['records'];
      if (reply['success'] != true || reply['schoolId'] != schoolId ||
          reply['syncProtocol'] != 2 ||
          reply['partialRecords'] == true || reply['unchanged'] == true ||
          records is! Map ||
          records.values.any((row) => row is! Map || row['schoolId'] != schoolId)) {
        throw StateError('Unable to verify school marks for exam deletion.');
      }
      remoteMatches[collection] = {
        for (final entry in records.entries)
          if (hasSavedMarks(entry.value as Map)) entry.key.toString(): entry.value as Map,
      };
    }
    _requireProfile(profile);
    final current = await CentralSchoolCloud.saved();
    if (current['schoolId'] != schoolId || current['uid'] != managed['uid']) {
      throw StateError('School identity changed. Delete cancelled.');
    }
    final db = FirebaseFirestore.instance;
    final batch = db.batch();
    for (final collection in const [
      'exam_center_results', 'exam_results', '_local_exam_center_results',
    ]) {
      final ref = db.collection(collection);
      final snapshot = await ref.get();
      _requireProfile(profile);
      final matching = {
        for (final row in snapshot.docs)
          if (hasSavedMarks(row.data())) row.id: row,
      };
      for (final entry in remoteMatches[collection]?.entries ?? const <MapEntry<String, Map>>[]) {
        final row = matching[entry.key]?.data();
        final revision = entry.value['_syncRevision'];
        if (row == null || revision is! String || revision.isEmpty ||
            row['_syncRevision'] != revision) {
          throw StateError('Sync the latest marks to this PC and retry delete.');
        }
      }
      for (final row in matching.values) {
        batch.requireUnchanged(row.reference, row.data());
        batch.delete(row.reference);
      }
    }
    for (final entry in {
      'exams': examId,
      '_local_exam_center_exams': examId,
      'school_settings': 'exam_$examId',
    }.entries) {
      final ref = db.collection(entry.key).doc(entry.value);
      final record = (await ref.get()).data();
      _requireProfile(profile);
      batch.requireUnchanged(ref, record);
      if (record != null) batch.delete(ref);
    }
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

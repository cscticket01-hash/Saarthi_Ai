import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image/image.dart' as img;

import '../lib/windows_backend_bridge.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/platform/platform_config.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final db = FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      CentralSchoolCloud.key: jsonEncode({
        'managed': true,
        'schoolId': school,
        'uid': 'A',
        'projectId': platformProjectId,
        'endpoint': 'https://unreachable.example/school-cloud',
        'folderId': 'managed',
        'firebaseRefreshToken': 'saved-refresh',
        'email': 'a@example.com',
        'storageReady': false,
      }),
    });
    await WindowsRuntimeFlags.setLocalStorageEnabled(true);
    await db.switchProfile(
      'documents-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolSyncId': school, 'schoolId': school},
    );
  });
  test('offline replacement is durable, retains originals and queues only the newest generation', () async {
    final image = img.Image(width: 300, height: 400);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    final bytes = img.encodeJpg(image);
    Future<Map> save([String id = '']) async {
      final response = await WindowsBackendBridge.post(
        Uri.parse('https://unreachable.example'),
        body: jsonEncode({
          'action': 'upload_student_document',
          'studentId': 'S-1',
          'documentName': 'Birth Certificate',
          'fileName': 'scan.jpg',
          'mimeType': 'image/jpeg',
          'fileBase64': base64Encode(bytes),
          'replaceDocumentId': id,
        }),
      );
      return jsonDecode(response.body) as Map;
    }

    final first = await save();
    expect(first['cloudSyncPending'], true);
    final id = first['documentId'] as String,
        old = (first['document'] as Map)['originalPath'] as String;
    final second = await save(id),
        current = (second['document'] as Map)['originalPath'] as String;
    expect(current, isNot(old));
    expect(await File(old).readAsBytes(), bytes);
    expect(await File(current).readAsBytes(), bytes);
    final queue = (await db.collection('_windows_document_outbox').get()).docs;
    expect(queue.length, 1);
    expect(queue.single.data()['localPath'], current);
    final origin = db.activeProfileId;
    await db.switchProfile(
      'foreign-documents',
      identity: {'schoolSyncId': 'other'},
    );
    expect(
      (await db.collection('_local_student_documents').get()).docs,
      isEmpty,
    );
    await db.switchProfile(
      origin,
      identity: {'schoolSyncId': school, 'schoolId': school},
    );
    expect(
      (await db.collection('_windows_document_outbox').get()).docs.single
          .data()['localPath'],
      current,
    );
    expect(
      (await db.collection('_local_student_documents').doc(id).get())
          .data()?['syncState'],
      'Pending',
    );
    await expectLater(
      WindowsBackendBridge.flushDocumentPending(
        send: (_) async => throw StateError('offline'),
      ),
      throwsStateError,
    );
    expect(
      (await db.collection('_windows_document_outbox').get()).docs.length,
      1,
    );
    await WindowsBackendBridge.flushDocumentPending(
      send: (payload) async {
        expect(payload['schoolId'], school);
        await save(id);
        return {
          'success': true,
          'fileUrl': 'https://drive.google.com/file/d/old/view',
          'document': {
            'documentRevision': payload['documentRevision'],
            'uploadedAt': 42,
          },
        };
      },
    );
    expect(
      (await db.collection('_windows_document_outbox').get()).docs.length,
      1,
    );
    await WindowsBackendBridge.flushDocumentPending(
      send: (payload) async => {
        'success': true,
        'fileUrl': 'https://drive.google.com/file/d/current/view',
        'document': {
          'documentRevision': payload['documentRevision'],
          'uploadedAt': 43,
        },
      },
    );
    expect(
      (await db.collection('_windows_document_outbox').get()).docs,
      isEmpty,
    );
    final deletion = await WindowsBackendBridge.post(
      Uri.parse('https://unreachable.example'),
      body: jsonEncode({
        'action': 'delete_student_document',
        'studentId': 'S-1',
        'documentId': id,
      }),
    );
    expect((jsonDecode(deletion.body) as Map)['cloudSyncPending'], true);
    await WindowsBackendBridge.flushDocumentPending(
      send: (payload) async {
        expect(payload['action'], 'delete_student_document');
        return {'success': true};
      },
    );
    expect(await File(old).exists(), true);
    expect(
      (await db.collection('_local_student_documents').doc(id).get())
          .data()?['deleted'],
      true,
    );
  });
}

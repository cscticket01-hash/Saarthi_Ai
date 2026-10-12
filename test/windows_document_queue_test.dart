import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;

import '../lib/windows_backend_bridge.dart';
import '../lib/storage/windows_sqlite_store.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_local_storage.dart';
import '../lib/windows_connect/managed_school_session.dart';
import '../lib/platform/platform_config.dart';

// Isolated signed-readback fixture. A legacy success bool is intentionally insufficient.
Map<String,dynamic> documentAckFixture(Map<String,dynamic> payload, int at, {String? url}) => {
  'success':true, 'cloudVerified':true, 'schoolId':payload['schoolId'], 'fileUrl':url,
  'document':{...payload, 'id':payload['documentId'], 'schoolId':payload['schoolId'],
    '_syncRevision':'fixture-record-$at', 'uploadedAt':at,
    if(payload['action']=='delete_student_document') '_syncDeleted':true,
    if(payload['action']=='delete_student_document') 'documentRevision':payload['baseCloudRevision'],
  },
};

Future<Map<String, dynamic>> persistedRoot() async {
  final sqlite = await WindowsLocalStorage.sqliteFile();
  if (WindowsLocalStorage.sqliteEnabled && await sqlite.exists()) {
    final store = await WindowsSqliteStore.open(sqlite.path);
    try {
      return await store.readAllRoot();
    } finally {
      await store.close();
    }
  }
  final file = await WindowsLocalStorage.databaseFile();
  return await file.exists()
      ? Map<String, dynamic>.from(jsonDecode(await file.readAsString()))
      : {'profiles': {}};
}

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
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile(
      'documents-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolSyncId': school, 'schoolId': school},
    );
  });
  test('document review measures retained bytes and rejects foreign-school files', () async {
    final dir=await Directory.systemTemp.createTemp('document-review-proof');
    try {
      final file=File('${dir.path}/original');await file.writeAsBytes([1,2,3]);
      final row={'schoolId':school,'localPath':file.path,'documentRevision':'op','studentId':'S1'};
      final proof=await WindowsBackendBridge.documentReviewPayload('doc',row);
      expect(proof['contentHash'],matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(await file.readAsBytes(),[1,2,3]);
      await expectLater(WindowsBackendBridge.documentReviewPayload('doc',{...row,'schoolId':'foreign'}),throwsStateError);
      expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty);
    } finally {await dir.delete(recursive:true);}
  });
  test('document revision conflict retains original and allows independent ACK', () async {
    final dir = await Directory.systemTemp.createTemp('document-conflict-');
    try {
      for (final id in ['conflict-doc', 'independent-doc']) {
        final path = '${dir.path}/$id';
        await File(path).writeAsBytes([1, 2, 3]);
        final row = {'schoolId':school, 'documentRevision':'revision-$id',
          'localPath':path, 'syncState':'Pending', 'baseCloudRevision':'base',
          'studentId':'S1', 'deleted':false};
        await db.collection('_local_student_documents').doc(id).set(row);
        await db.collection('_windows_document_outbox').doc(id).set(row);
      }
      final sent = <String>[];
      await expectLater(WindowsBackendBridge.flushDocumentPending(send:(payload) async {
        final id = payload['documentId'] as String;
        sent.add(id);
        if (id == 'conflict-doc') throw CentralCloudException(409,'school_cloud',
          'Document version conflict; both copies retained',
          diagnosticCode:'SCRIPT_DOCUMENT_REVISION_CONFLICT');
        return documentAckFixture(payload,42);
      }), throwsA(isA<CentralCloudException>()));
      expect(sent, containsAll(['conflict-doc','independent-doc']));
      final retained = (await db.collection('_windows_document_outbox').doc('conflict-doc').get()).data()!;
      expect(retained['syncState'],'conflict');
      expect(retained['documentRevision'],'revision-conflict-doc');
      expect(retained['baseCloudRevision'],'base');
      expect(await File(retained['localPath'] as String).exists(),true);
      expect((await db.collection('_windows_document_outbox').doc('independent-doc').get()).exists,false);
      expect((await db.collection('_local_student_documents').doc('independent-doc').get()).data()?['syncState'],'Synced');
    } finally { await dir.delete(recursive:true); }
  });
  test('malformed legacy pending request is retained instead of acknowledged', () async {
    final ref = db.collection('_windows_google_outbox').doc('retained-invalid');
    await ref.set({'operationId': 'original-operation', 'body': 'invalid', 'queuedAt': 42});
    expect(await WindowsBackendBridge.flushPending(), 0);
    final retained = (await ref.get()).data()!;
    expect(retained['operationId'], 'original-operation');
    expect(retained['queuedAt'], 42);
    expect(retained['body'], 'invalid');
    expect(retained['syncState'], 'needsAttention');
  });
  test('legacy duplicate and missing-record responses never guess an ACK', () async {
    const url='https://script.google.com/macros/s/ReviewedTestDeployment/exec';
    for(final result in [
      {'success':false,'code':'STUDENT_ALREADY_EXISTS','message':'already exists'},
      {'success':false,'message':'record not found'},
      {'success':false,'message':'already deleted'},
    ]) {
      final ref=db.collection('_windows_google_outbox').doc('legacy-retained');
      final body={'operationId':'original-operation','schoolId':school,'name':'Original'};
      await ref.set({'action':result.containsKey('code')?'add_student':'delete_student',
        'url':url,'body':body,'queuedAt':42});
      final events=<Map<String,dynamic>>[];
      expect(await WindowsBackendBridge.flushPending(readActiveUrl:()async=>url,
        send:(a,b,c)async=>http.Response(jsonEncode(result),200),onActivity:events.add),0);
      final retained=(await ref.get()).data()!;
      expect(retained['body'],body);expect(retained['queuedAt'],42);
      expect(retained['syncState'],'needsAttention');
      expect(events.any((event)=>event['stage']=='verified'),false);
    }
  });
  test('unclassified document failure is retained for review rather than blind retry', () async {
    final ref=db.collection('_windows_document_outbox').doc('unknown-original');
    await ref.set({'schoolId':school,'documentRevision':'original-revision',
      'deleted':true,'localPath':''});
    await expectLater(WindowsBackendBridge.flushDocumentPending(
      send:(_)async=>throw StateError('Synthetic unclassified failure')),throwsStateError);
    final retained=(await ref.get()).data()!;
    expect(retained['documentRevision'],'original-revision');
    expect(retained['syncState'],'needsAttention');
    expect(retained['failureCategory'],'unknown');
    await WindowsBackendBridge.flushDocumentPending(send:(_)async=>fail('Review row must not retry'));
    expect((await ref.get()).exists,true);
  });
  test('pause prevents pending admission without changing queued evidence', () async {
    final ref = db.collection('_windows_google_outbox').doc('paused-original');
    await ref.set({'operationId': 'original-operation', 'body': 'invalid', 'queuedAt': 42});
    final before = (await ref.get()).data();
    expect(await WindowsBackendBridge.flushPending(canAdmit: () => false), 0);
    expect((await ref.get()).data(), before);
    await db.collection('_windows_document_outbox').doc('paused-document').set({
      'operationId': 'original-document', 'schoolId': school,
    });
    await WindowsBackendBridge.flushDocumentPending(
      canAdmit: () => false,
      send: (_) async => fail('Paused request must not be sent'),
    );
    expect((await db.collection('_windows_document_outbox').get()).docs, hasLength(1));
  });
  test(
      'synced multilingual inventory JSON is decoded without treating metadata as paths',
      () async {
    final metadata = <String, dynamic>{
      'schoolId': school,
      'studentId': 'S-1',
      'documentId': 'doc-unicode',
      'documentName': 'জন্ম সনদ – विद्यालय',
      'fileId': 'existing-drive-file',
      'fileUrl': 'https://drive.google.com/file/d/existing-drive-file/view',
      'localPath': r'C:\School\documents\scan.pdf',
      'documentRevision': 'preserved-revision',
      'syncState': 'Synced',
      'mimeType': 'application/pdf',
      'sizeBytes': 12345,
    };
    expect(
        () => http.Response(
            jsonEncode({
              'documents': [metadata]
            }),
            200),
        throwsArgumentError);
    await db.collection('documents').doc('doc-unicode').set(metadata);
    final response = await WindowsBackendBridge.post(Uri.parse(''),
        body: jsonEncode(
            {'action': 'list_student_documents', 'studentId': 'S-1'}));
    expect(response.statusCode, 200);
    final rows = jsonDecode(response.body)['documents'] as List;
    expect(rows.single['documentName'], metadata['documentName']);
    expect(rows.single['fileId'], metadata['fileId']);
    expect(rows.single['localPath'], metadata['localPath']);
    expect(WindowsBackendBridge.normalizedDocumentPath(response.body), isNull);
    expect(WindowsBackendBridge.normalizedDocumentPath(metadata), isNull);
    expect(WindowsBackendBridge.normalizedDocumentPath(metadata['fileUrl']),
        isNull);
    expect(
        WindowsBackendBridge.normalizedDocumentPath('bad\u0000path'), isNull);
    final record =
        (await db.collection('documents').doc('doc-unicode').get()).data();
    expect(record!['documentRevision'], 'preserved-revision');
    final origin = db.activeProfileId;
    await db.switchProfile('inventory-restart-away');
    await db.switchProfile(origin,
        identity: {'schoolId': school, 'schoolSyncId': school});
    final reopened = await WindowsBackendBridge.post(Uri.parse(''),
        body: jsonEncode(
            {'action': 'list_student_documents', 'studentId': 'S-1'}));
    expect(jsonDecode(reopened.body)['documents'].single['fileId'],
        'existing-drive-file');
  });
  test(
      'offline replacement is durable, retains originals and queues only the newest generation',
      () async {
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
    // Read the persisted file, then discard session RAM and reopen the tenant.
    final disk = await persistedRoot();
    expect(disk['profiles'][origin]['collections']['_windows_document_outbox'],
        isNotEmpty);
    await db.resetVolatileSession();
    await db.switchProfile(
      'foreign-documents',
      identity: {'schoolSyncId': 'other'},
    );
    expect(
        (await db.collection('_local_student_documents').get()).docs, isEmpty);
    await expectLater(save(), throwsStateError);
    await db.switchProfile(
      origin,
      identity: {'schoolSyncId': school, 'schoolId': school},
    );
    expect(
      (await db.collection('_windows_document_outbox').get())
          .docs
          .single
          .data()['localPath'],
      current,
    );
    expect(
      (await db.collection('_local_student_documents').doc(id).get())
          .data()?['syncState'],
      'Pending',
    );
    for (final outage in [
      const SocketException('Synthetic offline path'),
      TimeoutException('Synthetic provider response timeout'),
      CentralCloudException(503,'school_cloud','Synthetic provider unavailable')
    ]) {
      await expectLater(
          WindowsBackendBridge.flushDocumentPending(
              send: (_) async => throw outage),
          throwsA(same(outage)));
      expect((await db.collection('_windows_document_outbox').get()).docs,
          hasLength(1));
      final retry = (await db.collection('_windows_document_outbox').get())
          .docs
          .single
          .data();
      expect(retry['syncState'], 'retry');
      expect(retry['retryCount'], greaterThan(0));
    }
    expect(
      (await db.collection('_windows_document_outbox').get()).docs.length,
      1,
    );
    await WindowsBackendBridge.flushDocumentPending(
      send: (payload) async {
        expect(payload['schoolId'], school);
        await save(id);
        return documentAckFixture(payload,42,url:'https://drive.google.com/file/d/old/view');
      },
    );
    expect(
      (await db.collection('_windows_document_outbox').get()).docs.length,
      1,
    );
    await WindowsBackendBridge.flushDocumentPending(
      send: (payload) async => documentAckFixture(payload,43,url:'https://drive.google.com/file/d/current/view'),
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
        return documentAckFixture(payload,44);
      },
    );
    expect(await File(old).exists(), true);
    expect(
      (await db.collection('_local_student_documents').doc(id).get())
          .data()?['deleted'],
      true,
    );
  });
  test(
      'malformed image and truncated PDF cannot create managed documents or outbox records',
      () async {
    for (final item in [
      {
        'mime': 'image/jpeg',
        'bytes': [1, 2, 3]
      },
      {
        'mime': 'application/pdf',
        'bytes': utf8.encode('%PDF-1.7 incomplete body')
      },
    ]) {
      await expectLater(
          WindowsBackendBridge.post(Uri.parse('https://unreachable.example'),
              body: jsonEncode({
                'action': 'upload_student_document',
                'studentId': 'S-1',
                'documentName': 'Bad',
                'fileName': 'bad',
                'mimeType': item['mime'],
                'fileBase64': base64Encode(item['bytes'] as List<int>)
              })),
          throwsFormatException);
      expect((await db.collection('_local_student_documents').get()).docs,
          isEmpty);
      expect((await db.collection('_windows_document_outbox').get()).docs,
          isEmpty);
    }
  });

  test('blocked and foreign school context cannot persist or save documents',
      () async {
    for (final identity in [
      {'schoolSyncId': school, 'schoolId': school, 'blocked': true},
      {
        'schoolSyncId': school,
        'schoolId': 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
      },
    ]) {
      await db.switchProfile('invalid-document-context', identity: identity);
      expect(await db.localPersistenceEnabled(), false);
      await expectLater(
          WindowsBackendBridge.post(Uri.parse('https://unreachable.example'),
              body: jsonEncode({
                'action': 'upload_student_document',
                'studentId': 'S-1',
                'fileBase64': base64Encode([1, 2, 3])
              })),
          throwsStateError);
      expect((await db.collection('_windows_document_outbox').get()).docs,
          isEmpty);
    }
  });

  test(
      'standalone legacy OFF remains RAM-only without a managed school identity',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final profile = 'standalone-${DateTime.now().microsecondsSinceEpoch}';
    await db.switchProfile(profile);
    expect(await db.localPersistenceEnabled(), false);
    await db
        .collection('notices')
        .doc('temporary')
        .set({'text': 'session-only'});
    final disk = await persistedRoot();
    expect((disk['profiles'] as Map).containsKey(profile), false);
    await db.resetVolatileSession();
    expect((await db.collection('notices').get()).docs, isEmpty);
  });

  test(
      'managed logout/session change invalidates the storage binding without changing legacy preference',
      () async {
    expect(await db.localPersistenceEnabled(), true);
    FlutterSecureStorage.setMockInitialValues({});
    ManagedSchoolSession.changed.value++;
    expect(await db.localPersistenceEnabled(), false);
    expect(await WindowsRuntimeFlags.localStorageEnabled(), false);
  });
}

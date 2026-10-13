import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../lib/windows_backend_bridge.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/platform/platform_config.dart';
import '../lib/school_qr_link.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final db = FirebaseFirestore.instance;
  late Directory dir;
  late Map<String, dynamic> local, cloud;
  const id = 'review-document';
  Future<Map<String, dynamic>> read() async => {
    'schoolId': school,
    'syncProtocol': 2,
    'records': {id: cloud},
  };
  Future<void> resolve(
    String choice, {
    Map<String, dynamic>? expected,
    Map<String, dynamic>? reviewed,
    Future<Map<String, dynamic>> Function()? reader,
    Future<Uint8List> Function(Map<String, dynamic>)? fetch,
  }) => WindowsBackendBridge.resolveReviewedDocument(
    id: id,
    expected: expected ?? local,
    reviewedCloud: reviewed ?? cloud,
    choice: choice,
    reason: 'Reviewed retained originals',
    reviewedLocalHash: sha256.convert([1, 2, 3]).toString(),
    readCloud: reader ?? read,
    fetchBytes: fetch ?? (_) async => Uint8List.fromList([4, 5, 6]),
  );
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
        'storageReady': false,
      }),
    });
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile(
      'owner-review-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolId': school, 'schoolSyncId': school},
    );
    dir = await Directory.systemTemp.createTemp('review-original-');
    final file = File('${dir.path}/local.pdf');
    await file.writeAsBytes([1, 2, 3]);
    local = {
      'documentId': id,
      'schoolId': school,
      'studentId': 'S1',
      'localPath': file.path,
      'optimizedPath': file.path,
      'documentRevision': 'local-op-original',
      'documentKind': 'idCard',
      'ownerRole': 'student',
      'personId': 'S1',
      'inputRevision': 'local-input',
      'syncState': 'conflict',
      'deleted': false,
      'mimeType': 'application/pdf',
      'fileName': 'ID.pdf',
      'baseCloudRevision': '',
    };
    cloud = {
      'id': id,
      'schoolId': school,
      'studentId': 'S1',
      'documentRevision': 'cloud-op-original',
      '_syncRevision': 'cloud-record-original',
      'documentKind': 'idCard',
      'ownerRole': 'student',
      'personId': 'S1',
      'inputRevision': 'cloud-input',
      'contentHash': sha256.convert([4, 5, 6]).toString(),
      'fileId': 'cloud-immutable',
      'fileUrl': 'https://drive.google.com/file/d/cloud-immutable/view',
      'mimeType': 'application/pdf',
      'fileName': 'ID.pdf',
      'uploadedAt': 42,
    };
    await db.collection('_local_student_documents').doc(id).set(local);
    await db.collection('_windows_document_outbox').doc(id).set(local);
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  test(
    'local review creates a fresh CAS operation without upload or ACK and retains original',
    () async {
      await resolve('local');
      final queued =
          (await db.collection('_windows_document_outbox').doc(id).get())
              .data()!;
      expect(queued['syncState'], 'Pending');
      expect(queued['documentRevision'], isNot(local['documentRevision']));
      expect(queued['baseCloudRevision'], cloud['documentRevision']);
      expect(queued['reviewedRecordRevision'], cloud['_syncRevision']);
      expect(queued['localPath'], local['localPath']);
      expect(await File(local['localPath'] as String).readAsBytes(), [1, 2, 3]);
      expect(
        (await db.collection('_windows_sync_receipts').get()).docs,
        isEmpty,
      );
      expect(
        (await db.collection('_windows_sync_conflict_history').get())
            .docs
            .single
            .data()['documentRevision'],
        local['documentRevision'],
      );
      await expectLater(resolve('local'), throwsStateError);
      expect(
        (await db.collection('_windows_document_outbox').doc(id).get()).data(),
        queued,
      );
      final origin = db.activeProfileId;
      await db.resetVolatileSession();
      await db.switchProfile(
        origin,
        identity: {'schoolId': school, 'schoolSyncId': school},
      );
      expect(
        (await db.collection('_windows_document_outbox').doc(id).get())
            .data()?['documentRevision'],
        queued['documentRevision'],
      );
    },
  );
  test(
    'cloud review verifies bytes and archives exact rejected operation; never ACKs local revision',
    () async {
      await resolve('cloud');
      expect(
        (await db.collection('_windows_document_outbox').doc(id).get()).exists,
        false,
      );
      final selected =
          (await db.collection('_local_student_documents').doc(id).get())
              .data()!;
      expect(selected['documentRevision'], cloud['documentRevision']);
      expect(selected['ownerCloudChoiceInputRevision'], 'local-input');
      expect(await File(selected['localPath'] as String).readAsBytes(), [
        4,
        5,
        6,
      ]);
      expect(await File(local['localPath'] as String).readAsBytes(), [1, 2, 3]);
      final receipt = (await db.collection('_windows_sync_receipts').get())
          .docs
          .single
          .data();
      expect(receipt['operationId'], cloud['documentRevision']);
      expect(receipt['rejectedLocalRevision'], local['documentRevision']);
    },
  );
  test(
    'bad cloud bytes retain queue, history and original unchanged',
    () async {
      await expectLater(
        resolve('cloud', fetch: (_) async => Uint8List.fromList([9])),
        throwsStateError,
      );
      expect(
        (await db.collection('_windows_document_outbox').doc(id).get()).data(),
        local,
      );
      expect(
        (await db.collection('_windows_sync_receipts').get()).docs,
        isEmpty,
      );
      expect(
        (await db.collection('_windows_sync_conflict_history').get()).docs,
        isEmpty,
      );
    },
  );
  test('cloud change after download rejects stale decision', () async {
    await expectLater(
      resolve(
        'cloud',
        fetch: (_) async {
          cloud = {...cloud, '_syncRevision': 'changed'};
          return Uint8List.fromList([4, 5, 6]);
        },
      ),
      throwsStateError,
    );
    expect(
      (await db.collection('_windows_document_outbox').doc(id).get()).data(),
      local,
    );
  });
  test('local edit during slow cloud read preserves newest queue', () async {
    final newer = {...local, 'documentRevision': 'newer-local'};
    await expectLater(
      resolve(
        'local',
        reader: () async {
          await db.collection('_windows_document_outbox').doc(id).set(newer);
          return await read();
        },
      ),
      throwsStateError,
    );
    expect(
      (await db.collection('_windows_document_outbox').doc(id).get()).data(),
      newer,
    );
  });
  test('school switch during slow read never resolves old school', () async {
    await expectLater(
      resolve(
        'local',
        reader: () async {
          await db.switchProfile(
            'foreign-review',
            identity: {'schoolId': 'foreign', 'schoolSyncId': 'foreign'},
          );
          return await read();
        },
      ),
      throwsStateError,
    );
    expect((await db.collection('_windows_sync_receipts').get()).docs, isEmpty);
  });
  test(
    'unsafe identity, deletion and unverified cloud replies remain blocked',
    () async {
      for (final row in [
        {...cloud, 'studentId': 'Other'},
        {...cloud, 'schoolId': 'foreign'},
        {...cloud, '_syncDeleted': true},
        {...cloud, '_syncRevision': ''},
      ]) {
        await expectLater(
          resolve(
            'local',
            reviewed: row,
            reader: () async => {
              'schoolId': school,
              'syncProtocol': 2,
              'records': {id: row},
            },
          ),
          throwsStateError,
        );
      }
      await expectLater(
        resolve('local', expected: {...local, 'deleted': true}),
        throwsStateError,
      );
      expect(
        (await db.collection('_windows_document_outbox').doc(id).get()).data(),
        local,
      );
    },
  );
  test(
    'timeout after possible commit replays one stable reviewed operation then verifies readback',
    () async {
      await resolve('local');
      Map<String, dynamic>? committed;
      await expectLater(
        WindowsBackendBridge.flushDocumentPending(
          send: (payload) async {
            committed = {...payload};
            throw TimeoutException('possible remote commit; response lost');
          },
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(
        (await db.collection('_windows_document_outbox').doc(id).get()).exists,
        true,
      );
      expect(
        (await db.collection('_windows_sync_receipts').get()).docs,
        isEmpty,
      );
      await WindowsBackendBridge.flushDocumentPending(
        send: (payload) async {
          expect(payload, committed);
          return {
            'success': true,
            'cloudVerified': true,
            'schoolId': school,
            'fileUrl': cloud['fileUrl'],
            'document': {
              ...payload,
              'id': id,
              '_syncRevision': 'verified-new-record',
              'fileUrl': cloud['fileUrl'],
            },
          };
        },
      );
      expect(
        (await db.collection('_windows_document_outbox').doc(id).get()).exists,
        false,
      );
      expect(await File(local['localPath'] as String).readAsBytes(), [1, 2, 3]);
      expect(
        (await db.collection('_windows_sync_conflict_history').get()).docs,
        isNotEmpty,
      );
    },
  );
  test(
    'local bytes changed since displayed review cannot become a selected upload',
    () async {
      await File(local['localPath'] as String).writeAsBytes([7, 8, 9]);
      await expectLater(resolve('local'), throwsStateError);
      expect(
        (await db.collection('_windows_document_outbox').doc(id).get()).data(),
        local,
      );
      expect(
        (await db.collection('_windows_sync_receipts').get()).docs,
        isEmpty,
      );
    },
  );
  test(
    'restored same-input cloud ID does not regenerate or upload another PDF',
    () async {
      final person = {
        'mobileLinkToken': 'c'.padRight(32, 'c'),
        'mobileStableId': 'S1',
        'name': 'Student',
        'class': '1',
        'rollNo': 1,
      };
      final qr = SchoolLink.encodeCompact({
        'app': 'VIDYA_SAARTHI',
        'v': 2,
        'managed': true,
        'schoolId': school,
        'centralEndpoint':
            'https://saarthi-oauth-staging.onrender.com/school-cloud',
        'firebaseProjectId': platformProjectId,
        'type': 'student',
        'personId': 'S1',
        'linkToken': person['mobileLinkToken'],
      });
      final cardId = WindowsBackendBridge.publishedIdCardId(qr);
      final row = {...cloud, 'id': cardId, 'inputRevision': 'same-input'};
      await WindowsBackendBridge.publishIdCard(
        bytes: Uint8List(0),
        qr: qr,
        kind: 'studentId',
        person: person,
        inputRevision: 'same-input',
        readPublished: () async => {
          'schoolId': school,
          'syncProtocol': 2,
          'records': {cardId: row},
        },
      );
      expect(
        (await db.collection('_local_student_documents').doc(cardId).get())
            .exists,
        false,
      );
      expect(
        (await db.collection('_windows_document_outbox').doc(cardId).get())
            .exists,
        false,
      );
      expect(
        (await db.collection('documents').doc(cardId).get())
            .data()?['documentRevision'],
        row['documentRevision'],
      );
    },
  );
}

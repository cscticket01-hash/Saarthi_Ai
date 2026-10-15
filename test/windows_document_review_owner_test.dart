import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:qr/qr.dart' as qr_pixels;
import 'package:printing/printing.dart';
import 'package:printing/src/interface.dart';
import 'package:printing/src/method_channel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import '../lib/windows_sync_conflict_review.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../lib/windows_document_templates.dart';
import '../lib/windows_backend_bridge.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/platform/platform_config.dart';
import '../lib/school_qr_link.dart';
import '../lib/id_card_engine.dart';
import '../lib/id_card_manifest.dart';

// Simulated OS raster boundary for owner-state tests. Production QR decoding
// still runs; actual composed PDF pixels are separately checked by the existing
// 13-sample final-raster acceptance suite. This is not native printer proof.
class OwnerReviewRaster extends PdfRaster {
  OwnerReviewRaster(img.Image image)
    : png = Uint8List.fromList(img.encodePng(image)),
      super(
        image.width,
        image.height,
        image.getBytes(order: img.ChannelOrder.rgba),
      );
  final Uint8List png;
  @override
  Future<Uint8List> toPng() async => png;
}

class OwnerReviewPrinting extends MethodChannelPrinting {
  OwnerReviewPrinting(this.qr);
  final String qr;
  @override
  Stream<PdfRaster> raster(
    Uint8List document,
    List<int>? pages,
    double dpi,
  ) async* {
    final code = qr_pixels.QrImage(
      qr_pixels.QrCode.fromData(
        data: qr,
        errorCorrectLevel: qr_pixels.QrErrorCorrectLevel.M,
      ),
    );
    const scale = 6, quiet = 4;
    final image = img.Image(
      width: (code.moduleCount + quiet * 2) * scale,
      height: (code.moduleCount + quiet * 2) * scale,
      numChannels: 4,
    );
    img.fill(image, color: img.ColorRgba8(255, 255, 255, 255));
    for (var y = 0; y < code.moduleCount; y++)
      for (var x = 0; x < code.moduleCount; x++)
        if (code.isDark(y, x))
          img.fillRect(
            image,
            x1: (x + quiet) * scale,
            y1: (y + quiet) * scale,
            x2: (x + quiet + 1) * scale - 1,
            y2: (y + quiet + 1) * scale - 1,
            color: img.ColorRgba8(0, 0, 0, 255),
          );
    yield OwnerReviewRaster(image);
  }
}

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
  for(final source in ['local-deletion','pending-deletion','cloud-tombstone','deletion-during-read']) {
    test('automatic ID decision retains $source without a replacement upload', () async {
      final person={'mobileLinkToken':'x'*48,'mobileStableId':'S1','name':'Synthetic Student','class':'1','rollNo':1};
      final qr=SchoolLink.encodeCompact({'app':'VIDYA_SAARTHI','v':2,'managed':true,
        'schoolId':school,'centralEndpoint':'https://saarthi-oauth-staging.onrender.com/school-cloud',
        'type':'student','personId':'S1','linkToken':person['mobileLinkToken']});
      final cardId=WindowsBackendBridge.publishedIdCardId(qr);
      final deletion={...local,'documentId':cardId,'deleted':true,'syncState':'Synced'};
      if(source=='local-deletion')await db.collection('_local_student_documents').doc(cardId).set(deletion);
      if(source=='pending-deletion')await db.collection('_windows_document_outbox').doc(cardId).set({...deletion,'syncState':'Pending'});
      final originalQueue=(await db.collection('_windows_document_outbox').get()).docs.map((r)=>r.id).toList();
      var reads=0;
      await WindowsBackendBridge.publishIdCard(bytes:Uint8List.fromList([1]),qr:qr,kind:'studentId',
        person:person,inputRevision:'new-input',automatic:true,readPublished:()async{
          reads++;
          if(source=='deletion-during-read')await db.collection('_local_student_documents').doc(cardId).set(deletion);
          return {'schoolId':school,'syncProtocol':2,'records':{
            if(source=='cloud-tombstone')cardId:{'schoolId':school,'_syncDeleted':true,'_syncRevision':'verified-delete'},
          }};
        });
      expect(reads,source=='local-deletion'||source=='pending-deletion'?0:1);
      expect((await db.collection('_windows_document_outbox').get()).docs.map((r)=>r.id).toList(),originalQueue);
      final retained=(await db.collection('_local_student_documents').doc(cardId).get()).data();
      if(source=='local-deletion'||source=='deletion-during-read')expect(retained,deletion);
      else expect(retained,isNull);
      expect(await File(local['localPath'] as String).exists(),true);
      expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty);
    });
  }
  test('local ID renderer stays usable with retained publication conflict and offline cloud', () async {
    final person = {'mobileLinkToken':'x' * 48, 'mobileStableId':'S1',
      'name':'Synthetic Student', 'class':'1', 'rollNo':1};
    final qr = SchoolLink.encodeCompact({'app':'VIDYA_SAARTHI','v':2,'managed':true,
      'schoolId':school,'centralEndpoint':'https://saarthi-oauth-staging.onrender.com/school-cloud',
      'type':'student','personId':'S1','linkToken':person['mobileLinkToken']});
    final cardId = WindowsBackendBridge.publishedIdCardId(qr);
    await db.collection('students_directory').doc('S1').set(person);
    await db.collection('school_config').doc('school_profile_cache').set({'schoolName':'Synthetic School','principalName':'Synthetic Principal','schoolContactNo':'0000000000'});
    final queue = db.collection('_windows_document_outbox').doc(cardId);
    await queue.set({...local,'documentId':cardId});
    final before = (await queue.get()).data();
    await db.collection('school_settings').doc('document_templates').set({'studentId':'manifest:school-id-v1'});
    final printing = PrintingPlatform.instance;
    PrintingPlatform.instance = OwnerReviewPrinting(qr);
    try {
      final bytes = await WindowsDocumentTemplates.selected('studentId',
        {...person,'schoolId':school,'schoolName':'Synthetic School'},qr:qr);
      expect(bytes, isNotNull);
      expect(String.fromCharCodes(bytes!.take(4)), '%PDF');
      expect((await queue.get()).data(),before);
    } finally { PrintingPlatform.instance = printing; }
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
      expect(selected['localPath'],endsWith('.pdf'));
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
  testWidgets(
    'differing PDF verification exposes owner choices and preview controls',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showWindowsConflictReview(context, {
                  'id': id,
                  ...local,
                  '_queueCollection': '_windows_document_outbox',
                }, cloudReader: (_) => read()),
                child: const Text('Review'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Verify cloud version'));
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(find.text('Use local version'), findsOneWidget);
      expect(find.text('Use cloud version'), findsOneWidget);
      expect(find.text('Preview local PDF'), findsOneWidget);
      expect(find.text('Preview cloud PDF'), findsOneWidget);
      await tester.runAsync(()async{
      expect(
        (await db.collection('_windows_document_outbox').doc(id).get()).data(),
        local,
      );
      expect(
        (await db.collection('_windows_sync_receipts').get()).docs,
        isEmpty,
      );
      });
      await tester.tap(find.text('Close'));await tester.pumpAndSettle();
    },
  );
  test(
    'different restored ID inputs retain both versions for review without uploading',
    () async {
      final person = {
        'mobileLinkToken': 'x' * 48,
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
        'type': 'student',
        'personId': 'S1',
        'linkToken': person['mobileLinkToken'],
      });
      final cardId = WindowsBackendBridge.publishedIdCardId(qr);
      final template = IdCardManifest.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(
            File('assets/school_id_manifest_v1.json').readAsStringSync(),
          ),
        ),
      );
      final bytes = await IdCardEngine.render(template, {
        ...person,
        'schoolName': 'Synthetic School',
      }, qr: qr);
      final printing = PrintingPlatform.instance;
      PrintingPlatform.instance = OwnerReviewPrinting(qr);
      try {
        await WindowsBackendBridge.publishIdCard(
          bytes: bytes,
          qr: qr,
          kind: 'studentId',
          person: person,
          inputRevision: 'new-input',
          readPublished: () async => {
            'schoolId': school,
            'syncProtocol': 2,
            'records': {
              cardId: {...cloud, 'id': cardId},
            },
          },
        );
      } finally {
        PrintingPlatform.instance = printing;
      }
      final retained =
          (await db.collection('_windows_document_outbox').doc(cardId).get())
              .data()!;
      expect(retained['syncState'], 'conflict');
      expect(retained['diagnosticId'], 'ID_CLOUD_GENERATION_REVIEW_REQUIRED');
      expect(
        retained['observedCloud']['documentRevision'],
        cloud['documentRevision'],
      );
      expect(await File(retained['localPath'] as String).readAsBytes(), bytes);
      expect(
        (await db.collection('_windows_sync_receipts').get()).docs,
        isEmpty,
      );
      await WindowsBackendBridge.flushDocumentPending(
        send: (_) async => fail('Conflicted generation cannot upload'),
      );
    },
  );
  test(
    'retryable cloud inventory outage permits offline ID save but authorization denial does not',
    () async {
      final person = {
        'mobileLinkToken': 'x' * 48,
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
        'type': 'student',
        'personId': 'S1',
        'linkToken': person['mobileLinkToken'],
      });
      final cardId = WindowsBackendBridge.publishedIdCardId(qr);
      await expectLater(
        WindowsBackendBridge.publishIdCard(
          bytes: Uint8List(0),
          qr: qr,
          kind: 'studentId',
          person: person,
          inputRevision: 'new-input',
          readPublished: () async =>
              throw CentralCloudException(403, 'school_cloud', 'denied'),
        ),
        throwsA(isA<CentralCloudException>()),
      );
      expect(
        (await db.collection('_windows_document_outbox').doc(cardId).get())
            .exists,
        false,
      );
      final template = IdCardManifest.fromJson(
        Map<String, dynamic>.from(
          jsonDecode(
            File('assets/school_id_manifest_v1.json').readAsStringSync(),
          ),
        ),
      );
      final bytes = await IdCardEngine.render(template, {
        ...person,
        'schoolName': 'Synthetic School',
      }, qr: qr);
      final printing = PrintingPlatform.instance;
      PrintingPlatform.instance = OwnerReviewPrinting(qr);
      try {
        await WindowsBackendBridge.publishIdCard(
          bytes: bytes,
          qr: qr,
          kind: 'studentId',
          person: person,
          inputRevision: 'new-input',
          readPublished: () async =>
              throw CentralCloudException(503, 'school_cloud', 'offline'),
        );
      } finally {
        PrintingPlatform.instance = printing;
      }
      final queued =
          (await db.collection('_windows_document_outbox').doc(cardId).get())
              .data()!;
      expect(queued['syncState'], 'Pending');
      expect(queued['baseCloudRevision'], '');
      expect(await File(queued['localPath'] as String).readAsBytes(), bytes);
      expect(
        (await db.collection('_windows_sync_receipts').get()).docs,
        isEmpty,
      );
    },
  );
  test(
    'protected pending ID is rejected before cloud lookup or regeneration',
    () async {
      final person = {'mobileLinkToken': 'x' * 48, 'mobileStableId': 'S1'};
      final qr = SchoolLink.encodeCompact({
        'app': 'VIDYA_SAARTHI',
        'v': 2,
        'managed': true,
        'schoolId': school,
        'centralEndpoint':
            'https://saarthi-oauth-staging.onrender.com/school-cloud',
        'type': 'student',
        'personId': 'S1',
        'linkToken': person['mobileLinkToken'],
      });
      final cardId = WindowsBackendBridge.publishedIdCardId(qr);
      await db.collection('_windows_document_outbox').doc(cardId).set(local);
      await expectLater(
        WindowsBackendBridge.publishIdCard(
          bytes: Uint8List(0),
          qr: qr,
          kind: 'studentId',
          person: person,
          inputRevision: 'new-input',
          readPublished: () async =>
              fail('Protected queue must not trigger a cloud lookup'),
        ),
        throwsStateError,
      );
      expect(
        (await db.collection('_windows_document_outbox').doc(cardId).get())
            .data(),
        local,
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

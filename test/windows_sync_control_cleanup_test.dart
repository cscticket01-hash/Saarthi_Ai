import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/cloudflare_record_handoff.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_sync_control_center.dart';
import '../lib/windows_sync_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = FirebaseFirestore.instance;
  final engine = WindowsSyncEngine.instance;
  late Map<String, dynamic> previous;
  setUp(() async {
    previous = engine.details.value;
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile('cleanup-${DateTime.now().microsecondsSinceEpoch}',
        identity: {'schoolSyncId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'});
    engine.details.value = {
      'pending': 3, 'needsAttention': 2,
      'items': [
        {'id': 'conflict', 'collection': 'students_directory', 'syncState': 'conflict'},
        {'id': 'failed', 'collection': 'students_directory', 'syncState': 'failed'},
        {'id': 'waiting', 'collection': 'students_directory', 'syncState': 'pending'},
      ],
    };
  });
  tearDown(() => engine.details.value = previous);

  test('diagnostic report separates exact handoffs and excludes foreign rows', () async {
    const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const foreign = 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    final queue = db.collection('_windows_firebase_outbox');
    Map<String, dynamic> row(String op, String owner) => {
      'schoolId': owner, 'collection': 'school_notices',
      'documentId': op, 'operationId': op, 'operation': 'set',
      'baseCloudRevision': '', 'syncState': 'cloudAccepted',
      'cloudTicketId': exactStagedRecordTicket({
        'schoolId':owner,'collection':'school_notices',
        'documentId':op,'operationId':op,
      },owner), 'cloudTicketLane': 'records',
      'data': {'privateText': 'not for diagnostic export'},
    };
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() async {
      await queue.doc('accepted').set(row('accepted-operation-0001', school));
      await queue.doc('unverified').set({
        ...row('unverified-operation-0001', school),
        'cloudTicketId': List.filled(64, 'b').join(),
      });
      await queue.doc('foreign').set(row('foreign-operation-0001', foreign));
      await queue.doc('pending').set({
        ...row('pending-operation-0001', school), 'syncState': 'pending',
      });
      await db.collection('_windows_sync_receipts').doc('foreign-receipt').set({
        'schoolId': foreign, 'operationId': 'foreign-operation-0001',
      });
    });
    final report = await engine.safeQueueDiagnostics();
    expect(report['foregroundQueueCount'], 2);
    expect(report['cloudflareOwnedPendingDriveCount'], 1);
    expect(report['unscopedQueueCount'], 1);
    expect(report['retainedVerifiedReceiptCount'], 0);
    final states = (report['items'] as List).map((r) => r['state']);
    expect(states, unorderedEquals(['cloudAccepted', 'unverifiedHandoff', 'pending']));
    expect(report.toString(), isNot(contains('foreign-operation-0001')));
    expect(report.toString(), isNot(contains('not for diagnostic export')));
    expect((await queue.get()).docs.length, 4,
        reason: 'Diagnosis never deletes or acknowledges original queue work');
  });

  test('document Cloudflare-owned Idle classification requires exact original sidecar ticket', () async {
    const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const revision='document-original-operation-0001';
    final digest=List.filled(64,'a').join();
    String ticket(String id) {
      final key=sha256.convert(utf8.encode('$id:$revision')).toString();
      return sha256.convert(utf8.encode(jsonEncode([school,key]))).toString();
    }
    Map<String,dynamic> row(String id,String key)=> {
      'schoolId':school,'documentRevision':revision,
      'contentHash':digest,'cloudContentHash':digest,
      'syncState':'cloudAccepted','cloudTicketLane':'file-$key',
      'cloudTicketId':key,'deleted':false,
    };
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() async {
      await db.collection('_windows_document_outbox')
          .doc('exact-document').set(row('exact-document',ticket('exact-document')));
      await db.collection('_windows_document_outbox')
          .doc('wrong-ticket').set(row('wrong-ticket',List.filled(64,'b').join()));
    });
    final report=await engine.safeQueueDiagnostics();
    expect(report['cloudflareOwnedPendingDriveCount'],1);
    expect(report['foregroundQueueCount'],1);
    expect(report['unscopedQueueCount'],0);
    expect((await db.collection('_windows_document_outbox').get()).docs.length,2);
  });

  testWidgets('overview keeps real queue activity and combined pending counts; queue opens without adding attention twice', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: WindowsSyncControlCenter(diskProbe: (_) async => {'status': 'Unknown'}, refreshOnOpen: () async {})));
    await tester.pumpAndSettle();
    expect(find.text('LIVE UI'), findsNothing);
    expect(find.text('Detailed status & safe controls'), findsNothing);
    expect(find.text('Needs attention'), findsNothing);
    expect(find.text('Pending Uploads'), findsOneWidget);
    expect(find.text('3 Pending · 2 Need Attention\n1 Conflicts · 1 Failed\n0 file cleanup operations included'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Live Queue Activity'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Live Queue Activity'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Pending Uploads'), -200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Pending Uploads').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Pending Queue & Conflict Review'), findsOneWidget);
    expect(find.text('students_directory • conflict'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manual sync keeps pause admission available before completion', (tester) async {
    final completion = Completer<void>();
    var starts = 0;
    final pauses = <Duration>[];
    await tester.pumpWidget(MaterialApp(home: WindowsSyncControlCenter(diskProbe: (_) async => {'status': 'Unknown'},
      refreshOnOpen: () async {},
      syncRequest: () async { starts++; await completion.future; },
      pauseRequest: (duration) async { pauses.add(duration); },
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Sync Now'));
    await tester.pump();
    expect(starts, 1);
    final pause = find.widgetWithText(FilledButton, 'Pause Sync');
    expect(tester.widget<FilledButton>(pause).onPressed, isNotNull);
    await tester.tap(pause);
    await tester.pumpAndSettle();
    expect(pauses, [const Duration(minutes: 5)]);
    expect(completion.isCompleted, false);
    expect(engine.details.value['pending'], 3);
    completion.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'four inline destinations retain advanced tools without a nested drawer',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: WindowsSyncControlCenter(
            diskProbe: (_) async => {'status': 'Unknown'},
            refreshOnOpen: () async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing);
      expect(find.byTooltip('Back'), findsOneWidget);
      for (final label in [
        'Overview',
        'Smart Repair History',
        'Recycle Bin',
        'Backup School Data',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Export Sanitized Report'), findsNothing);
      expect(find.text('Diagnostics and recovery tools'),findsNothing);
      await tester.tap(find.byType(PopupMenuButton<int>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Troubleshoot'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Export Sanitized Report'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Export Sanitized Report'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('activity shows only own-school measured stages and offers repair only for recoverable retained operations', (tester) async {
    engine.details.value = {
      'pending': 1, 'needsAttention': 1, 'items': const [],
      'activity': [
        {'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'stage': 'retry',
         'operationId': 'original-op', 'queueId': 'original-row',
         'queueCollection': '_windows_firebase_outbox', 'isRetryable': true,
         'at': DateTime.now().millisecondsSinceEpoch},
        {'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'stage': 'conflict',
         'operationId': 'conflict-op', 'queueId': 'conflict-row',
         'queueCollection': '_windows_firebase_outbox', 'isRetryable': true,
         'at': DateTime.now().millisecondsSinceEpoch},
        {'schoolId': 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'stage': 'unauthorized',
         'operationId': 'foreign-op', 'isRetryable': true, 'at': DateTime.now().millisecondsSinceEpoch},
      ],
    };
    await tester.pumpWidget(MaterialApp(home: WindowsSyncControlCenter(diskProbe: (_) async => {'status': 'Unknown'}, refreshOnOpen: () async {})));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Smart Repair History'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Smart Repair — Safe Retry'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Smart Repair — Safe Retry'), findsOneWidget);
    expect(find.text('Conflict — administrator review'), findsOneWidget);
    expect(find.text('Unauthorized — authentication required'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

}

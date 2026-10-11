import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_local_firestore.dart';
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

  testWidgets('overview keeps real queue activity and combined pending counts; queue opens without adding attention twice', (tester) async {
    await tester.pumpWidget(MaterialApp(home: WindowsSyncControlCenter(refreshOnOpen: () async {})));
    await tester.pumpAndSettle();
    expect(find.text('LIVE UI'), findsNothing);
    expect(find.text('Detailed status & safe controls'), findsNothing);
    expect(find.text('Needs attention'), findsNothing);
    expect(find.text('Pending Uploads'), findsOneWidget);
    expect(find.text('3 Pending · 2 Need Attention\n1 Conflicts · 1 Failed'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Live Queue Activity'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Live Queue Activity'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Pending Uploads'), -200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Pending Uploads'));
    await tester.pumpAndSettle();
    expect(find.text('Pending Queue & Conflict Review'), findsOneWidget);
    expect(find.text('students_directory • conflict'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('manual sync keeps pause admission available before completion', (tester) async {
    final completion = Completer<void>();
    var starts = 0;
    final pauses = <Duration>[];
    await tester.pumpWidget(MaterialApp(home: WindowsSyncControlCenter(
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
    expect(pauses, [const Duration(hours: 24)]);
    expect(completion.isCompleted, false);
    expect(engine.details.value['pending'], 3);
    completion.complete();
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('narrow window drawer retains recovery and diagnostic controls outside Overview', (tester) async {
    await tester.pumpWidget(MaterialApp(home: WindowsSyncControlCenter(refreshOnOpen: () async {})));
    await tester.pumpAndSettle();
    expect(find.text('Export Sanitized Report'), findsNothing);
    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.text('Sync tools'), findsOneWidget);
    expect(find.text('Version Conflicts'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Export Sanitized Report'), 250,
        scrollable: find.descendant(of: find.byType(Drawer), matching: find.byType(Scrollable)).first);
    expect(find.text('Export Sanitized Report'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('activity shows only own-school measured stages and offers repair only for recoverable retained operations', (tester) async {
    engine.details.value = {
      'pending': 1, 'needsAttention': 1, 'items': const [],
      'activity': [
        {'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'stage': 'retry',
         'operationId': 'original-op', 'queueId': 'original-row',
         'queueCollection': '_windows_firebase_outbox', 'isRetryable': true,
         'at': 123456},
        {'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'stage': 'conflict',
         'operationId': 'conflict-op', 'queueId': 'conflict-row',
         'queueCollection': '_windows_firebase_outbox', 'isRetryable': true,
         'at': 123456},
        {'schoolId': 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'stage': 'unauthorized',
         'operationId': 'foreign-op', 'isRetryable': true, 'at': 123456},
      ],
    };
    await tester.pumpWidget(MaterialApp(home: WindowsSyncControlCenter(refreshOnOpen: () async {})));
    await tester.pump(); await tester.pump(const Duration(milliseconds: 100));
    await tester.scrollUntilVisible(find.text('Smart Repair — Safe Retry'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('Smart Repair — Safe Retry'), findsOneWidget);
    expect(find.text('Conflict — administrator review'), findsOneWidget);
    expect(find.text('Unauthorized — authentication required'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

}

import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_sync_flow.dart';
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
    await db.switchProfile(
      'modern-ui-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolSyncId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'},
    );
    engine.details.value = {
      'pending': 1,
      'needsAttention': 1,
      'displayState': 'needsAttention',
      'items': [
        {
          'id': 'retained',
          'collection': 'students_directory',
          'syncState': 'needsAttention',
        },
      ],
      'liveQueue': [
        {
          'id': 'retained',
          'collection': 'students_directory',
          'syncState': 'needsAttention',
        },
      ],
      'activity': [
        {
          'schoolId': 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          'stage': 'verified',
          'at': DateTime.now().millisecondsSinceEpoch,
        },
        {
          'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'stage': 'verified',
          'at': DateTime.now().millisecondsSinceEpoch,
        },
      ],
    };
  });
  tearDown(() => engine.details.value = previous);
  WindowsSyncControlCenter page({Future<void> Function()? backup, Future<void> Function()? sync}) =>
      WindowsSyncControlCenter(
        refreshOnOpen: () async {},
        diskProbe: (_) async => {'status': 'Unknown'},
        backupRequest: backup,
        syncRequest: sync,
      );

  for (final width in [480.0, 1440.0]) {
    testWidgets('single navigation and honest state at width $width', (
      tester,
    ) async {
      // A narrow dashboard can require more height without global scaling.
      tester.view.physicalSize = Size(width, width < 960 ? 1900 : 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: page()));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);
      expect(find.text('Backup School Data'), findsNothing);
      expect(find.descendant(of: find.byType(WindowsSyncFlow),
        matching: find.text('Needs Attention')), findsOneWidget);
      expect(find.text('Idle'), findsNothing);
      expect(find.text('Live Queue Activity'), findsOneWidget);
      // Approved dashboard: three top summary cards, three vertical flow stages.
      for (final label in ['Current Upload', 'Last Synced', 'System Health']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text("Today's Sync"), findsNothing);
      for (final label in ['Local Save', 'School Server ACK', 'Google Drive']) {
        expect(find.descendant(of: find.byType(WindowsSyncFlow),
          matching: find.text(label)), findsOneWidget);
      }
      expect(find.text('Server ACK'), findsNothing);
      final viewport = find.byType(Scrollable).first;
      expect(tester.state<ScrollableState>(viewport).position.maxScrollExtent, 0);
      expect(find.text('Pending Uploads'), findsNothing);
      expect(find.text('View full queue').hitTestable(), findsOneWidget);
      expect(find.text('Verified sync'), findsOneWidget);
      expect(find.text('School records'),findsNothing);
      expect(find.text('Documents & ID cards'),findsNothing);
      expect(find.text('Photos & file downloads'),findsNothing);
      expect(find.text('Inventory not yet verified'),findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('View full sync history').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('Verified sync'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('overview clips at short window height without scaling and reveals content again', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 1100);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: page()));
    await tester.pumpAndSettle();
    final viewport = find.byKey(const ValueKey('sync-overview-viewport'));
    final header = find.text('Live Sync');
    final before = tester.getSize(header);
    expect(find.text('View full queue').hitTestable(), findsOneWidget);
    tester.view.physicalSize = const Size(720, 420);
    await tester.pumpAndSettle();
    expect(viewport, findsOneWidget);
    expect(tester.getSize(header).height, before.height);
    final box = tester.renderObject<RenderBox>(header);
    expect(box.getTransformTo(null).getMaxScaleOnAxis(), closeTo(1, .001));
    expect(find.text('View full queue').hitTestable(), findsNothing);
    expect(tester.state<ScrollableState>(find.byType(Scrollable).first)
        .position.maxScrollExtent, 0);
    expect(tester.takeException(), isNull);
    tester.view.physicalSize = const Size(1440, 1100);
    await tester.pumpAndSettle();
    expect(find.text('View full queue').hitTestable(), findsOneWidget);
    expect(tester.getSize(header).height, before.height);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('only latest verified sync shows for five seconds, never replays, and remains in history', (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: page()));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('recent-verified-sync')), findsOneWidget);
    expect(find.text('Verified sync'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(find.byKey(const ValueKey('recent-verified-sync')), findsNothing);
    expect(find.text('Verified sync'), findsNothing);

    // A refresh must not replay the previous successful event.
    engine.details.value = {...engine.details.value};
    await tester.pump();
    expect(find.text('Verified sync'), findsNothing);

    // A genuinely new, same-school verified result replaces the hidden one.
    engine.details.value = {
      ...engine.details.value,
      'activity': [
        ...(engine.details.value['activity'] as List? ?? const []),
        {
          'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'stage': 'verified',
          'collection': 'teachers_directory',
          'documentId': 'teacher-two',
          'at': DateTime.now().millisecondsSinceEpoch,
        },
      ],
    };
    await tester.pump();
    expect(find.byKey(const ValueKey('recent-verified-sync')), findsOneWidget);
    expect(find.text('Verified sync'), findsOneWidget);
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('Verified sync'), findsNothing);

    // Hiding the transient notice must not delete durable history.
    await tester.tap(find.text('View full sync history').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Verified sync'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Cloudflare ACK shows the last device success; late Drive status stays quiet', (tester) async {
    final acceptedAt=DateTime.now().millisecondsSinceEpoch;
    engine.details.value={
      'pending':0,
      'needsAttention':0,
      'displayState':'idle',
      'cloudflareOwnedPendingDrive':1,
      'lastCloudAckMillis':acceptedAt,
      'liveQueue':<Map<String,dynamic>>[],
      'activity':[{
        'schoolId':'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'stage':'cloudflareAccepted',
        'operationId':'server-ack-test-1',
        'collection':'students_directory',
        'documentId':'student-cloud-1',
        'at':acceptedAt,
      }],
    };
    await tester.pumpWidget(MaterialApp(home:page()));
    await tester.pumpAndSettle();
    expect(find.descendant(of:find.byType(WindowsSyncFlow),
      matching:find.text('Idle')),findsOneWidget);
    expect(find.text('School Server ACK verified — device upload complete'),
      findsOneWidget);
    expect(find.byKey(const ValueKey('recent-verified-sync')),findsOneWidget);
    expect(find.textContaining('Google Drive pending'),findsWidgets);
    await tester.pump(const Duration(seconds:6));
    expect(find.byKey(const ValueKey('recent-verified-sync')),findsNothing);
    engine.details.value={
      ...engine.details.value,
      'activity':[
        ...(engine.details.value['activity'] as List),
        {
          'schoolId':'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'stage':'verified','operationId':'server-ack-test-1',
          'at':DateTime.now().millisecondsSinceEpoch,
        }
      ],
    };
    await tester.pump();
    expect(find.byKey(const ValueKey('recent-verified-sync')),findsNothing,
      reason:'late Drive provider status must not reannounce a PC upload');
    expect(find.descendant(of:find.byType(WindowsSyncFlow),
      matching:find.text('Idle')),findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('old verified events are never shown again on opening the overview', (tester) async {
    engine.details.value = {
      ...engine.details.value,
      'activity': [{
        'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'stage': 'verified',
        'at': DateTime.now().subtract(const Duration(minutes: 1)).millisecondsSinceEpoch,
      }],
    };
    await tester.pumpWidget(MaterialApp(home: page()));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('recent-verified-sync')), findsNothing);
    expect(find.text('Verified sync'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('legacy Drive waiting never reopens completed PC upload status', (tester) async {
    engine.details.value={
      'pending':0,'needsAttention':0,'displayState':'waiting',
      'cloudflareOwnedPendingDrive':1,
      'liveQueue':<Map<String,dynamic>>[
        {'schoolId':'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
         '_queueCollection':'_windows_google_outbox',
         'collection':'school_notices','documentId':'old-provider-proof',
         'syncState':'pending'},
      ],
      'items':<Map<String,dynamic>>[],
      'activity':<Map<String,dynamic>>[],
    };
    await tester.pumpWidget(MaterialApp(home:page()));
    await tester.pumpAndSettle();
    expect(find.descendant(of:find.byType(WindowsSyncFlow),
      matching:find.text('Idle')),findsOneWidget);
    expect(find.descendant(of:find.byType(WindowsSyncFlow),
      matching:find.text('Waiting')),findsNothing);
    expect(tester.widget<CircularProgressIndicator>(
      find.descendant(of:find.byType(WindowsSyncFlow),
        matching:find.byType(CircularProgressIndicator))).value,0);
    expect(find.textContaining('Google Drive pending'),findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('zero uploads and one cloud hint show separate honest queue states', (tester) async {
    engine.details.value = {
      'pending':0,
      'incomingPending':1,
      'incomingBreakdown':{'recordDownloads':0,'remoteChecks':1,
                           'mediaFiles':0,'total':1},
      'needsAttention':0,
      'displayState':'idle',
      'liveQueue':<Map<String,dynamic>>[],
      'items':<Map<String,dynamic>>[],
    };
    await tester.pumpWidget(MaterialApp(home:page()));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(WindowsSyncFlow),
      matching: find.text('Idle')), findsOneWidget);
    expect(find.text('Preparing changed data'),findsNothing);
    expect(find.text('Syncing'),findsNothing);
    expect(find.text('0 pending'),findsOneWidget);
    expect(find.text('Pause Sync'),findsNothing);
    expect(find.text('No pending upload operations. Incoming cloud work is listed below.'),findsOneWidget);
    expect(find.text('Cloud change signal queued for verified reconciliation (not an upload).'),findsOneWidget);
    expect(find.text('No pending operations in this school.'),findsNothing);
    expect(tester.takeException(),isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('read-only checks remain enabled during an admitted sync while backup stays locked', (tester) async {
    tester.view.physicalSize = const Size(1440,1100); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    final pending = Completer<void>();
    await tester.pumpWidget(MaterialApp(home:page(sync:()=>pending.future)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync Now')); await tester.pump();
    await tester.tap(find.byType(PopupMenuButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Troubleshoot'));
    await tester.pumpAndSettle();
    for(final label in ['Check Cloud Health','Local Storage Details','School Drive Usage']) {
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton,label)).onPressed,isNotNull);
    }
    final backups = tester.widgetList<OutlinedButton>(find.widgetWithText(OutlinedButton,'Backup School Data'));
    expect(backups,isNotEmpty);
    expect(backups.every((button)=>button.onPressed==null),isTrue);
    pending.complete(); await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('sync failure is shown once inside the alerts card in every view', (tester) async {
    tester.view.physicalSize = const Size(1440, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: page(sync: () async {
      throw TimeoutException('provider unavailable');
    })));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync Now'));
    await tester.pumpAndSettle();
    final card = find.byKey(const ValueKey('sync-errors-alerts'));
    expect(card, findsOneWidget);
    expect(find.descendant(of: card, matching: find.byType(SelectableText)), findsOneWidget);
    final alert = tester.widget<SelectableText>(find.descendant(
      of: card, matching: find.byType(SelectableText)));
    expect(find.text(alert.data!), findsOneWidget,
      reason: 'The same alert must not also be rendered below the overview');
    await tester.tap(find.text('View full sync history').hitTestable());
    await tester.pumpAndSettle();
    expect(find.descendant(of: card, matching: find.byType(SelectableText)), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Back returns to previous route', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  Navigator.of(context)
                      .push(MaterialPageRoute<void>(builder: (_) => page())),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Sync Engine 3.0'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('secure backup callback is the only primary export action', (
    tester,
  ) async {
    var exports = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: page(
          backup: () async {
            exports++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Troubleshoot'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Backup School Data').hitTestable().first);
    await tester.pumpAndSettle();
    expect(exports, 1);
    expect(find.text('Backup Now'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('three sync options; auto interval stays in Troubleshoot', (tester) async {
    await tester.pumpWidget(MaterialApp(home: page()));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Sync options'));
    await tester.pumpAndSettle();
    expect(find.text('Sync Pause'), findsOneWidget);
    expect(find.byType(Switch), findsOneWidget);
    expect(find.text('Troubleshoot'), findsOneWidget);
    expect(find.text('Recycle Bin'), findsOneWidget);
    expect(find.text('Auto Sync (Interval)'), findsNothing,
      reason:'approved top-level menu has only three entries');
    await tester.tap(find.text('Troubleshoot'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Auto Sync (Interval)'));
    await tester.pumpAndSettle();
    for (final label in ['Off', 'Every 5 Minutes', 'Every 30 Minutes', 'Every 1 Hour']) {
      expect(find.text(label), findsOneWidget);
    }
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('three-dot Sync Pause row admits an explicit local pause', (tester) async {
    final pauses = <Duration>[];
    await tester.pumpWidget(MaterialApp(
      home: WindowsSyncControlCenter(
        refreshOnOpen: () async {},
        diskProbe: (_) async => {'status': 'Unknown'},
        pauseRequest: (duration) async { pauses.add(duration); },
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Sync options'));
    await tester.pumpAndSettle();
    final pauseRow = find.text('Sync Pause');
    expect(pauseRow, findsOneWidget);
    expect(
      tester.widget<PopupMenuItem<int>>(
        find.ancestor(of: pauseRow, matching: find.byType(PopupMenuItem<int>)).first,
      ).enabled,
      isTrue,
      reason: 'The whole pause menu row must be selectable, not just the switch',
    );
    await tester.tap(pauseRow);
    await tester.pumpAndSettle();
    expect(pauses, [const Duration(minutes: 5)]);
    expect(find.text('Sync Pause'), findsNothing,
      reason: 'Selecting Pause closes the three-dot popup');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('real widget preview artifact', (tester) async {
    tester.view.physicalSize = const Size(1536, 736);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final font = FontLoader('Segoe UI');
      font.addFont(
        File(Platform.isWindows ? 'C:/Windows/Fonts/segoeui.ttf' : 'assets/id_card_regular.ttf')
            .readAsBytes()
            .then((bytes) => ByteData.sublistView(bytes)),
      );
      await font.load();
      final icons = FontLoader('MaterialIcons');
      icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData(brightness: Brightness.dark,
            fontFamily: 'Segoe UI'),
          home: page(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Diagnostics and recovery tools'), findsNothing);
    expect(find.text('Local Save'), findsOneWidget);
    expect(find.text('Open Folder'), findsNothing);
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 1.25);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await Directory('build/ui-previews').create(recursive: true);
      await File('build/ui-previews/sync-control-modern.png')
          .writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

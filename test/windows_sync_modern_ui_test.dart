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
          'schoolId': 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          'stage': 'verified',
          'at': 12345,
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
      tester.view.physicalSize = Size(width, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(home: page()));
      await tester.pumpAndSettle();
      expect(find.byType(Drawer), findsNothing);
      expect(find.byType(BackButton), findsOneWidget);
      for (final text in [
        'Overview',
        'Smart Repair History',
        'Recycle Bin',
        'Backup School Data',
      ]) {
        expect(find.text(text), findsOneWidget);
      }
      expect(find.text('Needs Attention'), findsOneWidget);
      expect(find.text('Idle'), findsNothing);
      expect(find.text('Verified sync'), findsNothing);
      expect(find.text('School records'),findsNothing);
      expect(find.text('Documents & ID cards'),findsNothing);
      expect(find.text('Photos & file downloads'),findsNothing);
      expect(find.text('Inventory not yet verified'),findsNothing);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Smart Repair History'));
      await tester.pumpAndSettle();
      expect(find.text('Verified sync'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
  testWidgets('read-only checks remain enabled during an admitted sync while backup stays locked', (tester) async {
    tester.view.physicalSize = const Size(1440,1100); tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize); addTearDown(tester.view.resetDevicePixelRatio);
    final pending = Completer<void>();
    await tester.pumpWidget(MaterialApp(home:page(sync:()=>pending.future)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync Now')); await tester.pump();
    await tester.scrollUntilVisible(find.text('Diagnostics and recovery tools'),250,
      scrollable:find.byType(Scrollable).first);
    await Scrollable.ensureVisible(tester.element(find.text('Diagnostics and recovery tools')),alignment:0.5);
    await tester.pump(const Duration(milliseconds:400));
    await tester.tap(find.text('Diagnostics and recovery tools'));
    await tester.pump(const Duration(milliseconds:400));
    for(final label in ['Check Cloud Health','Local Storage Details','School Drive Usage']) {
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton,label)).onPressed,isNotNull);
    }
    final backups = tester.widgetList<OutlinedButton>(find.widgetWithText(OutlinedButton,'Backup School Data'));
    expect(backups,isNotEmpty);
    expect(backups.every((button)=>button.onPressed==null),isTrue);
    pending.complete(); await tester.pumpAndSettle();
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
    await tester.tap(find.text('Backup School Data'));
    await tester.pumpAndSettle();
    expect(exports, 1);
    expect(find.text('Backup Now'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('real widget preview artifact', (tester) async {
    tester.view.physicalSize = const Size(1536, 736);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final font = FontLoader(Platform.isWindows ? 'Segoe UI' : 'Preview');
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
            fontFamily: Platform.isWindows ? 'Segoe UI' : 'Preview'),
          home: page(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Diagnostics and recovery tools')).dy, lessThan(736));
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

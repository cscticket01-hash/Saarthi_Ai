import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:printing/src/interface.dart';
import 'package:printing/src/method_channel.dart';

import '../lib/main_dashboard_screen_windows.dart' show StudentDocumentsScreen;
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/platform/platform_config.dart';

// Only the OS PDF raster boundary is simulated. The production pipeline still
// processes raster pixels, builds both PDFs, previews and persists them.
class ReviewRaster extends PdfRaster {
  ReviewRaster(img.Image image)
      : png = Uint8List.fromList(img.encodePng(image)),
        super(image.width, image.height, image.getBytes(order: img.ChannelOrder.rgba));
  final Uint8List png;
  // Native raster-to-PNG conversion belongs to the simulated platform boundary,
  // not Flutter's fake-async test GPU. The real document engine consumes this PNG.
  @override
  Future<Uint8List> toPng() async => png;
}

class ReviewPrinting extends MethodChannelPrinting {
  int rasterCalls = 0;
  @override
  Stream<PdfRaster> raster(Uint8List document, List<int>? pages, double dpi) async* {
    rasterCalls++;
    final paper = img.Image(width: 120, height: 160, numChannels: 4);
    img.fill(paper, color: img.ColorRgba8(255, 255, 255, 255));
    img.fillRect(paper, x1: 15, y1: 20, x2: 95, y2: 25,
      color: img.ColorRgba8(0, 0, 0, 255));
    yield ReviewRaster(paper);
  }
}


class ReviewPicker extends FileSelectorPlatform {
  XFile? selection;
  int calls = 0;
  @override
  Future<XFile?> openFile(
      {List<XTypeGroup>? acceptedTypeGroups,
      String? initialDirectory,
      String? confirmButtonText}) async {
    calls++;
    expect(
        acceptedTypeGroups!.single.extensions, ['jpg', 'jpeg', 'png', 'pdf']);
    return selection;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final platform = FileSelectorPlatform.instance;
  final db = FirebaseFirestore.instance;
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  late ReviewPicker picker;
  final printing = PrintingPlatform.instance;
  late ReviewPrinting rasterizer;
  setUp(() async {
    picker = ReviewPicker();
    rasterizer = ReviewPrinting();
    PrintingPlatform.instance = rasterizer;
    FileSelectorPlatform.instance = picker;
    FlutterSecureStorage.setMockInitialValues({
      CentralSchoolCloud.key: jsonEncode({
        'managed': true,
        'schoolId': school,
        'uid': 'screen-review',
        'projectId': platformProjectId,
        'endpoint': 'https://unreachable.example/school-cloud',
        'folderId': 'review',
        'firebaseRefreshToken': 'synthetic-test-token',
        'storageReady': false,
      })
    });
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile('screen-${DateTime.now().microsecondsSinceEpoch}',
        identity: {'schoolSyncId': school, 'schoolId': school});
  });
  tearDown(() {
    FileSelectorPlatform.instance = platform;
    PrintingPlatform.instance = printing;
  });
  Future<int> count() async =>
      (await db.collection('_local_student_documents').get()).docs.length;
  Future<void> waitFor(WidgetTester t, bool Function() ready) async {
    for (var i = 0; i < 200 && !ready(); i++) {
      await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 25)));
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(ready(), true, reason: 'Production document flow did not complete');
  }

  // Keep pumping the UI zone while real disk I/O and the queued credential
  // adapter complete. Awaiting disk inside runAsync alone can starve a queued
  // callback owned by the widget's fake-async zone.
  Future<T?> io<T>(WidgetTester t, Future<T> Function() action) async {
    T? value;
    Object? error;
    StackTrace? stack;
    var done = false;
    await t.runAsync(() async {
      unawaited(action().then<void>((result) {
        value = result;
        done = true;
      }, onError: (Object e, StackTrace st) {
        error = e;
        stack = st;
        done = true;
      }));
    });
    await waitFor(t, () => done);
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    return value;
  }

  Future<void> open(WidgetTester t, {int existing = 0, bool cancelled = false}) async {
    final beforeCalls = picker.calls;
    t.view.physicalSize = const Size(1400, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(const MaterialApp(
        home: StudentDocumentsScreen(studentId: 'S-1', studentData: {
      'name': 'Review pupil',
      'class': 'Class 1',
      'rollNo': '1'
    })));
    await waitFor(
        t, () => find.byType(CircularProgressIndicator).evaluate().isEmpty);
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('student-document-upload')));
    await t.pumpAndSettle();
    await t.enterText(
        find.byKey(const ValueKey('document-name')), 'Birth Certificate');
    await t.tap(find.byKey(const ValueKey('document-name-continue')));
    // Uploading intentionally animates the screen's FAB behind the dialog.
    // Wait for the next screen state, not for all animations to stop.
    await t.pump(const Duration(milliseconds: 400));
    await waitFor(
        t,
        () => find
            .byKey(const ValueKey('document-select-file'))
            .evaluate()
            .isNotEmpty || (cancelled && picker.calls > beforeCalls));
    expect(picker.calls, beforeCalls + 1);
    expect(await io(t, count), existing);
  }

  testWidgets(
      'production Documents screen legacy toggle OFF: PNG and PDF offline save, cancellation and failure preserve records/queue',
      (t) async {
    // Keep both real-screen cases in one widget clock. Singleton I/O queues
    // must not inherit a discarded fake-async zone between test callbacks.
    for (final pdf in [false, true]) {
    picker.calls = 0;
    rasterizer.rasterCalls = 0;
    await io(t, () => db.switchProfile('screen-case-${pdf}-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolSyncId': school, 'schoolId': school}));
    final document = pw.Document()..addPage(pw.Page(build: (_) => pw.Text('Real PDF document fixture')));
    final source = pdf ? (await io(t, document.save))! :
        Uint8List.fromList(img.encodePng(img.Image(width: 100, height: 140)));
    if (pdf) debugPrint('PDF regression: real PDF fixture generated');
    final filename = pdf ? 'source.pdf' : 'source.png';
    picker.selection = XFile.fromData(source,
        path: filename, name: filename, mimeType: pdf ? 'application/pdf' : 'image/png');
    await open(t);
    if (pdf) debugPrint('PDF regression: picker returned; awaiting processing');
    await waitFor(
        t,
        () =>
            t
                .widget<ElevatedButton>(
                    find.byKey(const ValueKey('document-confirm-save')))
                .onPressed !=
            null);
    if (pdf) debugPrint('PDF regression: processed preview ready');
    expect(picker.calls, 1);
    expect(await io(t, count), 0);
    expect(find.textContaining('optimized'), findsWidgets);
    await t.tap(find.byKey(const ValueKey('document-confirm-save')));
    await waitFor(
        t,
        () =>
            find
                .byKey(const ValueKey('document-select-file'))
                .evaluate()
                .isEmpty &&
            find.text('Birth Certificate').evaluate().isNotEmpty &&
            t
                    .widget<FloatingActionButton>(
                        find.byKey(const ValueKey('student-document-upload')))
                    .onPressed !=
                null);
    if (pdf) debugPrint('PDF regression: saved and listed locally');
    final rows =
        await io(t, () => db.collection('_local_student_documents').get());
    expect(rows!.docs.length, 1);
    final row = rows.docs.single.data();
    expect(row['syncState'], 'Pending');
    expect(row['schoolId'], school);
    expect(
        await io(t, () => File(row['originalPath'] as String).readAsBytes()),
        source);
    final queue =
        await io(t, () => db.collection('_windows_document_outbox').get());
    expect(queue!.docs.length, 1);
    expect(await io(t, WindowsRuntimeFlags.localStorageEnabled), false);
    expect(await io(t, db.localPersistenceEnabled), true);
    expect(row['optimizedPath'], isNotEmpty);
    expect(row['cleanupStatus'], contains(pdf ? 'pages processed' : ''));
    final optimized = await io(t, () => File(row['optimizedPath'] as String).readAsBytes());
    expect(row['sizeBytes'], optimized!.length);
    expect(await io(t, () => File(row['processedPath'] as String).exists()), true);
    if (pdf) {
      expect(rasterizer.rasterCalls, greaterThanOrEqualTo(2));
      expect(String.fromCharCodes(optimized.take(5)), '%PDF-');
      expect(optimized, isNot(source));
    }

    // Continue the real screen/session, including its existing document. This
    // also verifies cancellation/failure do not erase an earlier successful save.
    picker.selection = null;
    await open(t, existing: 1, cancelled: true);
    await t.pumpAndSettle();
    expect(await io(t, count), 1);
    final afterCancel =
        await io(t, () => db.collection('_windows_document_outbox').get());
    expect(afterCancel!.docs.length, 1);
    expect(find.byKey(const ValueKey('document-select-file')), findsNothing);

    final corrupt = Uint8List.fromList([1, 2, 3]);
    picker.selection = XFile.fromData(corrupt,
        path: 'broken.jpg', name: 'broken.jpg', mimeType: 'image/jpeg');
    await open(t, existing: 1);
    await waitFor(
        t,
        () => find
            .textContaining('Original file is unchanged')
            .evaluate()
            .isNotEmpty);
    expect(corrupt, [1, 2, 3]);
    expect(await io(t, count), 1);
    expect(
        t
            .widget<ElevatedButton>(
                find.byKey(const ValueKey('document-confirm-save')))
            .onPressed,
        isNull);
    await t.tap(find.byKey(const ValueKey('document-cancel')));
    await t.pumpAndSettle();
    final afterFailure =
        await io(t, () => db.collection('_windows_document_outbox').get());
    expect(afterFailure!.docs.length, 1);
    expect(
        await io(t, () => File(row['originalPath'] as String).readAsBytes()),
        source);
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
    }
  });
}

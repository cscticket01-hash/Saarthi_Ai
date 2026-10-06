import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../lib/main_dashboard_screen_windows.dart' show StudentDocumentsScreen;
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/platform/platform_config.dart';

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
  setUp(() async {
    picker = ReviewPicker();
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
    await WindowsRuntimeFlags.setLocalStorageEnabled(true);
    await db.switchProfile('screen-${DateTime.now().microsecondsSinceEpoch}',
        identity: {'schoolSyncId': school, 'schoolId': school});
  });
  tearDown(() {
    FileSelectorPlatform.instance = platform;
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
    expect(await t.runAsync(count), existing);
  }

  testWidgets(
      'production Documents screen: offline preview/save, cancellation and processing failure preserve records and queue',
      (t) async {
    final source =
        Uint8List.fromList(img.encodePng(img.Image(width: 100, height: 140)));
    picker.selection = XFile.fromData(source,
        path: 'source.png', name: 'source.png', mimeType: 'image/png');
    await open(t);
    await waitFor(
        t,
        () =>
            t
                .widget<ElevatedButton>(
                    find.byKey(const ValueKey('document-confirm-save')))
                .onPressed !=
            null);
    expect(picker.calls, 1);
    expect(await t.runAsync(count), 0);
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
    final rows =
        await t.runAsync(() => db.collection('_local_student_documents').get());
    expect(rows!.docs.length, 1);
    final row = rows.docs.single.data();
    expect(row['syncState'], 'Pending');
    expect(row['schoolId'], school);
    expect(
        await t
            .runAsync(() => File(row['originalPath'] as String).readAsBytes()),
        source);
    final queue =
        await t.runAsync(() => db.collection('_windows_document_outbox').get());
    expect(queue!.docs.length, 1);

    // Continue the real screen/session, including its existing document. This
    // also verifies cancellation/failure do not erase an earlier successful save.
    picker.selection = null;
    await open(t, existing: 1, cancelled: true);
    await t.pumpAndSettle();
    expect(await t.runAsync(count), 1);
    final afterCancel =
        await t.runAsync(() => db.collection('_windows_document_outbox').get());
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
    expect(await t.runAsync(count), 1);
    expect(
        t
            .widget<ElevatedButton>(
                find.byKey(const ValueKey('document-confirm-save')))
            .onPressed,
        isNull);
    await t.tap(find.byKey(const ValueKey('document-cancel')));
    await t.pumpAndSettle();
    final afterFailure =
        await t.runAsync(() => db.collection('_windows_document_outbox').get());
    expect(afterFailure!.docs.length, 1);
    expect(
        await t
            .runAsync(() => File(row['originalPath'] as String).readAsBytes()),
        source);
    await t.pumpWidget(const SizedBox());
    await t.pumpAndSettle();
  });
}

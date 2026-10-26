// Review-only native plugin harness. Never connects to a school or cloud.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../lib/main_dashboard_screen_windows.dart' show StudentDocumentsScreen;
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_secure_storage.dart';
import '../lib/platform/platform_config.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('Native document picker review — isolated fixtures only'),
        ),
      ),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) => review());
}

Future<void> review() async {
  final folder = Directory(Platform.environment['SAARTHI_PICKER_REVIEW']!);
  await folder.create(recursive: true);
  void state(Map<String, dynamic> data) {
    final temp = File('${folder.path}/state.tmp');
    temp.writeAsStringSync(jsonEncode(data), flush: true);
    final target = File('${folder.path}/state.json');
    if (target.existsSync()) target.deleteSync();
    temp.renameSync(target.path);
  }

  try {
    // Synthetic school, isolated by the launching script's APPDATA directory.
    // No usable cloud credentials and no remote-ready connection are provided.
    const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final db = FirebaseFirestore.instance;
    await const WindowsSecureStorage().write(
        key: CentralSchoolCloud.key,
        value: jsonEncode({
          'managed': true,
          'schoolId': school,
          'uid': 'native-review',
          'projectId': platformProjectId,
          'endpoint': 'https://unreachable.example/school-cloud',
          'folderId': 'review',
          'firebaseRefreshToken': 'synthetic-unusable-token',
          'email': 'review@example.invalid',
          'storageReady': false,
        }));
    await WindowsRuntimeFlags.setLocalStorageEnabled(true);
    await db.switchProfile('native-document-review',
        identity: {'schoolSyncId': school, 'schoolId': school});
    runApp(const MaterialApp(
        home: StudentDocumentsScreen(
      studentId: 'review-pupil',
      studentData: {'name': 'Review pupil', 'class': 'Class 1', 'rollNo': '1'},
    )));
    Future<int> records() async =>
        (await db.collection('_local_student_documents').get()).docs.length;
    Future<void> startUpload(String name) async {
      await waitFor(() =>
          (widgetWithKey('student-document-upload') as FloatingActionButton?)
              ?.onPressed !=
          null);
      (widgetWithKey('student-document-upload') as FloatingActionButton)
          .onPressed!();
      await waitFor(() => widgetWithKey('document-name') is TextField);
      (widgetWithKey('document-name') as TextField).controller!.text = name;
      (widgetWithKey('document-name-continue') as ElevatedButton).onPressed!();
      await waitFor(() =>
          (widgetWithKey('document-select-file') as OutlinedButton?)
              ?.onPressed !=
          null);
    }

    final image = img.Image(width: 600, height: 800);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    for (var y = 80; y < 720; y += 24)
      img.drawLine(
        image,
        x1: 40,
        y1: y,
        x2: 560,
        y2: y,
        color: img.ColorRgb8(0, 0, 0),
        thickness: 2,
      );
    final jpeg = Uint8List.fromList(img.encodeJpg(image));
    final png = Uint8List.fromList(img.encodePng(image));
    final pdf = pw.Document();
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (_) => pw.Image(pw.MemoryImage(png)),
      ),
    );
    final fixtures = <String, Uint8List>{
      'scan.jpg': jpeg,
      'scan.jpeg': jpeg,
      'scan.png': png,
      'scan.pdf': await pdf.save(),
    };
    final results = <Map<String, dynamic>>[];
    for (final entry in fixtures.entries) {
      final path = '${folder.path}/${entry.key}';
      await File(path).writeAsBytes(entry.value, flush: true);
      final before = await records();
      await startUpload(entry.key);
      if (await records() != before)
        throw StateError('Name step created an empty record');
      state({'stage': 'select', 'file': path});
      (widgetWithKey('document-select-file') as OutlinedButton).onPressed!();
      await waitFor(() =>
          (widgetWithKey('document-confirm-save') as ElevatedButton?)
              ?.onPressed !=
          null);
      await waitFor(() => findWidget((w) => w is Image) != null);
      if (await records() != before)
        throw StateError('Preview saved before explicit Save');
      (widgetWithKey('document-confirm-save') as ElevatedButton).onPressed!();
      await waitForAsync(() async => await records() == before + 1);
      final row = (await db.collection('_local_student_documents').get())
          .docs
          .singleWhere((d) => d.data()['documentName'] == entry.key)
          .data();
      final original = File(row['originalPath'] as String);
      if (!original.path.startsWith(folder.path) ||
          base64Encode(await original.readAsBytes()) !=
              base64Encode(entry.value)) {
        throw StateError(
            'Local saved original mismatch or outside isolated review folder');
      }
      if ((await File(row['processedPath'] as String).length()) == 0 ||
          (await File(row['optimizedPath'] as String).length()) == 0)
        throw StateError('Missing processed/sync copy');
      if (row['syncState'] != 'Pending' ||
          (await db.collection('_windows_document_outbox').get()).docs.length !=
              before + 1)
        throw StateError('Local save did not retain its pending sync queue');
      if (base64Encode(await File(path).readAsBytes()) !=
          base64Encode(entry.value))
        throw StateError('Original fixture changed');
      results.add({
        'file': entry.key,
        'mime': row['mimeType'],
        'optimizedBytes': row['sizeBytes'],
        'originalRetained': true,
        'previewBeforeSave': true,
        'localSaveAndPendingQueue': true,
      });
    }
    final countBeforeCancel = await records();
    await startUpload('Cancelled document');
    state({'stage': 'cancel'});
    (widgetWithKey('document-select-file') as OutlinedButton).onPressed!();
    await waitFor(() => widgetWithKey('document-select-file') == null);
    if (await records() != countBeforeCancel)
      throw StateError('Cancellation created an empty document');
    final corrupt = File('${folder.path}/truncated.jpg');
    await corrupt.writeAsBytes([1, 2, 3], flush: true);
    await startUpload('Truncated document');
    state({'stage': 'select', 'file': corrupt.path});
    (widgetWithKey('document-select-file') as OutlinedButton).onPressed!();
    await waitFor(() =>
        findWidget((w) =>
            w is Text &&
            (w.data?.contains('Original file is unchanged') ?? false)) !=
        null);
    if ((widgetWithKey('document-confirm-save') as ElevatedButton).onPressed !=
            null ||
        await records() != countBeforeCancel ||
        base64Encode(await corrupt.readAsBytes()) != 'AQID')
      throw StateError(
          'Failed processing did not preserve original and block Save');
    (widgetWithKey('document-cancel') as TextButton).onPressed!();
    state({
      'stage': 'done',
      'passed': true,
      'results': results,
      'cancelledWithoutSelection': true,
      'processingFailureRetainedOriginal': true,
    });
    exit(0);
  } catch (e, stack) {
    state({'stage': 'done', 'passed': false, 'error': '$e', 'stack': '$stack'});
    exit(1);
  }
}

// Drive the production widget callbacks, not a parallel implementation of the
// upload flow. The native dialog itself is operated through Windows keyboard UI.
Widget? findWidget(bool Function(Widget) match) {
  Widget? result;
  void visit(Element element) {
    if (match(element.widget)) result = element.widget;
    element.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return result;
}

Widget? widgetWithKey(String key) => findWidget((w) => w.key == ValueKey(key));
Future<void> waitFor(bool Function() condition) =>
    waitForAsync(() async => condition());
Future<void> waitForAsync(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 45));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline))
      throw StateError(
          'Production Documents flow timed out; visible keys: ${visibleKeys()}');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  await Future<void>.delayed(const Duration(milliseconds: 100));
}

String visibleKeys() {
  final keys = <String>[];
  void visit(Element element) {
    final key = element.widget.key;
    if (key is ValueKey<String>) keys.add(key.value);
    element.visitChildElements(visit);
  }
  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  return keys.join(',');
}

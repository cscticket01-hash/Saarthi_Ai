import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/windows_document_templates.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final db = FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(true);
    final dir = await Directory.systemTemp.createTemp('id-preview-');
    await db.changeLocalStorageLocation(dir.path);
    await db.switchProfile(dir.path,
        identity: {'schoolSyncId': school, 'schoolId': school});
  });
  tearDown(() async => db.resetVolatileSession());
  for (final kind in ['studentId', 'teacherId', 'otherStaffId']) {
    test('$kind without a photo has no interactive preview', () async {
      expect(await WindowsDocumentTemplates.selected(kind,
          {'schoolId': school, 'name': 'Synthetic TEST'}, previewOnly: true),
          isNull);
      expect((await db.collection('_windows_document_outbox').get()).docs,
          isEmpty);
    });
  }
  test('preview rejects a foreign school before looking for its photo', () async {
    await expectLater(WindowsDocumentTemplates.selected('studentId',
        {'schoolId': 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'},
        previewOnly: true), throwsStateError);
  });
  test('normal no-photo PDF generation remains available for publication', () async {
    final bytes = await WindowsDocumentTemplates.selected('studentId', {
      'schoolId': school, 'name': 'Synthetic TEST', 'class': '1',
      'rollNo': '1', 'schoolName': 'TEST Sync V2',
    });
    expect(bytes, isNotNull);
    expect(bytes!.take(5).toList(), [37, 80, 68, 70, 45]);
    expect(bytes.length, lessThanOrEqualTo(85 * 1024));
    expect((await db.collection('_windows_document_outbox').get()).docs, isEmpty);
  });
}

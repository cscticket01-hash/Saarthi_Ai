import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import '../lib/id_card_live_preview.dart';
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
  testWidgets('Flutter ID preview loads without generating a PDF or enqueuing a document', (tester) async {
    final widget = await WindowsDocumentTemplates.liveIdCardPreview(
      'studentId',
      {'schoolId': school, 'name': 'Synthetic TEST', 'class': 'Class 1', 'rollNo': '1'},
      qr: 'synthetic-school-qr',
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: SizedBox(width: 500, child: widget),
    )));
    expect(find.byType(IdCardLivePreview), findsOneWidget);
    expect((await db.collection('_windows_document_outbox').get()).docs, isEmpty);
  });

  test('preview rejects a foreign school before looking for its photo', () async {
    await expectLater(WindowsDocumentTemplates.selected('studentId',
        {'schoolId': 'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'},
        previewOnly: true), throwsStateError);
  });
  test('school-selected SVN template generates student PDF from live record fields', () async {
    await db.collection('school_settings').doc('document_templates').set({
      'studentId': 'manifest:student-svn-navy-green-v1',
    });
    final bytes = await WindowsDocumentTemplates.selected('studentId', {
      'schoolId': school,
      'schoolName': 'Sample School',
      'name': 'Sample Student',
      'class': 'Class 1',
      'rollNo': '01',
      'studentUid': 'SAMPLE-01',
      'dob': '01/01/2016',
    });
    expect(bytes, isNotNull);
    expect(bytes!.take(5).toList(), [37, 80, 68, 70, 45]);
    expect(bytes.length, lessThanOrEqualTo(85 * 1024));
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
  for(final field in ['logoUrl','principalSignatureUrl','sealUrl']) {
    test('unavailable configured $field cannot produce an incomplete replacement ID',()async {
      await db.collection('school_config').doc('school_profile_cache').set({
        'schoolId':school,'schoolName':'Synthetic TEST',field:'data:image/png;base64,%%%'});
      await expectLater(WindowsDocumentTemplates.selected('studentId',{
        'schoolId':school,'name':'Synthetic TEST','class':'1','rollNo':'1'}),throwsStateError);
      expect((await db.collection('_windows_document_outbox').get()).docs,isEmpty);
    });
  }
  test('a photo-backed ID keeps its interactive PDF preview', () async {
    final bytes = await WindowsDocumentTemplates.selected('studentId', {
      'schoolId': school, 'name': 'Synthetic TEST', 'class': '1',
      'rollNo': '1', 'schoolName': 'TEST Sync V2',
      'photoBase64': 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGMwaDgAAAJUAXHIMWMAAAAAAElFTkSuQmCC',
    }, previewOnly: true);
    expect(bytes, isNotNull);
    expect(bytes!.length, lessThanOrEqualTo(85 * 1024));
    expect((await db.collection('_windows_document_outbox').get()).docs, isEmpty);
  });
}

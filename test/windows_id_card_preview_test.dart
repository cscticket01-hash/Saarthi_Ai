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
  test('native manifest preparation reads student and staff designs without writing a PDF or queue', () async {
    for (final kind in ['studentId','teacherId','otherStaffId']) {
      final card=await WindowsDocumentTemplates.nativePersonCard(kind,{
        'schoolId':school, 'name':'Synthetic TEST', 'class':'1',
        'rollNo':'1','schoolName':'TEST Sync V2',
      });
      expect(card,isNotNull);
      expect(card!.data['name'],'Synthetic TEST');
      expect(card.template.id,'school-id-v1');
      expect(card.backgrounds,isEmpty);
      expect(card.template.regions.any((r)=>r.side=='front'),isTrue);
      expect(card.template.regions.any((r)=>r.side=='back'),isTrue);
    }
    expect((await db.collection('_windows_document_outbox').get()).docs,isEmpty);
  });
  test('explicit white ID preview does not rewrite automatic issuance selection', () async {
    await db.collection('school_settings').doc('document_templates').set({'studentId':'plain'});
    final card=await WindowsDocumentTemplates.nativePersonCard('studentId',{
      'schoolId':school,'schoolName':'Test school','name':'Synthetic student'});
    expect(card!.template.id,'school-id-v1');
    expect(WindowsDocumentTemplates.studentCardSelection('plain'),
      WindowsDocumentTemplates.studentCardSelection(null));
    expect((await db.collection('_windows_document_outbox').get()).docs,isEmpty);
  });
  test('student preview and export validate the stored template category', () async {
    await db.collection('school_settings').doc('document_templates').set({
      'studentId': 'manifest:school-id-v1',
    });
    final person = {'schoolId': school, 'name': 'Synthetic Student'};
    await expectLater(
      WindowsDocumentTemplates.nativePersonCard('studentId', person),
      throwsStateError,
    );
    await expectLater(
      WindowsDocumentTemplates.selected('studentId', person),
      throwsStateError,
    );
  });
  test('native manifest preparation rejects foreign school', () async {
    await expectLater(WindowsDocumentTemplates.nativePersonCard('studentId',{
      'schoolId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    }),throwsStateError);
  });
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

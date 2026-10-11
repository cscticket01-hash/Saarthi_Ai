import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/id_card_designer.dart';
import '../lib/id_card_draft_storage_io.dart';

Map<String, dynamic> _manifest() => {
  'version': 1,
  'id': 'school-design',
  'canvasWidth': 100,
  'canvasHeight': 100,
  'printWidthMm': 54,
  'printHeightMm': 54,
  'regions': [
    {
      'key': 'name',
      'side': 'front',
      'kind': 'text',
      'x': 5,
      'y': 5,
      'width': 50,
      'height': 20,
    },
    {
      'key': 'backName',
      'side': 'back',
      'kind': 'text',
      'x': 5,
      'y': 5,
      'width': 50,
      'height': 20,
    },
  ],
};

Map<String, dynamic> _draft(String school, {double x = 5}) {
  final designer = IdCardDesigner(schoolId: school, manifest: _manifest());
  designer.move('front', 'name', x, 5);
  return designer.exportDraft(templateVersion: 'schema-v1');
}

void main() {
  late Directory root;
  setUp(() {
    root = Directory.systemTemp.createTempSync('saarthi-id-drafts-');
  });
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('draft survives a fresh repository instance without cloud access', () async {
    final store = IdCardDraftStorageIo(rootPath: root.path, schoolId: 'A');
    expect(await store.loadDraft(), isNull);
    await store.saveDraft(_draft('A', x: 13));
    final rebooted = IdCardDraftStorageIo(rootPath: root.path, schoolId: 'A');
    final saved = await rebooted.loadDraft();
    expect(saved?['schoolId'], 'A');
    expect(saved?['templateVersion'], 'schema-v1');
    final designer = IdCardDesigner(schoolId: 'A', manifest: _manifest());
    designer.restore(saved!);
    expect(designer.template.regions.first.x, 13);
  });

  test('a different school cannot read or write another school draft', () async {
    final a = IdCardDraftStorageIo(rootPath: root.path, schoolId: 'A');
    final b = IdCardDraftStorageIo(rootPath: root.path, schoolId: 'B');
    await a.saveDraft(_draft('A', x: 31));
    expect(await b.loadDraft(), isNull);
    await expectLater(b.saveDraft(_draft('A')), throwsFormatException);
    await b.saveDraft(_draft('B', x: 41));
    expect(((await a.loadDraft())!['manifest'] as Map)['regions'][0]['x'], 31);
    expect(((await b.loadDraft())!['manifest'] as Map)['regions'][0]['x'], 41);
  });

  test('keeps previous version for explicit recovery without restoring it silently', () async {
    final store = IdCardDraftStorageIo(rootPath: root.path, schoolId: 'A');
    await store.saveDraft(_draft('A', x: 10));
    await store.saveDraft(_draft('A', x: 20));
    expect(((await store.loadDraft())!['manifest'] as Map)['regions'][0]['x'], 20);
    expect(((await store.readPreviousRevision())!['manifest'] as Map)['regions'][0]['x'], 10);
    expect(((await store.loadDraft())!['manifest'] as Map)['regions'][0]['x'], 20);
  });

  test('invalid edits cannot destroy the last committed draft', () async {
    final store = IdCardDraftStorageIo(rootPath: root.path, schoolId: 'A');
    await store.saveDraft(_draft('A', x: 15));
    final invalid = _draft('A');
    (invalid['manifest'] as Map)['canvasWidth'] = -100;
    await expectLater(store.saveDraft(invalid), throwsA(isA<Exception>()));
    expect(((await store.loadDraft())!['manifest'] as Map)['regions'][0]['x'], 15);
  });

  test('corrupted newest draft is rejected, old revision remains accessible', () async {
    final store = IdCardDraftStorageIo(rootPath: root.path, schoolId: 'A');
    await store.saveDraft(_draft('A', x: 17));
    await store.saveDraft(_draft('A', x: 27));
    final drafts = root.listSync().whereType<File>()
        .where((file) => file.path.endsWith('.draft.json')).toList();
    expect(drafts, hasLength(1));
    final broken = jsonDecode(drafts.single.readAsStringSync()) as Map;
    (broken['draft']['manifest']['regions'][0] as Map)['x'] = 91;
    drafts.single.writeAsStringSync(jsonEncode(broken), flush: true);
    await expectLater(store.loadDraft(), throwsFormatException);
    expect(((await store.readPreviousRevision())!['manifest'] as Map)['regions'][0]['x'], 17);
    await expectLater(store.saveDraft(_draft('A', x: 31)), throwsFormatException);
  });

  test('concurrent saves preserve complete revisions, never partial JSON', () async {
    final store = IdCardDraftStorageIo(rootPath: root.path, schoolId: 'A');
    await Future.wait([
      for (var x = 10; x < 14; x++) store.saveDraft(_draft('A', x: x.toDouble())),
    ]);
    final saved = await store.loadDraft();
    final x = ((saved!['manifest'] as Map)['regions'] as List).first['x'];
    expect([10, 11, 12, 13], contains(x));
    final revisions = root.listSync().whereType<File>()
        .where((file) => file.path.contains('.draft.json.bak.')).toList();
    expect(revisions, hasLength(3));
    expect(await store.readPreviousRevision(), isNotNull);
  });
}

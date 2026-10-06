import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/id_card_manifest.dart';
import '../lib/id_card_engine.dart';
import '../lib/id_card_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map<String, dynamic> manifest() => Map<String, dynamic>.from(
    jsonDecode(File('assets/school_id_manifest_v1.json').readAsStringSync()),
  );
  test('bundled catalog validates manifests and rejects external or traversing assets', () async {
    final entries = await IdCardCatalog.load();
    expect(
      entries.single.kinds,
      containsAll(['studentId', 'teacherId', 'otherStaffId']),
    );
    expect((await entries.single.manifest()).id, entries.single.id);
    for (final asset in [
      'https://evil.example/card.json',
      'assets/../private.json',
    ]) {
      expect(
        () => IdCardCatalogEntry({
          'id': 'test-id',
          'name': 'Test',
          'manifest': asset,
          'kinds': ['studentId'],
        }),
        throwsFormatException,
      );
    }
  });
  test('manifest rejects overflow, duplicate regions, unknown version and distorted print dimensions', () {
    final raw = manifest();
    final valid = IdCardManifest.fromJson(raw);
    expect(valid.printWidth, 54);
    expect(valid.printHeight, 85.6);
    expect(valid.regions.map((r) => r.side).toSet(), {'front', 'back'});
    expect(
      () => IdCardManifest.fromJson({...raw, 'version': 2}),
      throwsFormatException,
    );
    expect(
      () => IdCardManifest.fromJson({...raw, 'printWidthMm': 85.6}),
      throwsFormatException,
    );
    expect(
      () => IdCardManifest.fromJson({
        ...raw,
        'regions': [...raw['regions'], raw['regions'][0]],
      }),
      throwsFormatException,
    );
    expect(
      () => IdCardManifest.fromJson({
        ...raw,
        'regions': [
          {...raw['regions'][0], 'x': 215},
          ...raw['regions'].skip(1),
        ],
      }),
      throwsFormatException,
    );
  });
  test('shared manifest renders Student Teacher and Other Staff as one physical front/back PDF page', () async {
    final template = IdCardManifest.fromJson(manifest());
    for (final role in ['Student', 'Teacher', 'Other Staff']) {
      final bytes = await IdCardEngine.render(template, {
        'schoolName': 'Own School',
        'name': 'Arup Das',
        'designation': role,
        'address': 'School Road, Silchar',
        'rollNo': '12',
      }, qr: 'verified-test-id');
      final text = latin1.decode(bytes);
      expect(text.startsWith('%PDF'), true);
      expect(RegExp(r'/Type\s*/Page\b').allMatches(text).length, 1);
      final box = RegExp(
        r'/MediaBox\s*\[\s*0(?:\.0+)?\s+0(?:\.0+)?\s+([\d.]+)\s+([\d.]+)',
      ).firstMatch(text);
      expect(box, isNotNull);
      expect(double.parse(box!.group(1)!), closeTo(116 * 72 / 25.4, 0.02));
      expect(double.parse(box.group(2)!), closeTo(85.6 * 72 / 25.4, 0.02));
      final folder = Directory('build/reference-document-previews');
      await folder.create(recursive: true);
      await File('${folder.path}/manifest_${role.replaceAll(' ', '_')}.pdf')
          .writeAsBytes(bytes);
    }
  });
}

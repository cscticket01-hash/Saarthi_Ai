import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/id_card_manifest.dart';
import '../lib/id_card_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map<String, dynamic> manifest() => Map<String, dynamic>.from(
    jsonDecode(File('assets/school_id_manifest_v1.json').readAsStringSync()),
  );
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
      expect(text.contains('/MediaBox'), true);
    }
  });
}

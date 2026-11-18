import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import '../lib/id_card_indic_text.dart';
import '../lib/id_card_manifest.dart';
import '../lib/id_card_engine.dart';
import '../lib/id_card_catalog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Latin names continue through searchable PDF font path', () async {
    expect(IdCardIndicText.needsShaping('Arup Das'), false);
    expect(await IdCardIndicText.rasterize(
      'Arup Das', width: 180, height: 25, fontSize: 15,
      minFontSize: 8, maxLines: 1, align: 'left',
    ), isNull);
  });

  test('Bengali Assamese and Devanagari use a valid offline rendered image', () async {
    for (final name in ['বিদ্যা', 'অসমীয়া ৰ ৱ', 'मोहन', 'বিদ্যা विद्यालय']) {
      expect(IdCardIndicText.needsShaping(name), true);
      final png = await IdCardIndicText.rasterize(
        name, width: 180, height: 35, fontSize: 14,
        minFontSize: 8, maxLines: 1, align: 'left',
      );
      expect(png, isA<Uint8List>());
      expect(png!.sublist(0, 8),
          [137, 80, 78, 71, 13, 10, 26, 10]);
    }
  });

  test('invalid multilingual text dimensions fail instead of silently clipping', () async {
    await expectLater(
      IdCardIndicText.rasterize('विद्यालय', width: 0, height: 10,
          fontSize: 12, minFontSize: 8, maxLines: 1, align: 'left'),
      throwsFormatException,
    );
  });

  test('compact PDF font is safe for shaped Indic fields and ASCII vectors', () async {
    final template = IdCardManifest.fromJson(Map<String,dynamic>.from(
      jsonDecode(File('assets/school_id_manifest_v1.json').readAsStringSync())
          as Map));
    // These displayed fields are rendered by the bundled shaping engine into
    // unchanged lossless PNGs. They do not need a second embedded PDF font.
    final indic = await IdCardEngine.prepare(template, {
      'schoolName': 'বিদ্যা',
      'name': 'मोहन',
      'parentName': 'অসমীয়া',
      'address': 'Silchar',
      'unusedMetadata': 'বাংলা', // Not part of the PDF's vector text.
    });
    expect(indic.shapedText.keys,
      containsAll(['front:schoolName', 'front:name', 'back:parentName']));
    expect(IdCardEngine.canUseCompactPdfFont(indic), isTrue);

    // A remaining non-ASCII vector field must never be silently rewritten
    // with Helvetica; preserve the original embedded Unicode font instead.
    final nonAsciiVector = await IdCardEngine.prepare(template, {
      'schoolName': 'Own School',
      'name': 'Student',
      'address': 'Café Road',
    });
    expect(nonAsciiVector.shapedText.containsKey('back:address'), isFalse);
    expect(IdCardEngine.canUseCompactPdfFont(nonAsciiVector), isFalse);
  });

  test('real bundled front/back school artwork with Indic text fits the unchanged 85 KiB limit', () async {
    final entry = await IdCardCatalog.find('student-maroon-gold-v1');
    final bytes = await IdCardEngine.render(
      await entry.manifest(),
      {
        'schoolName': 'বিদ্যা বিদ্যালয়',
        'name': 'मोहन',
        'parentName': 'অসমীয়া',
        'class': 'VII',
        'rollNo': '014',
        'address': 'Silchar',
        'contact': '1234567890',
      },
      backgrounds: await entry.backgrounds(),
    );
    expect(latin1.decode(bytes.take(4).toList()), '%PDF');
    expect(bytes.length, lessThanOrEqualTo(85 * 1024));
  });

  test('actual student ID renderer can embed Indic fields in a PDF', () async {
    final manifest=IdCardManifest.fromJson(Map<String,dynamic>.from(
      jsonDecode(File('assets/school_id_manifest_v1.json').readAsStringSync())
          as Map));
    final bytes=await IdCardEngine.render(manifest, {
      'schoolName': 'বিদ্যা',
      'name': 'मोहन',
      'parentName': 'অসমীয়া',
    });
    expect(bytes, isNotEmpty);
    expect(latin1.decode(bytes.take(4).toList()), '%PDF');
  });
}

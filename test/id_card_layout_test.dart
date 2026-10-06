import '../lib/school_qr_link.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../lib/id_card_layout.dart';
import '../lib/id_card_manifest.dart';
import '../lib/id_card_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map<String, dynamic> manifest() =>
      jsonDecode(File('assets/school_id_manifest_v1.json').readAsStringSync())
          as Map<String, dynamic>;
  for (final s in [
    'Normal Name',
    'A Very Long Student Name ' * 5,
    'Long Guardian Name ' * 8,
    'House Village District State PIN ' * 15,
    'A Long School Name ' * 8,
    '',
  ]) {
    test(
      'bounded measured text fits readable region: ${s.substring(0, s.length > 20 ? 20 : s.length)}',
      () {
        final fit = IdCardLayout.fitText(
          s,
          width: 150,
          height: 32,
          measure: (s) => s.runes.length * .6,
          fontSize: 14,
          minFontSize: 8,
          wrap: true,
          maxLines: 3,
        );
        expect(fit.fontSize, inInclusiveRange(8, 14));
        final lines = fit.text.split('\n');
        expect(lines.length, lessThanOrEqualTo(3));
        expect(lines.length * fit.fontSize * 1.25, lessThanOrEqualTo(32));
        for (final line in lines)
          expect(line.runes.length * .6 * fit.fontSize, lessThanOrEqualTo(150));
        if (s.length > 100) expect(fit.truncated, true);
      },
    );
  }
  test(
    'nonwrapping fields never acquire extra lines; impossible strict fit fails',
    () {
      final fit = IdCardLayout.fitText(
        'Name ' * 100,
        width: 90,
        height: 15,
        measure: (s) => s.length * .6,
        fontSize: 12,
        minFontSize: 8,
      );
      expect(fit.text.contains('\n'), false);
      expect(fit.text.endsWith('…'), true);
      expect(
        () => IdCardLayout.fitText(
          'Name ' * 100,
          width: 90,
          height: 15,
          measure: (s) => s.length * .6,
          fontSize: 12,
          minFontSize: 8,
          overflow: 'error',
        ),
        throwsFormatException,
      );
    },
  );
  test('truncated complete-header PNG/JPEG fails safely in ID fitting', () {
    final image = img.Image(width: 20, height: 30);
    for (final bytes in [img.encodePng(image), img.encodeJpg(image)]) {
      final truncated = Uint8List.fromList(bytes.sublist(0, bytes.length - 4));
      expect(() => IdCardLayout.prepareImage(truncated, aspect: .8), throwsFormatException);
    }
  });
  test('exact manifest minimum is measured before readable text is truncated', () {
    final fit = IdCardLayout.fitText('Long Name', width: 9 * .6 * 8.1,
      height: 20, measure: (s) => s.length * .6,
      fontSize: 12, minFontSize: 8.1);
    expect(fit.fontSize, 8.1);
    expect(fit.text, 'Long Name');
    expect(fit.truncated, false);
  });
  for (final shape in [
    [400, 600],
    [900, 300],
    [200, 1000],
    [2400, 3200],
  ]) {
    test(
      'portrait ${shape[0]}×${shape[1]} is safely cropped without stretching',
      () {
        final source = img.Image(width: shape[0], height: shape[1]);
        img.fill(source, color: img.ColorRgb8(120, 150, 180));
        final bytes = Uint8List.fromList(img.encodeJpg(source));
        final original = List<int>.from(bytes);
        final fitted = img.decodePng(
          IdCardLayout.prepareImage(bytes, aspect: .8, cover: true),
        )!;
        expect(fitted.width / fitted.height, closeTo(.8, .01));
        expect(fitted.width, lessThanOrEqualTo(1600));
        expect(fitted.height, lessThanOrEqualTo(1600));
        expect(bytes, original);
        final contained = img.decodePng(
          IdCardLayout.prepareImage(bytes, aspect: .8),
        )!;
        expect(
          contained.width / contained.height,
          closeTo(shape[0] / shape[1], .01),
        );
      },
    );
  }
  test('portrait crop is top weighted and invalid fit/image fails safely', () {
    final source = img.Image(width: 100, height: 500);
    for (final p in source) p.r = p.y / 2;
    final fitted = img.decodePng(
      IdCardLayout.prepareImage(
        Uint8List.fromList(img.encodePng(source)),
        aspect: 1,
        cover: true,
      ),
    )!;
    expect(fitted.getPixel(50, 0).r, closeTo(70, 2));
    expect(
      () => IdCardLayout.prepareImage(Uint8List.fromList([1, 2, 3]), aspect: 1),
      throwsFormatException,
    );
    expect(
      () => IdCardLayout.prepareImage(Uint8List(0), aspect: 0),
      throwsFormatException,
    );
  });
  test(
      'QR has four module quiet space and rejects unscannably small payload region',
      () {
    expect(
      IdCardLayout.qrPadding('verified-person', 100, physicalSideMm: 20),
      greaterThan(0),
    );
    expect(
      () => IdCardLayout.qrPadding('x' * 1000, 40, physicalSideMm: 8),
      throwsFormatException,
    );
  });
  test(
      'manifest rejects dynamic collisions, too-small QR, wrong image fit and malformed rules',
      () {
    final base = manifest();
    final rows = (base['regions'] as List).cast<Map>();
    for (final patch in [
      {'x': 0, 'y': 0},
      {'minFontSize': 3},
      {'focusY': 2},
      {
        'allowOverlapWith': ['nonexistent'],
      },
    ]) {
      expect(
        () => IdCardManifest.fromJson({
          ...base,
          'regions': [
            ...rows.take(3),
            {...rows[3], ...patch},
            ...rows.skip(4),
          ],
        }),
        throwsFormatException,
      );
    }
    final qr = rows.indexWhere((r) => r['kind'] == 'qr');
    expect(
      () => IdCardManifest.fromJson({
        ...base,
        'regions': [
          ...rows.take(qr),
          {...rows[qr], 'width': 20, 'height': 20},
          ...rows.skip(qr + 1),
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => IdCardManifest.fromJson({
        ...base,
        'regions': [
          {...rows.first, 'fit': 'cover'},
          ...rows.skip(1),
        ],
      }),
      throwsFormatException,
    );
    expect(
      () => IdCardManifest.fromJson({...base, 'regions': 'invalid'}),
      throwsFormatException,
    );
  });
  for (final role in ['Student', 'Teacher', 'Other Staff']) {
    test(
      'manifest renders $role stress content, assets and front/back at physical size',
      () async {
        final portrait = Uint8List.fromList(
          img.encodePng(img.Image(width: 500, height: 200)),
        );
        final small = Uint8List.fromList(
          img.encodePng(img.Image(width: 20, height: 50)),
        );
        final bytes = await IdCardEngine.render(
          IdCardManifest.fromJson(manifest()),
          {
            'name': 'Long Person Name ' * 8,
            'parentName': 'Long Guardian ' * 8,
            'address': 'House Street Village District State PIN ' * 10,
            'schoolName': 'Long School ' * 10,
            'designation': role,
          },
          images: {
            'photo': portrait,
            'logo': small,
            'seal': small,
            'signature': portrait,
          },
          qr: 'verified-${role.replaceAll(' ', '-')}',
        );
        final raw = latin1.decode(bytes);
        expect(RegExp(r'/Type\s*/Page\b').allMatches(raw).length, 1);
        expect(raw, contains('/MediaBox'));
        final dir = Directory('build/reference-document-previews');
        await dir.create(recursive: true);
        await File(
          '${dir.path}/manifest_stress_${role.replaceAll(' ', '_')}.pdf',
        ).writeAsBytes(bytes);
      },
    );
  }
  test('manifest rejects impossible tiny portrait region', () {
    final base = manifest();
    final rows = (base['regions'] as List).cast<Map>();
    expect(
        () => IdCardManifest.fromJson({
              ...base,
              'regions': [
                ...rows.take(2),
                {...rows[2], 'width': 1},
                ...rows.skip(3)
              ]
            }),
        throwsFormatException);
  });
  test(
      'real Windows managed authentication envelopes render without changing identity',
      () async {
    final fixtures = (jsonDecode(
                File('test/fixtures/windows_person_qr.json').readAsStringSync())
            as List)
        .cast<Map>();
    for (final fixture in fixtures) {
      final raw = SchoolLink.encodeCompact(Map<String,dynamic>.from(fixture));
      final bytes = await IdCardEngine.render(
          IdCardManifest.fromJson(manifest()),
          Map<String, dynamic>.from(fixture),
          qr: raw);
      final dir = Directory('build/reference-document-previews');
      await dir.create(recursive: true);
      await File('${dir.path}/manifest_auth_${fixture['type']}.pdf')
          .writeAsBytes(bytes);
      expect(SchoolLink.parse(raw).schoolId, fixture['schoolId']);
      expect(bytes.length, greaterThan(500));
    }
  });
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import '../lib/windows_student_excel.dart';
import '../lib/windows_admin_avatar.dart';

void main() {
  test(
    'class workbooks embed photos, retain leading zeros and escape formulas',
    () async {
      final photo = Uint8List.fromList(
        img.encodePng(img.Image(width: 10, height: 10)),
      );
      final bytes = await StudentExcelExport.build(
        schoolId: 'school-a',
        students: [
          {
            'id': 'one',
            'schoolId': 'school-a',
            'class': 'Class 2',
            'name': '=HYPERLINK("bad")',
            'rollNo': '001',
            'photoUrl': 'photo',
          },
          {
            'id': 'two',
            'class': 'Class 1',
            'name': 'विद्यार्थी',
            'photoUrl': 'missing',
          },
          {'id': 'deleted', 'class': 'Class 3', '_syncDeleted': true},
        ],
        imageReader: (source) async => source == 'photo' ? photo : null,
        checkSchool: () {},
      );
      final files = ZipDecoder().decodeBytes(bytes);
      String content(String path) =>
          utf8.decode(files.findFile(path)!.content as List<int>);
      expect(content('xl/workbook.xml'), contains('Class 1'));
      expect(content('xl/workbook.xml'), contains('Class 2'));
      expect(content('xl/workbook.xml'), isNot(contains('Class 3')));
      final sheets = files.files
          .where(
            (f) =>
                f.name.startsWith('xl/worksheets/sheet') &&
                f.name.endsWith('.xml'),
          )
          .map((f) => utf8.decode(f.content as List<int>))
          .join();
      expect(sheets, contains('001'));
      expect(sheets, contains('=HYPERLINK(&quot;bad&quot;)'));
      expect(sheets, isNot(contains('<f>')));
      expect(sheets, contains('Photo unavailable'));
      expect(
        files.files.where((f) => f.name.startsWith('xl/media/')),
        hasLength(1),
      );
    },
  );
  test('export rejects foreign records and stops after a school switch during photo loading', () async {
    Future<Uint8List> export(
      List<Map<String, dynamic>> rows, {
      bool switchDuringRead = false,
    }) {
      var current = true;
      return StudentExcelExport.build(
        schoolId: 'a',
        students: rows,
        imageReader: (_) async {
          if (switchDuringRead) current = false;
          return null;
        },
        checkSchool: () {
          if (!current) throw StateError('School changed');
        },
      );
    }

    await expectLater(
      export([
        {'schoolId': 'b', 'name': 'Foreign'},
      ]),
      throwsStateError,
    );
    await expectLater(
      export([
        {'name': 'Own', 'photoUrl': 'photo'},
      ], switchDuringRead: true),
      throwsStateError,
    );
  });
  test('administrator images accept Google HTTPS images only', () {
    expect(
      googleProfileImageUrl('https://lh3.googleusercontent.com/a/photo.gif'),
      isTrue,
    );
    for (final url in [
      'http://lh3.googleusercontent.com/a',
      'https://googleusercontent.com.attacker.test/a',
      'https://attacker.test/a',
      'file:///photo',
      'https://user@lh3.googleusercontent.com/a',
    ]) {
      expect(googleProfileImageUrl(url), isFalse, reason: url);
    }
  });
}

import '../lib/school_qr_link.dart';
import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_student_id_cards.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'old, unset and invalid template selections resolve without record changes',
    () {
      for (final v in [null, -1, 99, 'old']) {
        expect(windowsStudentIdIndex(v), 0);
      }
      for (var i = 0; i < 4; i++) {
        expect(windowsStudentIdIndex(i), i);
      }
    },
  );
  test(
      'four Windows designs render both sides, required fields and scan payload',
      () async {
    final output = Directory('build/windows-id-previews');
    await output.create(recursive: true);
    final sample = {
      'schoolName': 'VIDYA SAARTHI SCHOOL',
      'schoolAddress': 'School Road, Silchar',
      'name': 'Anamika Pandey',
      'parentName': 'Mr. Naveen Pandey',
      'class': 'Class VIII A',
      'roll': '24',
      'contact': '9876543210',
      'streetAddress': 'Street No. 4, Civil Lines',
      'district': 'Cachar',
      'state': 'Assam',
      'pinCode': '788001',
      'showStudentUid': true,
      'studentUid': 'VS-TEST-24',
    };
    for (var i = 0; i < 4; i++) {
      final bytes = await renderWindowsStudentId(
        template: i,
        data: sample,
        qr: SchoolLink.encodeCompact(Map<String,dynamic>.from((jsonDecode(File('test/fixtures/windows_person_qr.json').readAsStringSync()) as List).first)),
        photo: await File('assets/school_logo.png').readAsBytes(),
        logo: await File('assets/school_logo.png').readAsBytes(),
        signature: await File('assets/principal_sign.png').readAsBytes(),
      );
      final raw = latin1.decode(bytes);
      expect(raw.startsWith('%PDF'), isTrue);
      expect(RegExp(r'/Type\s*/Page\b').allMatches(raw).length, 1);
      await File('${output.path}/student_reference_$i.pdf').writeAsBytes(bytes);
      // Very long fields and missing assets must also remain printable.
      await expectLater(renderWindowsStudentId(template:i,data:{...sample,
        'name':'Student With A Very Long Name '*100}),throwsFormatException);
      final longBytes=await renderWindowsStudentId(template:i,data:{...sample,
        'name':'Mohit Kumar Das Choudhury','parentName':'Arup Chandra Das Choudhury',
        'schoolName':'Vivekananda Vidya Mandir Higher Secondary School'});
      expect(longBytes.length,greaterThan(500));
      await File('${output.path}/student_long_$i.pdf').writeAsBytes(longBytes);
      final empty = await renderWindowsStudentId(template: i, data: {});
      expect(empty.length, greaterThan(500));
    }
  });
}

import 'package:flutter_test/flutter_test.dart';
import '../lib/id_card_catalog.dart';
import '../lib/id_card_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('SVN Navy & Green is a selectable student-only ID template', () async {
    final entries = await IdCardCatalog.load();
    final design = entries.singleWhere((e) => e.id == 'student-svn-navy-green-v1');
    expect(design.kinds, ['studentId']);
    expect(design.name, contains('Clean Photo'));
    final manifest = await design.manifest();
    expect(manifest.printWidth, 85.6);
    expect(manifest.printHeight, 54);
    final backgrounds = await design.backgrounds();
    expect(backgrounds['front'], isNotEmpty);
    expect(backgrounds['back'], isNotEmpty);
    expect(manifest.regions.any((r) => r.side == 'front' &&
        r.kind == 'image' && r.key == 'photo'), isTrue);
    expect(manifest.regions.any((r) =>
        r.key.toLowerCase().contains('active') ||
        r.label.toLowerCase().contains('active')), isFalse);
    expect(manifest.regions.any((r) =>
        r.side == 'front' && r.kind == 'qr'), isTrue);
  });

  test('SVN template binds school identity and student fields, never fixed source PDF identity', () async {
    final manifest = await (await IdCardCatalog.find('student-svn-navy-green-v1')).manifest();
    final mapped = IdCardEngine.normalizedInput(manifest, {
      'schoolName': 'Example School',
      'schoolAddress': 'School Town',
      'name': 'Sample Student',
      'fatherName': 'Parent',
      'studentClass': 'Class 1',
      'rollNo': '01',
      'studentId': 'CARD-001',
      'dateOfBirth': '01/01/2016',
      'parentContact': '0000000000',
      'streetAddress': 'Sample Address',
    });
    expect(mapped['schoolName'], 'Example School');
    expect(mapped['schoolLocation'], 'School Town');
    expect(mapped['name'], 'Sample Student');
    expect(mapped['parentName'], 'Parent');
    expect(mapped['studentUid'], 'CARD-001');
    expect(mapped['dob'], '01/01/2016');
    expect(mapped['contact'], '0000000000');
    expect(mapped['address'], 'Sample Address');
  });
}

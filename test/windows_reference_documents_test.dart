import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_reference_documents.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'all nine reference designs render real data and printable front/back cards',
      () async {
    final folder = Directory('build/reference-document-previews');
    await folder.create(recursive: true);
    final sample = <String, dynamic>{
      'schoolName': 'Vidya Saarthi School',
      'name': 'Ananya Sharma',
      'studentName': 'Arup Das',
      'teacherId': 'T-001',
      'studentId': 'S-012',
      'qualification': 'M.Sc (Physics)',
      'joiningDate': '01/06/2024',
      'designation': 'Senior Teacher',
      'subject': 'Mathematics',
      'contact': '9876543210',
      'email': 'teacher@school.example',
      'schoolContactNo': '9876543210',
      'schoolEmail': 'office@school.example',
      'schoolAddress': 'School Road, Silchar, Assam 788001',
      'address': 'School Road, Silchar',
      'academicYear': '2026-2027',
      'class': 'Class VI',
      'rollNo': '12',
      'examName': 'Term 1',
      'dateText': '04/10/2026',
      'marks': {
        'English': 84,
        'Mathematics': 91,
        'Science': 87,
        'Social Studies': 80,
        'Bengali': 88,
        'Hindi': 83
      },
      'percentage': '85.5',
      'result': 'PASS',
      'remarks': 'Shows steady progress and participates well in class.',
      'feeItems': {'Tuition': 1000, 'Exam': 200},
      'expectedAmount': 1200,
      'installmentAmount': 500,
      'totalPaid': 500,
      'balance': 700,
      'receiptNo': 'VS-001',
      'month': 'October 2026',
      'paymentMode': 'Cash',
      'parentName': 'Bikash Das',
      'parentContact': '9876543210',
      'collectedBy': 'School Admin',
      'status': 'PART PAID'
    };
    for (final kind in windowsReferenceDocumentNames.keys) {
      for (var i = 0; i < windowsReferenceDocumentNames[kind]!.length; i++) {
        final bytes = await renderWindowsReferenceDocument(
            kind: kind,
            template: i,
            data: sample,
            qr: 'VIDYA_SAARTHI_TEST_TEACHER',
            photo: await File('assets/school_logo.png').readAsBytes(),
            logo: await File('assets/school_logo.png').readAsBytes(),
            signature: await File('assets/principal_sign.png').readAsBytes());
        expect(String.fromCharCodes(bytes.take(4)), '%PDF');
        await File('${folder.path}/${kind}_$i.pdf').writeAsBytes(bytes);
      }
      expect(windowsReferenceDocumentIndex(kind, -1), 0);
      expect(windowsReferenceDocumentIndex(kind, 99), 0);
    }
    expect(windowsReferenceTermNumber({'examName': 'Term 2'}), 2);
    expect(windowsReferenceTermNumber({'examName': 'Quarter 4'}), 4);
    expect(windowsReferenceTermNumber({'examName': 'Final 2026', 'isFinal': true}), isNull);
    for (final pair in [('reportCard_term2', 3), ('reportCard_quarter2', 1)]) {
      final bytes = await renderWindowsReferenceDocument(kind: 'reportCard', template: pair.$2,
          data: {...sample, 'examName': 'Term 2', 'isFinal': false});
      await File('${folder.path}/${pair.$1}.pdf').writeAsBytes(bytes);
    }
    for (final kind in ['reportCard', 'receipt']) {
      final large = {
        ...sample,
        'marks': {for (var n = 1; n <= 25; n++) 'Subject $n': n + 60},
        'feeItems': {for (var n = 1; n <= 25; n++) 'Fee $n': n * 100}
      };
      final bytes = await renderWindowsReferenceDocument(
          kind: kind, template: 0, data: large);
      await File('${folder.path}/${kind}_continuation.pdf').writeAsBytes(bytes);
    }
  });
}

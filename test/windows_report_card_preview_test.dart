import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_report_card_preview.dart';
import '../lib/windows_receipt_print_dialog.dart';

void main() {
  testWidgets('report eye opens one shared print preview directly',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1160, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: WindowsReportCardPreview(
          record: const {
            'schoolName': 'Test School',
            'studentName': 'Student',
            'studentClass': 'Class 5',
            'examName': 'Final Exam',
            'academicSession': '2026-2027',
            'rollNo': '4',
            'marks': {'English': 70, 'Maths': 85},
            'fullMarks': 100,
            'passMarks': 33,
            'totalMarks': 155,
            'percentage': 77.5,
            'result': 'PASS',
          },
        ),
      ),
    ));
    await tester.pump();
    expect(find.byType(WindowsReceiptPrintDialog), findsOneWidget);
    expect(find.text('Print preview'), findsOneWidget);
    expect(find.text('Print Report Card'), findsNothing);
    expect(find.text('Download Report Card'), findsNothing);
    expect(find.text('Report Card Preview'), findsNothing);
  });
}

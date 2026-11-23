import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_report_card_preview.dart';

void main() {
  testWidgets('record preview shows print and download without rendering PDF',
      (tester) async {
    var pdfRenderCalls = 0;
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
          createPdf: () async {
            pdfRenderCalls++;
            return Uint8List.fromList([]);
          },
        ),
      ),
    ));
    await tester.pump();
    expect(find.text('Print Report Card'), findsOneWidget);
    expect(find.text('Download Report Card'), findsOneWidget);
    expect(find.text('STUDENT PROGRESS REPORT'), findsOneWidget);
    expect(pdfRenderCalls, 0,
      reason: 'Preview creation must never invoke the PDF renderer.');
  });
}

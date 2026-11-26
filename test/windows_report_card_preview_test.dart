import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:printing/printing.dart';
import 'package:printing/src/interface.dart';

import '../lib/fitted_document_preview.dart';
import '../lib/windows_document_templates.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_maroon_marksheet.dart';
import '../lib/windows_receipt_print_dialog.dart';
import '../lib/windows_report_card_preview.dart';
import '../lib/windows_runtime_flags.dart';
import 'windows_receipt_print_dialog_test.dart' show PaperSizePrinting;

class ReportPreviewPrinting extends PaperSizePrinting {
  ReportPreviewPrinting() : super(1654, 2339);
  final List<Uint8List> documents = [];
  @override
  Future<List<Printer>> listPrinters() async => [];
  @override
  Stream<PdfRaster> raster(Uint8List document, List<int>? pages, double dpi) {
    documents.add(document);
    return super.raster(document, pages, dpi);
  }
}

const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const record = <String, dynamic>{
  'schoolId': school,
  'schoolName': 'Test School',
  'studentName': 'Student',
  'studentClass': 'Class 1',
  'examName': 'Final Exam',
  'academicSession': '2026-2027',
  'rollNo': '1',
  'marks': {'English': 40, 'Maths': 50, 'Science': 58},
  'fullMarks': 100,
  'passMarks': 33,
  'totalMarks': 148,
  'percentage': 49.333333333333336,
  'result': 'PASS',
};

void main() {
  test('financial selection distinguishes missing/white from explicit design zero', () {
    for(final kind in ['receipt','reportCard','payslip']) {
      expect(WindowsDocumentTemplates.financialSelection(kind,null), 'plain');
      expect(WindowsDocumentTemplates.financialSelection(kind,'plain'), 'plain');
      expect(WindowsDocumentTemplates.financialSelection(kind,0), 0);
      expect(WindowsDocumentTemplates.financialSelection(kind,'imported:version'), 'imported:version');
    }
    expect(WindowsDocumentTemplates.supportsPlain('studentId'), isFalse);
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = FirebaseFirestore.instance;
  late ReportPreviewPrinting platform;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile('report-preview-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolId': school, 'schoolSyncId': school});
    final original = PrintingPlatform.instance;
    platform = ReportPreviewPrinting();
    PrintingPlatform.instance = platform;
    addTearDown(() => PrintingPlatform.instance = original);
  });

  Future<void> settleReport(WidgetTester tester) async {
    for (var i = 0; i < 120; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
      if (find.byType(Image).evaluate().isNotEmpty ||
          find.text('Document unavailable.').evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  testWidgets('report eye renders the selected real PDF and enables the common print action',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1160, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
      builder: (context) => TextButton(
        onPressed: () => WindowsDocumentTemplates.previewReport(context, record),
        child: const Text('Open report'),
      ),
    ))));
    await tester.runAsync(() async {
      await tester.tap(find.text('Open report'));
      await tester.pump();
    });
    await settleReport(tester);
    expect(find.byType(WindowsReceiptPrintDialog), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.text('Document unavailable.'), findsNothing);
    expect(find.byType(FittedDocumentPreview), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    final preview = tester.widget<FittedDocumentPreview>(find.byType(FittedDocumentPreview));
    expect(String.fromCharCodes(preview.bytes.take(5)), '%PDF-');
    expect(String.fromCharCodes(preview.bytes.skip(preview.bytes.length - 128)), contains('%%EOF'));
    expect(platform.documents, isNotEmpty);
    expect(identical(platform.documents.first, preview.bytes), isTrue);
    expect(find.text('A4 (210 × 297 mm)'), findsOneWidget);
    expect(find.text('Detecting original paper size…'), findsNothing);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save as PDF')).onPressed,
      isNotNull);
    expect(find.text('Print Report Card'), findsNothing);
    expect(find.text('Download Report Card'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('Close receipt'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      expect((await db.collection('_local_student_documents').get()).docs, isEmpty);
      expect((await db.collection('_windows_document_outbox').get()).docs, isEmpty);
    });
  });

  testWidgets('failed report stops detecting paper, disables export and can retry real rendering',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1160, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WindowsReportCardPreview(
      record: record, createPdf: (data) async {
        if (++attempts == 1) throw StateError('Synthetic renderer failure');
        return renderMaroonMarksheet(data);
      },
    ))));
    await tester.pumpAndSettle();
    expect(find.text('Document unavailable.'), findsOneWidget);
    expect(find.text('Detecting original paper size…'), findsNothing);
    expect(find.text('Preparing document…'), findsNothing);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save as PDF')).onPressed,
      isNull);
    expect(platform.documents, isEmpty);
    await tester.runAsync(() async {
      await tester.tap(find.text('Retry document'));
      await tester.pump();
    });
    await settleReport(tester);
    expect(attempts, 2);
    expect(find.text('Document unavailable.'), findsNothing);
    expect(find.byType(FittedDocumentPreview), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save as PDF')).onPressed,
      isNotNull);
    expect(tester.takeException(), isNull);
  });
}

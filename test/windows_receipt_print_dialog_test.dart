import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import '../lib/windows_receipt_print_dialog.dart';

void main() {
  const printer = Printer(url: 'test-epson', name: 'EPSON L3110', isDefault: true, isAvailable: true);
  testWidgets('full app preview defaults A4, never auto prints, and sends exact bytes for each copy', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final bytes = Uint8List.fromList([37,80,68,70,45]);
    final calls = <Uint8List>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WindowsReceiptPrintDialog(
      receipt: Future.value(bytes), title: 'Receipt TEST', subtitle: 'Student', isCurrent: () => true,
      printers: () async => [printer], previewBuilder: (_) => const Center(child: Text('Full page preview')),
      printJob: (selected, original, format) async {
        expect(selected.url, printer.url); expect(format.width, PdfPageFormat.a4.width);
        calls.add(original); return true;
      }))));
    await tester.pumpAndSettle();
    expect(find.text('Full page preview'), findsOneWidget);
    expect(find.text('A4 (210 × 297 mm)'), findsOneWidget);
    expect(calls, isEmpty);
    await tester.enterText(find.byType(TextField), '2');
    await tester.tap(find.widgetWithText(FilledButton, 'Print'));
    await tester.pumpAndSettle();
    expect(calls, hasLength(2)); expect(identical(calls[0], bytes), true);
    expect(identical(calls[1], bytes), true);
    expect(find.text('2 copies sent to printer.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('invalid copies and a school switch cannot submit another print', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var current = true, calls = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: WindowsReceiptPrintDialog(
      receipt: Future.value(Uint8List(1)), title: 'Receipt', subtitle: 'Student', isCurrent: () => current,
      printers: () async => [printer], previewBuilder: (_) => const SizedBox(),
      printJob: (_, __, ___) async { calls++; return true; }))));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '0');
    await tester.tap(find.widgetWithText(FilledButton, 'Print'));
    await tester.pumpAndSettle();
    expect(find.text('Enter 1 to 20 copies.'), findsOneWidget); expect(calls, 0);
    current = false;
    await tester.enterText(find.byType(TextField), '1');
    await tester.tap(find.widgetWithText(FilledButton, 'Print'));
    await tester.pumpAndSettle(); expect(calls, 0);
    expect(tester.takeException(), isNull);
  });
}

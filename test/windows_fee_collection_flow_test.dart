import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/src/interface.dart';
import '../lib/fitted_document_preview.dart';
import '../lib/windows_receipt_print_dialog.dart';
import 'windows_report_card_preview_test.dart' show ReportPreviewPrinting;

import '../lib/windows_backend_bridge.dart';
import '../lib/windows_atomic_financial_coordinator.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_fee_receipt_preview.dart';
import '../lib/windows_person_avatar.dart';
import '../lib/windows_fee_structure.dart';
import '../lib/windows_fee_unpaid_filter.dart';
import '../lib/windows_local_firestore.dart' as local;
import '../lib/windows_runtime_flags.dart';
import '../lib/platform/platform_config.dart';
import '../lib/main_dashboard_screen_windows.dart';
import '../lib/windows_ui_localization.dart' as ui;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = local.FirebaseFirestore.instance;
  const school = 'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  late Uint8List pdf;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      CentralSchoolCloud.key: jsonEncode({
        'managed': true,
        'schoolId': school,
        'uid': 'A',
        'projectId': platformProjectId,
        'endpoint': 'https://unreachable.example/school-cloud',
        'folderId': 'managed',
        'firebaseRefreshToken': 'saved-refresh',
        'email': 'a@example.com',
        'storageReady': false,
      }),
    });
    ui.WindowsUiLanguage.change('en');
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile(
      'fee-flow-${DateTime.now().microsecondsSinceEpoch}',
      identity: {'schoolSyncId': school, 'schoolId': school},
    );
    await db.collection('students_directory').doc('S1').set({
      'schoolId': school,
      'name': 'Student One',
      'class': 'Class 1',
      'rollNo': '1',
      'mobileStableId': 'p-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    });
    final document = pw.Document();
    document.addPage(pw.Page(build: (_) => pw.Text('Original receipt 100')));
    pdf = await document.save();
  });
  Map<String, dynamic> payment(
    String id, {
    double previous = 0,
    double amount = 100,
  }) => {
    'schoolId': school,
    'paymentId': id,
    'receiptNo': 'VS-$id',
    'receiptDocumentId': 'FEE-$id',
    'studentId': 'S1',
    'studentName': 'Student One',
    'class': 'Class 1',
    'rollNo': '1',
    'month': '2026-10',
    'feeIdentity': 'stable-S1',
    'expectedAmount': 200.0,
    'installmentAmount': amount,
    'totalPaid': previous + amount,
    'balance': 200 - previous - amount,
    'paidAt': local.Timestamp.fromDate(DateTime(2026, 10, 29)),
    'paymentMode': 'Cash',
    'status': previous + amount == 200 ? 'PAID' : 'PARTIAL',
    'collectedBy': 'Admin',
  };
  Map<String, dynamic> ledger(Map<String, dynamic> p) => {
    'studentId': p['studentId'],
    'month': p['month'],
    'feeIdentity': p['feeIdentity'],
    'expectedAmount': p['expectedAmount'],
    'totalPaid': p['totalPaid'],
    'balance': p['balance'],
    'lastPaymentId': p['paymentId'],
  };
  Future<void> save(
    Map<String, dynamic> p, {
    double previous = 0,
    Uint8List? bytes,
  }) => WindowsBackendBridge.collectFeePayment(
    profileId: db.activeProfileId,
    paymentId: p['paymentId'],
    payment: p,
    ledgerId: 'ledger-S1',
    ledger: ledger(p),
    previousPaid: previous,
    pdfBytes: bytes ?? pdf,
  );

  test('record-only Save commits fee and ledger without queued PDF', () async {
    final p = payment('record-only')..remove('receiptDocumentId');
    await WindowsBackendBridge.collectFeePayment(
      profileId: db.activeProfileId,
      paymentId: p['paymentId'] as String,
      payment: p,
      ledgerId: 'ledger-S1',
      ledger: ledger(p),
      previousPaid: 0,
    );
    expect((await db.collection('fee_payments').doc('record-only').get())
        .data()?['totalPaid'], 100);
    expect((await db.collection('fee_ledger').doc('ledger-S1').get())
        .data()?['lastPaymentId'], 'record-only');
    expect((await db.collection('_local_student_documents').get()).docs,
        isEmpty);
    expect((await db.collection('_windows_document_outbox').get()).docs,
        isEmpty);
    await WindowsBackendBridge.collectFeePayment(
      profileId: db.activeProfileId,
      paymentId: p['paymentId'] as String,
      payment: p,
      ledgerId: 'ledger-S1',
      ledger: ledger(p),
      previousPaid: 0,
    );
    expect((await db.collection('fee_payments').get()).docs
        .where((d) => d.id == 'record-only'), hasLength(1));
  });

  test('offline save atomically retains original PDF, ledger and separate verified sync queues', () async {
    final p = payment('one');
    await save(p);
    expect(
      (await db.collection('fee_payments').doc('one').get())
          .data()?['totalPaid'],
      100,
    );
    expect(
      (await db.collection('fee_ledger').doc('ledger-S1').get())
          .data()?['balance'],
      100,
    );
    final receipt =
        (await db.collection('_local_student_documents').doc('FEE-one').get())
            .data()!;
    expect(await File(receipt['originalPath']).readAsBytes(), pdf);
    expect(receipt['optimizedPath'], receipt['originalPath']);
    expect(receipt['documentKind'], 'feeReceipt');
    expect(
      (await db.collection('_windows_document_outbox').doc('FEE-one').get())
          .exists,
      true,
    );
    final queued = (await db.collection('_windows_firebase_outbox').get()).docs;
    expect(
      queued.where((d) => d.data()['collection'] == 'fee_payments'),
      hasLength(1),
    );
    expect(
      queued.where((d) => d.data()['collection'] == 'fee_ledger'),
      hasLength(1),
    );
    // The new TEST owner must see the ORIGINAL queues from the existing
    // Collect Payment Save, never a newly invented finance queue.
    final originalPay=queued.singleWhere(
      (d)=>d.data()['collection']=='fee_payments').data();
    final originalLedger=queued.singleWhere(
      (d)=>d.data()['collection']=='fee_ledger').data();
    final originalPdf=(await db.collection('_windows_document_outbox')
      .doc('FEE-one').get()).data()!;
    expect(WindowsAtomicFinancialCoordinator.matchesFee(
      school,originalPay,originalLedger,originalPdf),isTrue,
      reason:'Existing offline fee Save must admit one original atomic triple');
    expect((await db.collection('fee_payments').doc('one').get()).data()!.containsKey('pdfBase64'), false);
    expect(await WindowsFeeReceiptPreview.bytes(p), pdf);
    await save(p);
    expect((await db.collection('fee_payments').get()).docs, hasLength(1));
    expect(
      (await db.collection('_local_student_documents').get()).docs,
      hasLength(1),
    );
    await expectLater(save({...p, 'paymentMode': 'UPI'}), throwsStateError);
    final profile = db.activeProfileId;
    await db.switchProfile(
      'other-fee-${DateTime.now().microsecondsSinceEpoch}',
    );
    await expectLater(WindowsFeeReceiptPreview.bytes(p), throwsStateError);
    await db.switchProfile(
      profile,
      identity: {'schoolSyncId': school, 'schoolId': school},
    );
    expect(await WindowsFeeReceiptPreview.bytes(p), pdf);
    await save(payment('two', previous: 100), previous: 100);
    expect((await db.collection('fee_payments').get()).docs, hasLength(2));
    expect(
      (await db.collection('fee_ledger').doc('ledger-S1').get())
          .data()?['totalPaid'],
      200,
    );
    await expectLater(save(payment('stale')), throwsStateError);
    expect((await db.collection('fee_payments').get()).docs, hasLength(2));
  });

  test(
    'invalid PDF or non-finite money cannot commit a payment or balance',
    () async {
      await expectLater(
        save(payment('bad-pdf'), bytes: Uint8List.fromList([1, 2, 3])),
        throwsStateError,
      );
      expect((await db.collection('fee_payments').get()).docs, isEmpty);
      expect((await db.collection('fee_ledger').get()).docs, isEmpty);
      expect(
        (await db.collection('_windows_document_outbox').get()).docs,
        isEmpty,
      );
      await expectLater(
        save({...payment('nan'), 'installmentAmount': double.nan}),
        throwsStateError,
      );
    },
  );

  test(
    'storage owner rejects a stale financial read before any batch mutation',
    () async {
      final ref = db.collection('fee_ledger').doc('cas');
      await ref.set({'totalPaid': 0});
      final before = (await ref.get()).data();
      final batch = db.batch();
      batch.requireUnchanged(ref, before);
      batch.set(ref, {'totalPaid': 100});
      batch.set(db.collection('fee_payments').doc('must-not-commit'), {
        'amount': 100,
      });
      await ref.update({'totalPaid': 50});
      await expectLater(batch.commit(), throwsStateError);
      expect((await ref.get()).data()?['totalPaid'], 50);
      expect(
        (await db.collection('fee_payments').doc('must-not-commit').get())
            .exists,
        false,
      );
    },
  );

  test('receipt upload retains payment until its independent record ACK', () async {
    await save(payment('sync'));
    var sends = 0;
    await WindowsBackendBridge.flushDocumentPending(send: (payload) async {
      sends++;
      expect(payload['documentId'], 'FEE-sync');
      expect(base64Decode(payload['fileBase64']), pdf);
      expect(payload['documentKind'], 'feeReceipt');
      return {
        'success': true, 'cloudVerified': true, 'schoolId': school,
        'fileUrl': 'https://drive.google.com/file/d/fixture-receipt/view',
        'document': {...payload, 'id': payload['documentId'],
          '_syncRevision': 'fixture-receipt-revision', 'uploadedAt': 1793232000000},
      };
    });
    expect(sends, 1);
    expect((await db.collection('_windows_document_outbox').get()).docs, isEmpty);
    expect((await db.collection('_local_student_documents').doc('FEE-sync').get()).data()?['syncState'], 'Synced');
    expect((await db.collection('_windows_firebase_outbox').get()).docs
      .where((d) => d.data()['collection'] == 'fee_payments'), hasLength(1));
  });

  testWidgets(
    'history opens its shell immediately and reads local payments without cloud navigation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() => save(payment('history')));
      await tester.pumpWidget(
        const MaterialApp(home: FeeTransactionHistoryScreen()),
      );
      expect(find.text('Transaction History'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      for (var i = 0; i < 100; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump(const Duration(milliseconds: 100));
        if (find.text('Student One').evaluate().isNotEmpty) break;
      }
      expect(find.text('Student One'), findsOneWidget);
      expect(find.text('Receipt'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('unpaid list is a read-only filter: any partial/full payment hides student', () {
    expect(showInUnpaidStudentList(null), true);
    expect(showInUnpaidStudentList({'totalPaid':0,'status':'DUE'}), true);
    expect(showInUnpaidStudentList({'totalPaid':50,'status':'PARTIAL'}), false);
    expect(showInUnpaidStudentList({'totalPaid':200,'status':'PAID'}), false);
    expect(showInUnpaidStudentList({'totalPaid':'0','lastPaymentId':'paid-first'}), false);
    expect(showInUnpaidStudentList({'status':'PARTIAL PAID'}), false);
  });

  testWidgets('three equal-height viewport panels; unpaid queue updates but WhatsApp receipt remains', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1649, 875));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await db.collection('students_directory').doc('S2').set({
        'schoolId':school,'name':'Student Two','class':'Class 1','rollNo':'2',
      });
    });
    await tester.pumpWidget(const MaterialApp(home: FeesCollectionScreen()));
    Future<void> flush() async {
      for (var i = 0; i < 30; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds:20)));
        await tester.pump(const Duration(milliseconds:60));
      }
    }
    await flush();
    final left=find.byKey(const ValueKey('fees-unpaid-panel'));
    final middle=find.byKey(const ValueKey('fees-structure-panel'));
    final right=find.byKey(const ValueKey('fees-payment-panel'));
    expect(left,findsOneWidget);
    expect(middle,findsOneWidget);
    expect(right,findsOneWidget);
    expect(tester.getSize(left).height,tester.getSize(middle).height);
    expect(tester.getSize(middle).height,tester.getSize(right).height);
    expect(find.byKey(const ValueKey('fees-unpaid-student-list')),findsOneWidget);
    expect(find.byKey(const ValueKey('fees-student-S1')),findsOneWidget);
    expect(find.byKey(const ValueKey('fees-student-S2')),findsOneWidget);
    expect(find.text('WhatsApp Receipt'),findsOneWidget);
    expect(find.text('Preview Receipt'),findsOneWidget);
    expect(tester.takeException(),isNull);

    // This is just a local ledger stream update. It must not create/remove
    // records, auto-sync payments or hide the existing receipt controls.
    await tester.runAsync(() async {
      await db.collection('fee_ledger').doc('partial-S1').set({
        'month':'${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2,'0')}',
        'studentId':'S1','studentName':'Student One',
        'rollNo':'1','parentContact':'','totalPaid':50.0,
        'expectedAmount':200.0,'status':'PARTIAL',
        'lastPaymentId':'receipt-for-S1',
      });
    });
    await flush();
    expect(find.byKey(const ValueKey('fees-student-S1')),findsNothing);
    expect(find.byKey(const ValueKey('fees-student-S2')),findsOneWidget);
    // Keep the existing not-yet-paid queue intact; partial installments are
    // selectable from their own tab on the same screen.
    expect(find.text('Partial (1)'), findsNothing);
    expect(find.text('Not paid (1)'), findsNothing);
    await tester.tap(find.text('Partial Paid'));
    await flush();
    expect(find.byKey(const ValueKey('fees-student-S1')), findsOneWidget);
    await tester.tap(find.text('Due'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fees-student-S1')), findsNothing);
    expect(find.byKey(const ValueKey('fees-student-S2')), findsOneWidget);
    expect(find.text('WhatsApp Receipt'),findsOneWidget);
    expect(tester.takeException(),isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('list selection works without search and a new name clears previous roll/class', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.runAsync(() async {
      await db.collection('students_directory').doc('S2').set({
        'schoolId': school, 'name': 'Student Two', 'class': 'Class 2', 'rollNo': '22',
      });
      final session = await WindowsFeeStructure.currentSession();
      await db.collection('fee_settings').doc(WindowsFeeStructure.documentId('Class 1', session)).set({'academicSession': session, 'fees': {'Tuition': 100}});
      await db.collection('fee_settings').doc(WindowsFeeStructure.documentId('Class 2', session)).set({'academicSession': session, 'fees': {'Admission': 200}});
      expect((await WindowsFeeStructure.load('Class 2'))['fees'], {'Admission': 200});
    });
    await tester.pumpWidget(const MaterialApp(home: FeesCollectionScreen()));
    Future<void> flush() async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }
    await flush();
    final row = find.byKey(const ValueKey('fees-student-S1'));
    await tester.ensureVisible(row);
    await tester.tap(row);
    await flush();
    expect(find.byKey(const ValueKey('fees-class-All Classes')), findsOneWidget);
    expect(find.byKey(const ValueKey('fees-avatar-S1')), findsOneWidget);
    expect(tester.widget<WindowsPersonAvatar>(find.byKey(const ValueKey('fees-avatar-S1'))).person['name'], 'Student One');
    await tester.enterText(find.byKey(const ValueKey('fees-name-search')), 'Student Two');
    await flush();
    expect(find.byKey(const ValueKey('fees-class-All Classes')), findsOneWidget);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('fees-roll-search'))).controller!.text, isEmpty);
    final second = find.byKey(const ValueKey('fees-student-S2'));
    await tester.ensureVisible(second);
    await tester.tap(second);
    await flush();
    expect(find.byKey(const ValueKey('fees-class-All Classes')), findsOneWidget);
    expect(find.byKey(const ValueKey('fees-avatar-S2')), findsOneWidget);
    final selectAll = find.byType(Checkbox).first;
    await tester.ensureVisible(selectAll);
    for (var i = 0; i < 100 && tester.widget<Checkbox>(selectAll).onChanged == null; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.widget<Checkbox>(selectAll).onChanged, isNotNull, reason: tester.allWidgets.whereType<Text>().map((w) => w.data).join(' | '));
    await tester.tap(selectAll);
    await tester.pump();
    expect(tester.widget<Checkbox>(selectAll).value, isTrue);
    final collect = find.text('Collect Payment');
    await tester.ensureVisible(collect);
    expect(tester.widget<ElevatedButton>(find.ancestor(of: collect, matching: find.byType(ElevatedButton))).onPressed, isNotNull);
    await tester.tap(collect);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('Student Two?'), findsOneWidget, reason: tester.allWidgets.whereType<Text>().map((w) => w.data).join(' | '));
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final payments = await tester.runAsync(() => db.collection('fee_payments').get());
    expect(payments!.docs, isEmpty);
    final unchanged = await tester.runAsync(() => db.collection('students_directory').doc('S2').get());
    expect(unchanged!.data()?['mobileStableId'], isNull, reason: 'Cancel must not mutate student identity');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test('historical fee sessions and fraction-of-paise inputs are guarded', () async {
    final earlier = await WindowsFeeStructure.sessionForMonth('2025-04');
    final later = await WindowsFeeStructure.sessionForMonth('2026-04');
    expect(earlier, isNot(later));
    await expectLater(WindowsFeeStructure.sessionForMonth('2026-13'),
      throwsFormatException);
    await expectLater(WindowsFeeStructure.save('Class 1', later,
      {'Tuition': 100.005}), throwsArgumentError);
  });

  test('record-only fee ledger refuses payment from another student generation', () async {
    final first = payment('person-first')..['personId'] = 'p-original';
    await WindowsBackendBridge.collectFeePayment(
      profileId: db.activeProfileId, paymentId: first['paymentId'] as String,
      payment: first, ledgerId: 'ledger-S1',
      ledger: {...ledger(first), 'personId': 'p-original'},
      previousPaid: 0,
    );
    final wrong = payment('person-second', previous: 100)
      ..['personId'] = 'p-different';
    await expectLater(WindowsBackendBridge.collectFeePayment(
      profileId: db.activeProfileId, paymentId: wrong['paymentId'] as String,
      payment: wrong, ledgerId: 'ledger-S1',
      ledger: {...ledger(wrong), 'personId': 'p-different'},
      previousPaid: 100,
    ), throwsStateError);
    expect((await db.collection('fee_payments').get()).docs, hasLength(1));
    expect((await db.collection('fee_ledger').doc('ledger-S1').get())
        .data()?['personId'], 'p-original');
  });

  Future<void> settleReceipt(WidgetTester tester) async {
    for (var i = 0; i < 120; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
      if (find.byType(Image).evaluate().isNotEmpty ||
          find.text('Document unavailable.').evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
  }

  void installPrintMock() {
    final original = PrintingPlatform.instance;
    PrintingPlatform.instance = ReportPreviewPrinting();
    addTearDown(() => PrintingPlatform.instance = original);
  }

  testWidgets('record-only receipt opens one common print preview and uses current template',
      (tester) async {
    installPrintMock();
    await tester.binding.setSurfaceSize(const Size(1160, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final p = payment('preview-payment')..remove('receiptDocumentId');
    p['feeItems'] = {'Tuition': 200.0};
    p['receiptTemplateSelection'] = 'imported:stale-removed-template';
    await tester.runAsync(() => db.collection('school_settings')
        .doc('document_templates').set({'receipt': 0}));
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) =>
      Scaffold(body: TextButton(
        onPressed: () => WindowsFeeReceiptPreview.open(context, p),
        child: const Text('Open saved receipt'),
      )),
    )));
    await tester.runAsync(() async {
      await tester.tap(find.text('Open saved receipt'));
      await tester.pump();
    });
    await settleReceipt(tester);
    expect(find.byType(WindowsReceiptPrintDialog), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Document unavailable.'), findsNothing);
    expect(find.text('Print Receipt'), findsNothing);
    expect(find.text('Download PDF'), findsNothing);
    final preview = tester.widget<FittedDocumentPreview>(find.byType(FittedDocumentPreview));
    expect(String.fromCharCodes(preview.bytes.take(5)), '%PDF-');
    expect(tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save as PDF')).onPressed, isNotNull);
    expect(p['receiptTemplateSelection'], 'imported:stale-removed-template');
    final outbox = await tester.runAsync(() => db.collection('_windows_document_outbox').get());
    final localDocs = await tester.runAsync(() => db.collection('_local_student_documents').get());
    expect(outbox!.docs, isEmpty);
    expect(localDocs!.docs, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('historical receipt opens the exact retained PDF directly without new writes',
      (tester) async {
    installPrintMock();
    await tester.binding.setSurfaceSize(const Size(1160, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final p = payment('original-preview');
    final counts = await tester.runAsync(() async {
      await save(p);
      return [
        (await db.collection('_windows_document_outbox').get()).docs.length,
        (await db.collection('_local_student_documents').get()).docs.length,
      ];
    });
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) =>
      Scaffold(body: TextButton(
        onPressed: () => WindowsFeeReceiptPreview.open(context, p),
        child: const Text('Preview original receipt'),
      )),
    )));
    await tester.runAsync(() async {
      await tester.tap(find.text('Preview original receipt'));
      await tester.pump();
    });
    await settleReceipt(tester);
    expect(find.byType(WindowsReceiptPrintDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Document unavailable.'), findsNothing);
    final preview = tester.widget<FittedDocumentPreview>(find.byType(FittedDocumentPreview));
    expect(preview.bytes, orderedEquals(pdf));
    expect(tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save as PDF')).onPressed, isNotNull);
    final outbox = await tester.runAsync(() => db.collection('_windows_document_outbox').get());
    final localDocs = await tester.runAsync(() => db.collection('_local_student_documents').get());
    expect(outbox!.docs.length, counts![0]);
    expect(localDocs!.docs.length, counts[1]);
    expect(tester.takeException(), isNull);
  });

}

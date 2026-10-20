import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_analytics_identity.dart';
import '../lib/windows_staff_payroll.dart';
import '../lib/windows_local_firestore.dart' as local;
import '../lib/windows_runtime_flags.dart';
import '../lib/main_dashboard_screen_windows.dart';
import '../lib/windows_ui_localization.dart' as ui;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = local.FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    ui.WindowsUiLanguage.change('en');
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile('financial-audit-${DateTime.now().microsecondsSinceEpoch}');
  });
  test('distinct student identities sharing name and class remain separate; duplicate immutable identity counts once', () {
    final records = [
      {'name': 'Synthetic Name', 'class': 'Class 1', 'uniqueStudentId': 'student-A', '_analyticsDocId': 'a'},
      {'name': 'Synthetic Name', 'class': 'Class 1', 'uniqueStudentId': 'student-B', '_analyticsDocId': 'b'},
      {'name': 'Renamed pupil', 'class': 'Class 2', 'uniqueStudentId': 'student-A', '_analyticsDocId': 'c'},
      {'name': 'Synthetic Name', 'class': 'Class 1', 'uniqueStudentId': 'student-a', '_analyticsDocId': 'd'},
    ];
    expect(windowsAnalyticsUniqueStudents(records), hasLength(3));
    expect(records, hasLength(4), reason: 'Analytics does not delete duplicate records');
    expect(windowsAnalyticsUniqueStudents([
      {'name': 'No identity'}, {'name': 'No identity'},
    ]), hasLength(2), reason: 'Matching names are not identity evidence');
  });
  test('salary payment retry with changed details is rejected without altering history or balances', () async {
    final origin = db.activeProfileId;
    await db.collection('teachers_directory').doc('teacher').set({'name': 'Synthetic Teacher', 'teacherId': 'T-1'});
    final person = (await StaffPayroll.staff(origin)).single;
    final salary = await StaffPayroll.save(origin, person, '2026-11', basic: 100000);
    final id = salary['id'] as String;
    Future<void> pay({int amount = 20000, DateTime? date, String mode = 'Cash', String reference = 'paid'}) =>
      StaffPayroll.recordPayment(origin, id, amount, paymentId: 'original-payment',
        date: date ?? DateTime(2026, 11, 1), mode: mode, reference: reference);
    await pay();
    final original = jsonEncode((await db.collection('teacher_salary').doc(id).get()).data());
    await pay();
    for (final conflicting in [
      () => pay(amount: 25000), () => pay(date: DateTime(2026, 11, 2)),
      () => pay(mode: 'UPI'), () => pay(reference: 'changed'),
    ]) {
      await expectLater(conflicting(), throwsStateError);
      expect(jsonEncode((await db.collection('teacher_salary').doc(id).get()).data()), original);
    }
    final saved = (await db.collection('teacher_salary').doc(id).get()).data()!;
    expect(saved['paidPaise'], 20000); expect(saved['balancePaise'], 80000);
    expect(saved['payments'], hasLength(1));
    await db.switchProfile('foreign-${DateTime.now().microsecondsSinceEpoch}');
    await expectLater(pay(), throwsStateError);
    expect((await db.collection('teacher_salary').get()).docs, isEmpty);
  });
  testWidgets('an analytics page retained after school switch hides the earlier school metrics', (tester) async {
    final screenKey = GlobalKey();
    await tester.pumpWidget(MaterialApp(home: AdminAnalyticsScreen(key: screenKey)));
    await tester.runAsync(() => db.switchProfile('analytics-other-${DateTime.now().microsecondsSinceEpoch}'));
    await tester.pumpWidget(MaterialApp(home: AdminAnalyticsScreen(key: screenKey)));
    await tester.pump();
    expect(find.text('School changed. Reopen analytics.'), findsOneWidget);
    expect(find.text('Total Students'), findsNothing);
    expect(find.text('Total Student Fees Collection'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('expenses display local data before a remote refresh finishes', (tester) async {
    await tester.runAsync(() => db.collection('school_expenses').doc('cached').set({
      'title': 'Cached school stationery', 'amount': 125, 'timestamp': 1,
    }));
    final response = Completer<Map<String, dynamic>>();
    await tester.pumpWidget(MaterialApp(home: WindowsSchoolExpensesScreen(call: (_) => response.future)));
    await settleExpenseIo(tester);
    expect(find.text('Cached school stationery'), findsOneWidget);
    response.completeError(StateError('Synthetic offline refresh'));
    await settleExpenseIo(tester);
    expect(find.text('Cached school stationery'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('expense dialog retries an uncertain save with the same intent and rejects edited retry', (tester) async {
    final requests = <Map<String, dynamic>>[];
    await tester.binding.setSurfaceSize(const Size(1100, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: WindowsSchoolExpensesScreen(call: (body) async {
      if (body['action'] == 'list_school_expenses') return {'success': true, 'expenses': const []};
      requests.add(Map<String, dynamic>.from(body));
      if (requests.length == 1) throw StateError('Synthetic uncertain response');
      return {'success': true};
    })));
    await settleExpenseIo(tester);
    await tester.tap(find.text('Add Expense')); await settleExpenseIo(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Expense Title'), 'Synthetic stationery');
    await tester.enterText(find.widgetWithText(TextField, 'Amount ₹'), '120.50');
    await tester.tap(find.text('Save Expense')); await settleExpenseIo(tester);
    expect(requests, hasLength(1));
    await tester.enterText(find.widgetWithText(TextField, 'Amount ₹'), '150');
    await tester.tap(find.text('Save Expense')); await settleExpenseIo(tester);
    expect(requests, hasLength(1), reason: 'Changed retry must never overwrite an uncertain original expense');
    await tester.enterText(find.widgetWithText(TextField, 'Amount ₹'), '120.50');
    await tester.tap(find.text('Save Expense')); await settleExpenseIo(tester);
    expect(requests, hasLength(2));
    expect(requests[1], requests[0]);
    expect(find.text('Add School Expense'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('expense page rejects previous-school list response after a school switch', (tester) async {
    final screenKey = GlobalKey();
    await tester.pumpWidget(MaterialApp(home: WindowsSchoolExpensesScreen(key: screenKey,
      call: (_) async => {'success': true, 'expenses': [{'expenseId':'legacy-id', 'title':'Earlier school private expense', 'amount':120}]})));
    await settleExpenseIo(tester);
    await tester.runAsync(() => db.switchProfile('expense-other-${DateTime.now().microsecondsSinceEpoch}'));
    await tester.pumpWidget(MaterialApp(home: WindowsSchoolExpensesScreen(key: screenKey,
      call: (_) async => {'success': true, 'expenses': const []})));
    await tester.pump();
    expect(find.text('School changed. Reopen expenses.'), findsOneWidget);
    expect(find.text('Earlier school private expense'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

}

// Local reads inspect device persistence flags through real file I/O. Let that
// finish while still advancing widget animations with the test clock.
Future<void> settleExpenseIo(WidgetTester tester) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 100));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

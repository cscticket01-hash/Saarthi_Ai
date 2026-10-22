import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_expense_intent.dart';
import '../lib/windows_expense_history.dart';
import '../lib/windows_exam_history_records.dart';
import 'dart:convert';

void main() {
  test('exam history scopes sessions, search, results and deleted rows', () {
    final rows = <Map<String, dynamic>>[
      {
        'schoolId': 'A',
        'examId': 'old',
        'examName': 'Final',
        'academicSession': '2025-26',
        'timestamp': 10,
      },
      {
        'schoolId': 'A',
        'examId': 'new',
        'examName': 'Unit Test',
        'studentClass': 'Class 2',
        'timestamp': 20,
      },
      {'schoolId': 'B', 'examId': 'foreign', 'timestamp': 30},
      {'schoolId': 'A', 'examId': 'deleted', '_syncDeleted': true},
      {'examId': 'legacy', 'timestamp': 5},
    ];
    final history = windowsExamHistoryRecords(rows, schoolId: 'A');
    expect(history.map((row) => row['examId']), ['new', 'old', 'legacy']);
    expect(
      windowsExamHistoryRecords(
        rows,
        schoolId: 'A',
        session: '2025-26',
      ).single['examId'],
      'old',
    );
    expect(
      windowsExamHistoryRecords(
        rows,
        schoolId: 'A',
        query: 'CLASS 2',
      ).single['examId'],
      'new',
    );
    history.first['examName'] = 'changed';
    expect(rows[1]['examName'], 'Unit Test');
    final results = <Map<String, dynamic>>[
      {'schoolId': 'A', 'examId': 'old', 'studentName': 'Own'},
      {'schoolId': 'B', 'examId': 'old', 'studentName': 'Foreign'},
      {'schoolId': 'A', 'examId': 'new', 'studentName': 'Other exam'},
      {'schoolId': 'A', 'examId': 'old', 'deleted': true},
    ];
    expect(
      windowsExamHistoryResults(
        results,
        schoolId: 'A',
        examId: 'old',
      ).single['studentName'],
      'Own',
    );
    expect(
      windowsExamHistoryResults(results, schoolId: 'A', examId: ''),
      isEmpty,
    );
  });
  test(
    'expense history keeps only active-school records, orders dates and never mutates the ledger',
    () {
      final rows = <Map<String, dynamic>>[
        {
          'expenseId': 'older',
          'schoolId': 'A',
          'title': 'Electricity',
          'amount': 100,
          'dateText': '2026-10-20',
        },
        {
          'expenseId': 'newer',
          'schoolId': 'A',
          'title': 'Stationery',
          'amount': 50,
          'timestamp': DateTime(2026, 10, 22).millisecondsSinceEpoch,
        },
        {
          'expenseId': 'legacy',
          'title': 'Local transport',
          'dateText': '21/10/2026',
        },
        {
          'expenseId': 'foreign',
          'schoolId': 'B',
          'title': 'Stationery',
          'timestamp': DateTime(2026, 10, 23).millisecondsSinceEpoch,
        },
        {'expenseId': 'deleted', 'schoolId': 'A', 'deleted': true},
        {'expenseId': 'tombstone', 'schoolId': 'A', '_syncDeleted': true},
      ];
      final before = jsonEncode(rows);
      final visible = windowsExpenseHistory(rows, schoolId: 'A');
      expect(visible.map((row) => row['expenseId']), [
        'newer',
        'legacy',
        'older',
      ]);
      visible.first['amount'] = 999;
      expect(jsonEncode(rows), before);
      expect(
        windowsExpenseHistory(
          rows,
          schoolId: 'B',
        ).map((row) => row['expenseId']),
        ['foreign', 'legacy'],
      );
    },
  );
  test(
    'expense history searches saved fields without exposing another school',
    () {
      final rows = <Map<String, dynamic>>[
        {
          'expenseId': 'own',
          'schoolId': 'A',
          'title': 'Paper',
          'category': 'Stationery',
          'paidTo': 'Local Shop',
          'note': 'Annual exam',
          'amount': 125,
          'dateText': '2026-10-22',
        },
        {'expenseId': 'foreign', 'schoolId': 'B', 'title': 'Paper'},
      ];
      for (final query in [
        ' paper ',
        'STATIONERY',
        'shop',
        'annual',
        '2026-10-22',
        '125',
      ]) {
        expect(
          windowsExpenseHistory(
            rows,
            schoolId: 'A',
            query: query,
          ).single['expenseId'],
          'own',
        );
      }
      expect(
        windowsExpenseHistory(rows, schoolId: 'A', query: 'no match'),
        isEmpty,
      );
    },
  );

  test(
    'uncertain response retry retains original expense identity, timestamp and exact details',
    () {
      final at = DateTime(2026, 11, 5, 13, 25);
      final intent = WindowsExpenseIntent(createdAt: at);
      Map<String, dynamic> submit({
        String title = 'Stationery',
        double amount = 120.50,
        String category = 'General',
        String note = 'Original',
      }) => intent.prepare(
        title: title,
        category: category,
        amount: amount,
        paidTo: 'Synthetic vendor',
        note: note,
      );
      final first = submit();
      first['expenseId'] = 'mutated-return-copy';
      final retry = submit();
      expect(retry['expenseId'], intent.expenseId);
      expect(retry['timestamp'], at.millisecondsSinceEpoch);
      expect(retry['dateText'], '2026-11-05');
      for (final changed in [
        () => submit(amount: 150),
        () => submit(title: 'Correction'),
        () => submit(category: 'Transport'),
        () => submit(note: 'Changed'),
      ])
        expect(changed, throwsStateError);
      expect(
        submit(),
        retry,
        reason: 'Changed retry never mutates the original intent',
      );
    },
  );
  test(
    'separate dialogs created at the same instant have different secure UUID identities',
    () {
      final at = DateTime(2026, 11, 5);
      final ids = List.generate(
        100,
        (_) => WindowsExpenseIntent(createdAt: at).expenseId,
      );
      expect(ids.toSet(), hasLength(100));
      for (final id in ids) {
        expect(
          RegExp(
            r'^EXP-[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
          ).hasMatch(id),
          true,
        );
      }
    },
  );
  test('invalid or non-finite expense values do not bind an intent', () {
    final intent = WindowsExpenseIntent();
    for (final invalid in [0.0, -1.0, double.nan, double.infinity]) {
      expect(
        () => intent.prepare(
          title: 'Synthetic',
          category: 'General',
          amount: invalid,
          paidTo: '',
          note: '',
        ),
        throwsArgumentError,
      );
    }
    expect(
      intent.prepare(
        title: 'Synthetic',
        category: 'General',
        amount: 1,
        paidTo: '',
        note: '',
      )['amount'],
      1,
    );
  });
}

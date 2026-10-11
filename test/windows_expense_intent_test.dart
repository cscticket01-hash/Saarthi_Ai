import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_expense_intent.dart';

void main() {
  test('uncertain response retry retains original expense identity, timestamp and exact details', () {
    final at = DateTime(2026, 11, 5, 13, 25);
    final intent = WindowsExpenseIntent(createdAt: at);
    Map<String, dynamic> submit({String title = 'Stationery', double amount = 120.50,
        String category = 'General', String note = 'Original'}) => intent.prepare(
      title: title, category: category, amount: amount, paidTo: 'Synthetic vendor', note: note);
    final first = submit();
    first['expenseId'] = 'mutated-return-copy';
    final retry = submit();
    expect(retry['expenseId'], intent.expenseId);
    expect(retry['timestamp'], at.millisecondsSinceEpoch);
    expect(retry['dateText'], '2026-11-05');
    for (final changed in [
      () => submit(amount: 150), () => submit(title: 'Correction'),
      () => submit(category: 'Transport'), () => submit(note: 'Changed'),
    ]) expect(changed, throwsStateError);
    expect(submit(), retry, reason: 'Changed retry never mutates the original intent');
  });
  test('separate dialogs created at the same instant have different secure UUID identities', () {
    final at = DateTime(2026, 11, 5);
    final ids = List.generate(100, (_) => WindowsExpenseIntent(createdAt: at).expenseId);
    expect(ids.toSet(), hasLength(100));
    for (final id in ids) {
      expect(RegExp(r'^EXP-[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$').hasMatch(id), true);
    }
  });
  test('invalid or non-finite expense values do not bind an intent', () {
    final intent = WindowsExpenseIntent();
    for (final invalid in [0.0, -1.0, double.nan, double.infinity]) {
      expect(() => intent.prepare(title: 'Synthetic', category: 'General', amount: invalid,
        paidTo: '', note: ''), throwsArgumentError);
    }
    expect(intent.prepare(title: 'Synthetic', category: 'General', amount: 1,
      paidTo: '', note: '')['amount'], 1);
  });
}

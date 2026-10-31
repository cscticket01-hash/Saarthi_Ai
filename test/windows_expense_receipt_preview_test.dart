import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_expense_receipt_preview.dart';

void main() {
  test('saved school expense renders an independent PDF without mutating its row',() async {
    final original = <String,dynamic>{
      'expenseId':'EXP-test-1', 'title':'School Furniture',
      'amount':2000.0,'category':'Stationery','paidTo':'ML Das',
      'dateText':'2026-10-31','note':'Payment hogaya Cash',
    };
    final before=jsonEncode(original);
    final bytes=await WindowsExpenseReceiptPreview.bytes(original);
    expect(bytes,hasLength(greaterThan(200)));
    expect(String.fromCharCodes(bytes.take(5)),'%PDF-');
    expect(jsonEncode(original),before);
  });
  test('unsafe/invalid money never generates a printable expense', () async {
    for (final invalid in [double.nan,-50.0,0, 'not-a-number']) {
      await expectLater(
        WindowsExpenseReceiptPreview.bytes({'amount':invalid,'title':'Bad'}),
        throwsStateError,
      );
    }
  });
}

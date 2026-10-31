import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';

import '../lib/windows_expense_intent.dart';
import '../lib/windows_school_expense_sync.dart';

void main() {
  test('expense save projects only one immutable school-owned delta', () {
    final intent=WindowsExpenseIntent(createdAt:DateTime(2026,10,31,8));
    final payload=intent.prepare(
      title:'Stationery',
      category:'Stationery',
      amount:2000,
      paidTo:'Vendor',
      note:'Paid in cash');
    final record=WindowsSchoolExpenseSync.recordForSchool(
      'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',payload);
    expect(record['expenseId'],intent.expenseId);
    expect(record['schoolId'],'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
    expect(record['amount'],2000);
    expect(record['timestamp'],DateTime(2026,10,31,8).millisecondsSinceEpoch);
    expect(record.containsKey('action'),false);
    expect(jsonEncode(WindowsSchoolExpenseSync.recordForSchool(
      'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',intent.prepare(
        title:'Stationery',category:'Stationery',amount:2000,
        paidTo:'Vendor',note:'Paid in cash'))),jsonEncode(record));
  });
  test('invalid amounts and missing school scope do not generate queued expense', () {
    final valid=WindowsExpenseIntent().prepare(
      title:'Paper',category:'Other',amount:2,paidTo:'',note:'');
    for(final row in [
      {...valid,'amount':double.nan},
      {...valid,'amount':-1.0},
      {...valid,'title':''},
      {...valid,'expenseId':''},
      {...valid,'timestamp':null},
      {...valid,'action':'delete_school_expense'},
    ]) {
      expect(()=>WindowsSchoolExpenseSync.recordForSchool(
        'vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',row),throwsStateError);
    }
    expect(()=>WindowsSchoolExpenseSync.recordForSchool('',valid),throwsStateError);
  });
}

import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_salary_reconciliation.dart';
import '../lib/windows_record_change_policy.dart';

void main(){
  const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const id='salary-a';
  const base=<String,dynamic>{'schoolId':school,'id':id,'staffId':'staff:a','month':'2026-11',
    'netPaise':2000000,'paidPaise':0,'balancePaise':2000000,'status':'Pending','_syncRevision':'r1'};
  Map<String,dynamic> payment(String key,int amount)=>{'id':key,'amountPaise':amount,'date':'2026-11-10','mode':'Cash','reference':key};
  Map<String,dynamic> row(String revision,List<Map<String,dynamic>> events){
    final paid=events.fold<int>(0,(v,e)=>v+(e['amountPaise'] as int));
    return {...base,'_syncRevision':revision,'payments':events,'paidPaise':paid,
      'balancePaise':2000000-paid,'status':paid==2000000?'Paid':paid==0?'Pending':'Part paid'};
  }
  Map<String,dynamic> queued(Map<String,dynamic> data)=>{'schoolId':school,'collection':'teacher_salary',
    'documentId':id,'operation':'set','operationId':'local-op','baseCloudRevision':'r1','syncState':'pending','retryCount':0,'data':data};
  test('distinct unsubmitted payments merge without discarding either original',(){
    final local=row('r1',[payment('a',500000)]);
    final remote=row('r2',[payment('b',700000)]);
    final merged=mergeUnsubmittedSalaryPayments(queued(local),base,remote)!;
    expect(merged['paidPaise'],1200000);
    expect(merged['balancePaise'],800000);
    expect((merged['payments'] as List).map((e)=>e['id']),['b','a']);
  });
  test('bound wire, overpayment, corrections, and different salary terms remain for review',(){
    final local=row('r1',[payment('a',500000)]);
    final remote=row('r2',[payment('b',700000)]);
    expect(mergeUnsubmittedSalaryPayments({...queued(local),'wireData':local},base,remote),isNull);
    expect(mergeUnsubmittedSalaryPayments(queued(local),base,row('r2',[payment('b',1800000)])),isNull);
    expect(mergeUnsubmittedSalaryPayments(queued(local),base,{...remote,'salaryLocked':true}),isNull);
    expect(mergeUnsubmittedSalaryPayments(queued(local),base,{...remote,'paymentCorrections':[{'id':'c'}]}),isNull);
    expect(mergeUnsubmittedSalaryPayments(queued(local),base,row('r2',[payment('a',600000)])),isNull);
  });
  test('payroll creates do not silently lose their local version',(){
    expect(firstCommittedCreateWins({...queued(row('r1',[payment('a',500000)])),
      'createIntent':true,'baseCloudRevision':''},row('r2',[payment('b',700000)])),false);
    expect(isPayrollFinancialRecord({'collection':'school_settings','documentId':'payroll_advance_a'}),true);
    expect(isPayrollFinancialRecord({'collection':'school_settings','documentId':'payroll_month_2026-11'}),true);
  });
}

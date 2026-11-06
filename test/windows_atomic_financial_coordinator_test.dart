import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_atomic_financial_coordinator.dart';

void main(){
 const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
 final p=<String,dynamic>{
   'collection':'fee_payments','schoolId':school,'operation':'set',
   'createIntent':true,'baseCloudRevision':'','priorDeletion':null,
   'documentId':'payment-001',
   'operationId':'original-financial-pay-0001',
   'data':{'schoolId':school,'studentId':'student-001',
     'paymentId':'payment-001','receiptDocumentId':'FEE-payment-001',
     'month':'2026-11','totalPaid':100.0,'expectedAmount':200.0},
 };
 final ledger=<String,dynamic>{
   'collection':'fee_ledger','schoolId':school,'operation':'set',
   'baseCloudRevision':'live-previous-ledger',
   'documentId':'ledger-student-001',
   'operationId':'original-financial-ledger-0001',
   'data':{'schoolId':school,'studentId':'student-001',
     'lastPaymentId':'payment-001','month':'2026-11',
     'totalPaid':100.0,'expectedAmount':200.0},
 };
 final doc=<String,dynamic>{
   'collection':'documents','documentId':'FEE-payment-001',
   'documentKind':'feeReceipt','schoolId':school,'studentId':'student-001',
   'ownerRole':'student','personId':'p-'+'a'*32,
   'documentRevision':'original-financial-receipt-0001',
   'contentHash':'b'*64,'baseCloudRevision':'','deleted':false,
   'optimizedMimeType':'application/pdf','optimizedPath':'/local/receipt.pdf',
 };
 test('original fee payment, ledger and receipt use existing queues',(){
   expect(WindowsAtomicFinancialCoordinator.matchesFee(school,p,ledger,doc),
     isTrue);
   final ids=[p['operationId'] as String,ledger['operationId'] as String,
     doc['documentRevision'] as String];
   expect(WindowsAtomicFinancialCoordinator.bundleId(school,ids),
     WindowsAtomicFinancialCoordinator.bundleId(school,ids));
   expect(WindowsAtomicFinancialCoordinator.uploadKey(school,ids.last),
     WindowsAtomicFinancialCoordinator.uploadKey(school,ids.last));
   expect(WindowsAtomicFinancialCoordinator.bundleId(school,ids),
     isNot(WindowsAtomicFinancialCoordinator.bundleId('vs-'+'c'*32,ids)));
 });
 test('duplicate/changed/foreign financial ownership does not enter TEST transaction',(){
   final cases=<List<Map<String,dynamic>>>[
     [{...p,'schoolId':'vs-'+'c'*32},ledger,doc],
     [p,{...ledger,'schoolId':'vs-'+'c'*32},doc],
     [p,ledger,{...doc,'schoolId':'vs-'+'c'*32}],
     [p,{...ledger,'data':{...ledger['data'],'lastPaymentId':'other'}},doc],
     [{...p,'baseCloudRevision':'live-already'},ledger,doc],
     [p,ledger,{...doc,'contentHash':'wrong'}],
     [p,ledger,{...doc,'personId':null}],
     [p,ledger,{...doc,'baseCloudRevision':'live-already'}],
     [p,ledger,{...doc,'deleted':true}],
     [p,{...ledger,'fieldPatch':{'set':{}}},doc],
     [p,{...ledger,'operationId':p['operationId']},doc],
     [p,ledger,{...doc,'atomicBundleId':'foreign-atomic-owner-001'}],
   ];
   for(final v in cases) {
     expect(WindowsAtomicFinancialCoordinator.matchesFee(school,v[0],v[1],v[2]),
       isFalse,reason:v.map((x)=>x['collection']).join('/'));
   }
 });
 test('real Exam Center result and original marksheet use one existing atomic queue pair',(){
   const examId='exam-one',studentId='student-001';
   const resultId='exam-one_student-001',documentId='SHEET-exam-one-student-001';
   final result=<String,dynamic>{
     'schoolId':school,'collection':'exam_center_results',
     'operation':'set','createIntent':true,'baseCloudRevision':'',
     'documentId':resultId,'operationId':'original-exam-result-operation-0001',
     'data':{'schoolId':school,'examId':examId,'studentId':studentId,
       'personId':'p-'+'a'*32,'marks':{'Maths':98},
       'marksheetDocumentId':documentId},
   };
   final pdf=<String,dynamic>{
     'schoolId':school,'collection':'documents','documentKind':'marksheet',
     'documentId':documentId,'examResultId':resultId,
     'studentId':studentId,'personId':'p-'+'a'*32,'ownerRole':'student',
     'documentRevision':'original-marksheet-revision-0001',
     'contentHash':'c'*64,'baseCloudRevision':'','deleted':false,
     'optimizedMimeType':'application/pdf','optimizedPath':'/school/marksheet.pdf',
   };
   expect(WindowsAtomicFinancialCoordinator.matchesExam(school,result,pdf),isTrue);
   expect(WindowsAtomicFinancialCoordinator.matchesExam(school,
     {...result,'collection':'exam_results'},pdf),isTrue,
     reason:'Old exam_results original stays compatible without a duplicate write');
   final cases=<List<Map<String,dynamic>>>[
     [{...result,'schoolId':'vs-'+'f'*32},pdf],
     [{...result,'createIntent':false},pdf],
     [{...result,'baseCloudRevision':'live-prior'},pdf],
     [{...result,'fieldPatch':{'set':{}}},pdf],
     [{...result,'documentId':'different-result'},pdf],
     [{...result,'operationId':pdf['documentRevision']},pdf],
     [{...result,'data':{...result['data'],'marksheetDocumentId':'other'}},pdf],
     [result,{...pdf,'schoolId':'vs-'+'f'*32}],
     [result,{...pdf,'studentId':'other'}],
     [result,{...pdf,'personId':'p-'+'b'*32}],
     [result,{...pdf,'examResultId':'other'}],
     [result,{...pdf,'documentKind':'feeReceipt'}],
     [result,{...pdf,'contentHash':'not-a-digest'}],
     [result,{...pdf,'baseCloudRevision':'drive-old'}],
     [result,{...pdf,'deleted':true}],
     [result,{...pdf,'optimizedMimeType':'image/png'}],
   ];
   for(final row in cases) {
     expect(WindowsAtomicFinancialCoordinator.matchesExam(school,row[0],row[1]),
       isFalse,reason:'A changed or foreign original may not enter atomic Exam Save');
   }
 });
 test('the atomic coordinator never activates in default production builds',(){
   expect(WindowsAtomicFinancialCoordinator.run('vs-'+'c'*32),
     completion(0));
 });
}

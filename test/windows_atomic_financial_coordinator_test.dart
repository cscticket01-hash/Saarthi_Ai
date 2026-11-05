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
 test('the atomic coordinator never activates in default production builds',(){
   expect(WindowsAtomicFinancialCoordinator.run('vs-'+'c'*32),
     completion(0));
 });
}

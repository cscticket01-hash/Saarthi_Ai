import 'package:flutter_test/flutter_test.dart';
import '../lib/live_sync_protocol.dart';
import '../lib/web_atomic_bundle_review.dart';

void main(){
 const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',bundle='atomic-web-person-card-0001';
 final group=<Map<String,dynamic>>[
  {'sequence':1,'collection':'students_directory','id':'person',
    'bundleId':bundle,'bundleSize':2,'bundleIndex':0,
    'record':{'schoolId':school,'mobileStableId':'p-generation',
      '_syncRevision':'live-person-one'}},
  {'sequence':2,'collection':'documents','id':'card',
    'bundleId':bundle,'bundleSize':2,'bundleIndex':1,
    'record':{'schoolId':school,'personId':'p-generation','studentId':'person',
      'ownerRole':'student','bundleId':bundle,'bundleManifestHash':'c'*64,
      'bundleMedia':[{'kind':'idCard','sha256':'d'*64}],
      '_syncRevision':'live-card-one'}},
 ];
 LiveSyncPage parse(List<Map<String,dynamic>> records)=>LiveSyncPage.parse({
  'success':true,'liveProtocol':1,'schoolId':school,
  'cursor':records.length,'head':records.length,
  'more':false,'events':records},school,0);
 test('TEST Web renders a complete same-school person/card atomically',(){
   final r=verifyWebAtomicBundles(school,[parse(group)]);
   expect(r.length,1);expect(r.single.personId,'person');
   expect(r.single.documentId,'card');expect(r.single.cardSha256,'d'*64);
 });
 test('TEST Web accepts original photo only with same person and document SHA',(){
   final withPhoto=group.map((e)=>Map<String,dynamic>.from(e)).toList();
   const photoId='f'*64,photoSha='e'*64;
   withPhoto[0]['record']={
     ...(withPhoto[0]['record'] as Map),
     'atomicPortrait':{
       'bundleId':bundle,'documentId':'card','role':'student',
       'id':photoId,'sha256':photoSha,'mime':'image/jpeg',
       'sizeBytes':4096,
     },
   };
   withPhoto[1]['record']={
     ...(withPhoto[1]['record'] as Map),
     'bundleMedia':[
       {'kind':'idCard','sha256':'d'*64},
       {'kind':'photo','id':photoId,'sha256':photoSha,
        'mime':'image/jpeg','sizeBytes':4096},
     ],
   };
   expect(verifyWebAtomicBundles(school,[parse(withPhoto)]),hasLength(1));
   final mismatch=withPhoto.map((e)=>Map<String,dynamic>.from(e)).toList();
   mismatch[1]['record']={
     ...(mismatch[1]['record'] as Map),
     'bundleMedia':[
       {'kind':'idCard','sha256':'d'*64},
       {'kind':'photo','id':photoId,'sha256':'a'*64,
        'mime':'image/jpeg','sizeBytes':4096},
     ],
   };
   expect(()=>verifyWebAtomicBundles(school,[parse(mismatch)]),
     throwsStateError);
   final missing=withPhoto.map((e)=>Map<String,dynamic>.from(e)).toList();
   missing[1]['record']={
     ...(missing[1]['record'] as Map),
     'bundleMedia':[{'kind':'idCard','sha256':'d'*64}],
   };
   expect(()=>verifyWebAtomicBundles(school,[parse(missing)]),
     throwsStateError);
 });
 test('TEST Web never accepts partial, mismatched or foreign group',(){
   expect(()=>parse(group.sublist(0,1)),throwsStateError);
   final forged=[...group.map((e)=>Map<String,dynamic>.from(e))];
   forged[1]['record']={...(forged[1]['record'] as Map),'personId':'other'};
   expect(()=>verifyWebAtomicBundles(school,[parse(forged)]),throwsStateError);
   expect(()=>verifyWebAtomicBundles('vs-'+'b'*32,[parse(group)]),throwsStateError);
 });
 test('TEST Web financial replay keeps payment, ledger and receipt inseparable',(){
   const id='web-financial-original-payment-0001',groupId='web-financial-receipt-bundle-0001';
   final events=<Map<String,dynamic>>[
     {'sequence':1,'collection':'fee_payments','id':id,'bundleId':groupId,
       'bundleSize':3,'bundleIndex':0,
       'record':{'schoolId':school,'studentId':'student','paymentId':id,
         'receiptDocumentId':'FEE-$id','month':'2026-11',
         '_syncRevision':'live-fee-1'}},
     {'sequence':2,'collection':'fee_ledger','id':'ledger-student','bundleId':groupId,
       'bundleSize':3,'bundleIndex':1,
       'record':{'schoolId':school,'studentId':'student','lastPaymentId':id,
         'month':'2026-11','_syncRevision':'live-ledger-1'}},
     {'sequence':3,'collection':'documents','id':'FEE-$id','bundleId':groupId,
       'bundleSize':3,'bundleIndex':2,
       'record':{'schoolId':school,'studentId':'student','ownerRole':'student',
         'documentKind':'feeReceipt','contentHash':'a'*64,
         'mimeType':'application/pdf','bundleId':groupId,
         'bundleManifestHash':'b'*64,
         'bundleMedia':[{'kind':'receipt','mime':'application/pdf',
           'sizeBytes':2048,'sha256':'a'*64}],
         '_syncRevision':'live-receipt-1'}},
   ];
   LiveSyncPage page(List<Map<String,dynamic>> rows)=>LiveSyncPage.parse({
     'success':true,'liveProtocol':1,'schoolId':school,
     'cursor':rows.length,'head':rows.length,'more':false,'events':rows},school,0);
   final verified=verifyWebAtomicFinancialBundles(school,[page(events)]);
   expect(verified.length,1);
   expect(verified.single.kind,'receipt');
   expect(verified.single.documentId,'FEE-$id');
   final tampered=events.map((e)=>Map<String,dynamic>.from(e)).toList();
   tampered[1]['record']={...(tampered[1]['record'] as Map),
     'lastPaymentId':'another'};
   expect(()=>verifyWebAtomicFinancialBundles(school,[page(tampered)]),
     throwsStateError);
   final wrongHash=events.map((e)=>Map<String,dynamic>.from(e)).toList();
   wrongHash[2]['record']={...(wrongHash[2]['record'] as Map),
     'contentHash':'c'*64};
   expect(()=>verifyWebAtomicFinancialBundles(school,[page(wrongHash)]),
     throwsStateError);
 });
 test('TEST Web marksheet requires matching exam result and school',(){
   const groupId='web-exam-marksheet-bundle-0001',id='exam-result-1';
   final events=<Map<String,dynamic>>[
     {'sequence':1,'collection':'exam_results','id':id,
       'bundleId':groupId,'bundleSize':2,'bundleIndex':0,
       'record':{'schoolId':school,'studentId':'student',
         'marksheetDocumentId':'SHEET-$id','_syncRevision':'live-exam-1'}},
     {'sequence':2,'collection':'documents','id':'SHEET-$id',
       'bundleId':groupId,'bundleSize':2,'bundleIndex':1,
       'record':{'schoolId':school,'studentId':'student','ownerRole':'student',
         'documentKind':'marksheet','contentHash':'d'*64,
         'mimeType':'application/pdf','bundleId':groupId,
         'bundleManifestHash':'e'*64,
         'bundleMedia':[{'kind':'marksheet','mime':'application/pdf',
           'sizeBytes':4096,'sha256':'d'*64}],
         '_syncRevision':'live-mark-1'}},
   ];
   final page=LiveSyncPage.parse({'success':true,'liveProtocol':1,'schoolId':school,
     'cursor':2,'head':2,'more':false,'events':events},school,0);
   final verified=verifyWebAtomicFinancialBundles(school,[page]);
   expect(verified.single.kind,'marksheet');
   expect(verified.single.pdfSha256,'d'*64);
   expect(()=>verifyWebAtomicFinancialBundles('vs-'+'b'*32,[page]),
     throwsStateError);
 });

}

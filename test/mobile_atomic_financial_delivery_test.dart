import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/mobile/atomic_financial_delivery.dart';

void main(){
 const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
 const bundle='mobile-school-financial-atomic-0001',docId='FEE-001';
 final bytes=latin1.encode('%PDF-1.7\nSigned original school receipt\n%%EOF');
 final digest=sha256.convert(bytes).toString();
 final id=sha256.convert(utf8.encode(jsonEncode([school,'media-original-0001']))).toString();
 Map<String,dynamic> signed({String kind='receipt'})=> {
   'success':true,'available':true,'mobileAtomicDocument':true,
   'schoolId':school,'projectId':school,'bundleProtocol':1,
   'bundleId':bundle,'documentId':docId,'id':id,'kind':kind,
   'sha256':digest,'contentHash':digest,'mime':'application/pdf',
   'sizeBytes':bytes.length,'base64':base64Encode(bytes),
   'documentRevision':'atomic-$bundle',
 };
 test('signed original receipt preserves exact bytes, size and school owner',(){
   final result=AtomicFinancialDelivery.verify(school,'receipt',docId,signed());
   expect(result,bytes);
 });
 test('wrong school, document, kind, file hash and MIME cannot be displayed',(){
   for(final tamper in <Map<String,dynamic>>[
     {'schoolId':'vs-'+'b'*32},{'projectId':'vs-'+'b'*32},
     {'documentId':'other'},{'kind':'marksheet'},
     {'sha256':'a'*64},{'contentHash':'b'*64},
     {'mime':'text/plain'},{'sizeBytes':bytes.length+1},
     {'documentRevision':'atomic-other'},{'mobileAtomicDocument':false},
   ]){
     expect(()=>AtomicFinancialDelivery.verify(school,'receipt',docId,
       {...signed(),...tamper}),throwsStateError,
       reason:tamper.keys.join(','));
   }
   expect(()=>AtomicFinancialDelivery.verify(school,'marksheet',docId,signed()),
     throwsStateError);
 });
 test('forged PDF bytes or oversized media never bypass signed document proof',(){
   final fake=base64Encode(utf8.encode('wrong content with a footer %%EOF'));
   expect(()=>AtomicFinancialDelivery.verify(school,'receipt',docId,
     {...signed(),'base64':fake}),throwsStateError);
   expect(()=>AtomicFinancialDelivery.verify(school,'receipt',docId,
     {...signed(),'sizeBytes':30*1024+1}),throwsStateError);
   expect(()=>AtomicFinancialDelivery.verify(school,'marksheet',docId,
     {...signed(kind:'marksheet'),'sizeBytes':150*1024+1}),throwsStateError);
 });
}

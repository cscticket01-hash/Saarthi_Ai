import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/mobile/atomic_card_delivery.dart';

void main(){
 const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
 const bundle='atomic-mobile-published-card-0001';
 final bytes=latin1.encode('%PDF-1.7\nOne original school ID\n%%EOF');
 final sha=sha256.convert(bytes).toString();
 const id='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
 final pointer={'bundleId':bundle,'id':id,'sha256':sha};
 final response=<String,dynamic>{
  'success':true,'available':true,'mobileAtomicIdCard':true,
  'schoolId':school,'projectId':school,'bundleProtocol':1,
  'bundleId':bundle,'id':id,'kind':'idCard','sha256':sha,
  'contentHash':sha,'mime':'application/pdf',
  'documentRevision':'atomic-$bundle',
  'sizeBytes':bytes.length,'base64':base64Encode(bytes),
 };
 test('authenticated mobile card passes exact school, bundle and SHA proof',(){
  final parsed=AtomicCardDelivery.verify(school,pointer,response);
  expect(base64Encode(parsed),base64Encode(bytes));
 });
 test('Drive fallback needs the exact same published PDF hash and archived identity',(){
  final archive={'documentId':'same-card','documentRevision':'drive-verified',
    'contentHash':sha};
  expect(AtomicCardDelivery.canUseArchivedCard(pointer,archive),isTrue);
  expect(AtomicCardDelivery.canUseArchivedCard(pointer,
    {...archive,'contentHash':'f'*64}),isFalse);
  expect(AtomicCardDelivery.canUseArchivedCard(pointer,
    {...archive,'documentId':''}),isFalse);
  expect(AtomicCardDelivery.canUseArchivedCard(pointer,
    {...archive,'documentRevision':''}),isFalse);
  expect(AtomicCardDelivery.canUseArchivedCard(pointer,null),isFalse);
 });
 test('wrong school, broken bytes, forged ID and stale bundle all fail closed',(){
  for(final wrong in <Map<String,dynamic>>[
   {...response,'schoolId':'vs-'+'c'*32},
   {...response,'projectId':'vs-'+'c'*32},
   {...response,'id':'c'*64},
   {...response,'bundleId':'another-bundle-identity-0001'},
   {...response,'sha256':'f'*64},
   {...response,'base64':base64Encode(latin1.encode('%PDF-1.7\nEdited card\n%%EOF'))},
   {...response,'sizeBytes':bytes.length+1},
   {...response,'mime':'image/png'},
   {...response,'available':false},
  ]) {
   expect(()=>AtomicCardDelivery.verify(school,pointer,wrong),throwsStateError);
  }
 });
}

import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_connect/atomic_bundle_pilot.dart';

void main(){
 const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
 const bundle='sync3-test-outbound-bundle-0001';
 const uploadKey='sync3-outbound-card-file-0001';
 final bytes=Uint8List.fromList(latin1.encode('%PDF-1.7\nOriginal TEST PDF\n%%EOF'));
 final sha=sha256.convert(bytes).toString();
 final id=sha256.convert(utf8.encode(jsonEncode([school,uploadKey]))).toString();
 final media={'kind':'idCard','id':id,'uploadKey':uploadKey,
   'sha256':sha,'sizeBytes':bytes.length,'mime':'application/pdf'};
 final operations=<Map<String,dynamic>>[
  {'collection':'students_directory','id':'p1','operation':'write',
   'operationId':'test-outbound-person-0001','expectedRevision':'',
   'data':{'schoolId':school,'mobileStableId':'p-stable-001','name':'Pilot'}},
  {'collection':'documents','id':'card1','operation':'write',
   'operationId':'test-outbound-card-0001','expectedRevision':'',
   'data':{'schoolId':school,'studentId':'p1','personId':'p-stable-001',
     'ownerRole':'student','contentHash':sha,'documentKind':'idCard'}},
 ];
 test('stage preserves the original upload identity without waiting for Drive',()async{
  final call=<String>[];
  final proof=await AtomicBundlePilot.stage(
    school:school,kind:'idCard',name:'card.pdf',mime:'application/pdf',
    uploadKey:uploadKey,bytes:bytes,isolatedTest:true,
    request:(action,body)async{
      call.add(action);
      expect(body['base64'],base64Encode(bytes));
      expect(body['sha256'],sha);
      return {'success':true,'schoolId':school,'bundleProtocol':1,
        'mediaReady':true,'cloudflareAccepted':true,'driveVerified':false,
        'media':media};
    });
  expect(proof['id'],id);expect(call,['managed/live/bundle-stage']);
 });
 test('publish verifies two ordered record ACKs and never infers Drive completion',()async{
  final result=await AtomicBundlePilot.publish(
   school:school,bundleId:bundle,media:[media],operations:operations,
   isolatedTest:true,request:(action,body)async{
    expect(action,'managed/live/bundle-publish');
    expect(body['confirmIsolatedBundleTest'],true);
    expect(body['mediaManifestHash'],
      AtomicBundlePilot.manifest(school,bundle,[media])['mediaManifestHash']);
    return {'success':true,'schoolId':school,'bundleProtocol':1,
      'bundleId':bundle,'cloudState':'committed','mediaReady':true,
      'archiveReady':false,'backupState':'pending','acknowledgements':[
        for(final op in operations) {'operationId':op['operationId'],
          'cloudState':'committed'}]};
   });
  expect(result['archiveReady'],false);
 });
 test('default disabled, invalid PDF and wrong-school staged proof fail closed',()async{
  await expectLater(AtomicBundlePilot.stage(
    school:school,kind:'idCard',name:'card.pdf',mime:'application/pdf',
    uploadKey:uploadKey,bytes:bytes,request:(a,b)async=>{}),throwsStateError);
  await expectLater(AtomicBundlePilot.stage(
    school:school,kind:'idCard',name:'card.pdf',mime:'application/pdf',
    uploadKey:uploadKey,isolatedTest:true,bytes:Uint8List.fromList([1,2,3]),
    request:(a,b)async=>{}),throwsStateError);
  await expectLater(AtomicBundlePilot.stage(
    school:school,kind:'idCard',name:'card.pdf',mime:'application/pdf',
    uploadKey:uploadKey,isolatedTest:true,bytes:bytes,
    request:(a,b)async=>{'success':true,'schoolId':'vs-'+'b'*32,
      'bundleProtocol':1,'mediaReady':true,'cloudflareAccepted':true,
      'media':media}),throwsStateError);
 });
}

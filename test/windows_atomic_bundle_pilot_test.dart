import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/windows_connect/atomic_bundle_pilot.dart';
import '../lib/windows_atomic_person_card_coordinator.dart';

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

 test('exact immutable replay receipt keeps Cloudflare and Drive status separate',() async {
   final manifest=AtomicBundlePilot.manifest(school,bundle,[media]);
   final response={
     'success':true,'schoolId':school,'bundleProtocol':1,'found':true,
     'cloudState':'committed','mediaReady':true,'driveVerified':false,
     'receipt':{
       'schoolId':school,'bundleId':bundle,'cloudState':'committed',
       'mediaReady':true,'mediaManifestHash':manifest['mediaManifestHash'],
       'acknowledgements':[
         for(final op in operations)
          {'operationId':op['operationId'],'recordRevision':'live-123'}],
     },
     'backups':[
       for(final op in operations)
       {'operationId':op['operationId'],'collection':op['collection'],
        'id':op['id'],'recordRevision':'live-123',
        'backupState':'pending','driveVerified':false}],
   };
   final recorded=<String>[];
   final result=await AtomicBundlePilot.receipt(
     school:school,bundleId:bundle,operations:operations,media:[media],
     isolatedTest:true,request:(action,body)async{
       recorded.add(action);
       expect(body['mediaManifestHash'],manifest['mediaManifestHash']);
       return response;
     });
   expect(result['driveVerified'],false);
   expect(recorded,['managed/live/bundle-receipt']);
   final wrong={...response,'backups':[
     {...(response['backups'] as List).first as Map,'id':'foreign-card'},
     (response['backups'] as List).last,
   ]};
   await expectLater(AtomicBundlePilot.receipt(
     school:school,bundleId:bundle,operations:operations,media:[media],
     isolatedTest:true,request:(a,b)async=>wrong),throwsStateError);
   final falseDrive={...response,'driveVerified':true};
   await expectLater(AtomicBundlePilot.receipt(
     school:school,bundleId:bundle,operations:operations,media:[media],
     isolatedTest:true,request:(a,b)async=>falseDrive),throwsStateError);
 });


 test('isolated outbox selector admits only exact same-school Person + ID Card creates',(){
   final parent={'schoolId':school,'collection':'students_directory',
     'operation':'set','documentId':'student-one',
     'operationId':'original-person-operation-0001','baseCloudRevision':'',
     'syncState':'pending',
     'data':{'schoolId':school,'mobileStableId':'p-'+'8'*32}};
   final doc={'schoolId':school,'documentId':'card-one',
     'documentRevision':'original-card-revision-0001',
     'documentKind':'idCard','deleted':false,'baseCloudRevision':'',
     'ownerRole':'student','personId':'p-'+'8'*32,
     'studentId':'student-one','optimizedMimeType':'application/pdf',
     'optimizedPath':'/isolated/student-card.pdf'};
   expect(WindowsAtomicPersonCardCoordinator.matches(school,parent,doc),isTrue);
   for(final bad in <Map<String,dynamic>>[
     {...doc,'schoolId':'vs-'+'f'*32},
     {...doc,'documentKind':'feeReceipt'},
     {...doc,'personId':'p-'+'9'*32},
     {...doc,'studentId':'other'},
     {...doc,'deleted':true},
     {...doc,'baseCloudRevision':'already-in-drive'},
     {...doc,'optimizedMimeType':'image/jpeg'},
     {...doc,'optimizedPath':''},
   ]){
     expect(WindowsAtomicPersonCardCoordinator.matches(school,parent,bad),isFalse);
   }
   expect(WindowsAtomicPersonCardCoordinator.matches(school,
     {...parent,'baseCloudRevision':'existing'},doc),isFalse);
   expect(WindowsAtomicPersonCardCoordinator.matches(school,
     {...parent,'data':{...(parent['data'] as Map),
       'photoUrl':'data:image/jpeg;base64,YWJj'}},doc),isFalse,
     reason:'A portrait must not trigger hidden Drive-first upload in the atomic pilot');
   final key=WindowsAtomicPersonCardCoordinator.uploadKey(
      school,doc['documentRevision'] as String);
   final bundle=WindowsAtomicPersonCardCoordinator.bundleId(
      school,parent['operationId'] as String,doc['documentRevision'] as String);
   expect(RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(bundle),isTrue);
   expect(RegExp(r'^[A-Za-z0-9_-]{1,150}$').hasMatch(key),isTrue);
   expect(bundle,WindowsAtomicPersonCardCoordinator.bundleId(school,
     parent['operationId'] as String,doc['documentRevision'] as String));
   expect(bundle,isNot(WindowsAtomicPersonCardCoordinator.bundleId(
     school,parent['operationId'] as String,'changed-card-revision-0002')));
 });

}

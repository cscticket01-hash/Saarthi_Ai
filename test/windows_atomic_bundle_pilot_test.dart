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
     'createIntent':true,
     'syncState':'pending',
     'data':{'schoolId':school,'mobileStableId':'p-'+'8'*32}};
   final doc={'schoolId':school,'documentId':'card-one',
     'documentRevision':'original-card-revision-0001',
     'documentKind':'idCard','deleted':false,'baseCloudRevision':'',
     'ownerRole':'student','personId':'p-'+'8'*32,
     'studentId':'student-one','optimizedMimeType':'application/pdf',
     'optimizedPath':'/isolated/student-card.pdf'};
   expect(WindowsAtomicPersonCardCoordinator.matches(school,parent,doc),isTrue);
   final teacher={...parent,
     'collection':'teachers_directory',
     'data':{'schoolId':school,'mobileStableId':'p-'+'6'*32}};
   final teacherCard={...doc,'ownerRole':'teacher','personId':'p-'+'6'*32,
     'teacherId':'student-one'};
   expect(WindowsAtomicPersonCardCoordinator.matches(school,teacher,teacherCard),isTrue);
   expect(WindowsAtomicPersonCardCoordinator.matches(school,
     {...teacher,'data':{'schoolId':school,'mobileStableId':'p-broken'}},
     teacherCard),isFalse,reason:'Teacher QR owner must use a verified generation');
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
     {...parent,'createIntent':false},doc),isFalse,
     reason:'Only first-time Person creation may be bundled with an original ID');
   // Original inline photo is staged with the same original Person+Card
   // operations, without a second queue or a premature Drive upload.
   for(final original in <Map<String,dynamic>>[
     {'photoUrl':'data:image/jpeg;base64,YWJjZA=='},
     {'photoBase64':'YWJjZA=='},
   ]){
     expect(WindowsAtomicPersonCardCoordinator.matches(school,
       {...parent,'data':{...(parent['data'] as Map),...original}},doc),isTrue);
   }
   for(final unsupported in <Map<String,dynamic>>[
     {'photoUrl':'https://drive.google.com/file/d/existing-photo/view'},
     {'photoPath':'C:/school/retained/student.jpg'},
     {'portraitBase64':'YWJjZA=='},
     {'nested':{'photoBase64':'YWJjZA=='}},
     {'photoBase64':'YWJjZA==','photoUrl':'data:image/jpeg;base64,eHl6'},
   ]){
     expect(WindowsAtomicPersonCardCoordinator.matches(school,
       {...parent,'data':{...(parent['data'] as Map),...unsupported}},doc),isFalse,
       reason:'Unsupported or ambiguous original media stays with its legacy owner');
   }
   expect(WindowsAtomicPersonCardCoordinator.matches(school,
       {...parent,'data':{...(parent['data'] as Map),'photoBase64':''}},doc),isTrue,
       reason:'An empty optional photo must not block a photo-free ID card');
   expect(WindowsAtomicPersonCardCoordinator.matches(school,
     {...parent,'wireData':{'schoolId':school,'mobileStableId':'p-'+'8'*32,
       'photoBase64':'YWJjZA=='}},doc),isFalse,
       reason:'A pre-bound wire photo cannot be silently omitted from the bundle');
   expect(WindowsAtomicPersonCardCoordinator.matches(school,
     {...parent,'wireData':{'schoolId':school,'mobileStableId':'p-'+'8'*32,
       'photoUrl':'https://drive.google.com/file/d/prior-drive-portrait/view'}},
     doc),isFalse,reason:'A legacy Drive upload cannot be counted as a new atomic photo');
   expect(WindowsAtomicPersonCardCoordinator.photoFreeWire(
     {'photoUrl':'','schoolId':school}),isTrue);
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
   final photoKey=WindowsAtomicPersonCardCoordinator.photoUploadKey(
     school,parent['operationId'] as String,doc['documentRevision'] as String);
   expect(photoKey,startsWith('photo-'));
   expect(photoKey,isNot(WindowsAtomicPersonCardCoordinator.photoUploadKey(
     school,parent['operationId'] as String,'changed-card-revision-0002')));
   expect(WindowsAtomicPersonCardCoordinator.originalPortraitBytes(
     'data:image/jpeg;base64,YWJjZA=='),utf8.encode('abcd'));
   expect(WindowsAtomicPersonCardCoordinator.originalPortraitBytes(
     'YWJjZA=='),utf8.encode('abcd'));
 });

 test('receipt and marksheet reuse TEST cloud stage with exact printable PDF ceilings',() async {
   Uint8List document(int size) {
     final bytes=Uint8List(size);
     bytes.setRange(0,8,latin1.encode('%PDF-1.7'));
     bytes.setRange(size-5,size,latin1.encode('%%EOF'));
     return bytes;
   }
   for(final entry in <(String,int)>[
     ('receipt',30*1024),('marksheet',150*1024)
   ]){
     final kind=entry.$1,limit=entry.$2;
     final bytes=document(limit);
     final key='test-school-pdf-$kind-0001';
     final id=sha256.convert(utf8.encode(jsonEncode([school,key]))).toString();
     final sha=sha256.convert(bytes).toString();
     final received=<Map<String,dynamic>>[];
     final result=await AtomicBundlePilot.stage(
       school:school,kind:kind,uploadKey:key,name:'$kind.pdf',
       mime:'application/pdf',bytes:bytes,isolatedTest:true,
       request:(action,body)async{
         expect(action,'managed/live/bundle-stage');
         expect(body['sizeBytes'],limit);
         expect(body['sha256'],sha);
         expect(base64Decode(body['base64'] as String),bytes);
         received.add(body);
         return {'success':true,'schoolId':school,'bundleProtocol':1,
           'mediaReady':true,'cloudflareAccepted':true,'driveVerified':false,
           'media':{'kind':kind,'id':id,'uploadKey':key,
             'sha256':sha,'sizeBytes':limit,'mime':'application/pdf'}};
       });
     expect(result['sha256'],sha);
     expect(result.containsKey('fileId'),isFalse);
     expect(received.length,1);
     await expectLater(AtomicBundlePilot.stage(
       school:school,kind:kind,uploadKey:key,name:'$kind.pdf',
       mime:'application/pdf',bytes:document(limit+1),isolatedTest:true,
       request:(action,body)async{fail('Oversized PDF entered cloud');}),
       throwsStateError);
     await expectLater(AtomicBundlePilot.stage(
       school:school,kind:kind,uploadKey:key,name:'$kind.pdf',
       mime:'image/png',bytes:bytes,isolatedTest:true,
       request:(action,body)async{fail('Invalid PDF MIME entered cloud');}),
       throwsStateError);
   }
 });

 test('finance and exam originals publish only complete typed TEST bundles',()async{
   for(final receipt in [true,false]){
     final type=receipt?'receipt':'marksheet';
     final bundleId='typed-financial-original-'+type+'-0001';
     final file={'kind':type,'id':id,'uploadKey':uploadKey,
       'sha256':sha,'sizeBytes':bytes.length,'mime':'application/pdf'};
     final first={'collection':receipt?'fee_payments':'exam_center_results',
       'id':receipt?'pay1':'result1','operation':'write',
       'operationId':'typed-financial-parent-'+type+'-0001',
       'expectedRevision':'','data':{'schoolId':school,'studentId':'s1'}};
     final ledger={'collection':'fee_ledger','id':'ledger1',
       'operation':'write','operationId':'typed-ledger-operation-0001',
       'expectedRevision':'','data':{'schoolId':school,'studentId':'s1'}};
     final doc={'collection':'documents','id':'financialDoc',
       'operation':'write','operationId':'typed-document-'+type+'-0001',
       'expectedRevision':'','data':{'schoolId':school,'studentId':'s1',
         'contentHash':sha}};
     final ops=<Map<String,dynamic>>[first,if(receipt)ledger,doc];
     final result=await AtomicBundlePilot.publish(
       school:school,bundleId:bundleId,operations:ops,media:[file],
       isolatedTest:true,request:(action,body)async{
         expect(action,'managed/live/bundle-publish');
         expect(body['operations'],ops);
         expect(body['mediaManifestHash'],
           AtomicBundlePilot.manifest(school,bundleId,[file])['mediaManifestHash']);
         return {'success':true,'schoolId':school,'bundleProtocol':1,
           'bundleId':bundleId,'cloudState':'committed','mediaReady':true,
           'archiveReady':false,'acknowledgements':[
             for(final op in ops){'operationId':op['operationId'],
               'cloudState':'committed'}]};
       });
     expect(result['archiveReady'],false);
     await expectLater(AtomicBundlePilot.publish(
       school:school,bundleId:bundleId,operations:ops.sublist(0,ops.length-1),
       media:[file],isolatedTest:true,
       request:(action,body)async{fail('Partial TEST bundle must not publish');}),
       throwsStateError);
   }
 });

}

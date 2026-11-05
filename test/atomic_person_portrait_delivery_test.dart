import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image/image.dart' as img;

import '../lib/windows_connect/atomic_person_portrait_delivery.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';

void main() {
 TestWidgetsFlutterBinding.ensureInitialized();
 const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
 const bundle='original-person-photo-card-bundle-0001';
 const document='original-person-photo-card-document-0001';
 const generation='p-88888888888888888888888888888888';
 const id='a' * 64;
 final db=FirebaseFirestore.instance;
 late Uint8List photo;
 late String digest;
 late Map<String,dynamic> person;
 setUp(() async {
   FlutterSecureStorage.setMockInitialValues({});
   await WindowsRuntimeFlags.setLocalStorageEnabled(true);
   final folder=await Directory.systemTemp.createTemp('atomic-person-photo-');
   await db.changeLocalStorageLocation(folder.path);
   await db.switchProfile(folder.path,identity:{
     'schoolId':school,'schoolSyncId':school,
   });
   final picture=img.Image(width:96,height:96);
   photo=Uint8List.fromList(img.encodeJpg(picture,quality:83));
   digest=sha256.convert(photo).toString();
   person={'schoolId':school,'mobileStableId':generation,'atomicPortrait':{
     'bundleId':bundle,'documentId':document,'role':'student',
     'id':id,'sha256':digest,'mime':'image/jpeg','sizeBytes':photo.length,
   }};
 });
 tearDown(() async => db.resetVolatileSession());
 test('same-school original portrait is SHA-verified directly from Cloudflare',()async{
   var cloudCalls=0;
   final found=await AtomicPersonPortraitDelivery.bytes(person,
     request:(action,body)async{
       expect(action,'managed/live/bundle-media');
       expect(body['bundleId'],bundle);
       expect(body['kind'],'photo');
       cloudCalls++;
       return {'success':true,'schoolId':school,'bundleProtocol':1,
         'bundleId':bundle,'id':id,'kind':'photo','sha256':digest,
         'sizeBytes':photo.length,'mime':'image/jpeg',
         'ownerRole':'student','personId':generation,'base64':base64Encode(photo)};
     });
   expect(found,photo);
   expect(cloudCalls,1);
 });
 test('after 24h cleanup only signed matching Drive document may recover photo',()async{
   var archiveReads=0;
   final found=await AtomicPersonPortraitDelivery.bytes(person,
     request:(action,body)async{
       if(action=='managed/live/bundle-media')throw StateError('Cloud bytes expired');
       expect(action,'managed/live/read');
       expect(body['collection'],'documents');
       expect(body['id'],document);
       archiveReads++;
       return {'success':true,'schoolId':school,'liveProtocol':1,'record':{
         'schoolId':school,'bundleId':bundle,'personId':generation,
         'ownerRole':'student','documentKind':'idCard',
         'bundleMedia':[{'kind':'idCard','sha256':'b'*64},
           {'kind':'photo','id':id,'sha256':digest,'mime':'image/jpeg',
            'sizeBytes':photo.length,'fileId':'verifiedDrivePortrait001'}],
       }};
     },
     driveImage:(url)async{
       expect(url,'https://drive.google.com/file/d/verifiedDrivePortrait001/view');
       return photo;
     });
   expect(found,photo);
   expect(archiveReads,1);
 });
 test('foreign school, forged photo digest and stale Drive document fail closed',()async{
   await expectLater(AtomicPersonPortraitDelivery.bytes({
     ...person,'schoolId':'vs-'+'f'*32,
   },request:(action,body)async=>throw StateError('should not read')),
     throwsStateError);
   final wrong={...person,'atomicPortrait':{
     ...(person['atomicPortrait'] as Map),'sha256':'c'*64}};
   await expectLater(AtomicPersonPortraitDelivery.bytes(wrong,
     request:(action,body)async{
       if(action=='managed/live/bundle-media')return {
         'success':true,'schoolId':school,'bundleProtocol':1,
         'bundleId':bundle,'id':id,'kind':'photo','sha256':'c'*64,
         'sizeBytes':photo.length,'mime':'image/jpeg',
         'ownerRole':'student','personId':generation,'base64':base64Encode(photo),
       };
       return {'success':true,'schoolId':school,'liveProtocol':1,'record':{
         'schoolId':school,'bundleId':'a-different-bundle',
         'personId':generation,'ownerRole':'student',
       }};
     }),throwsStateError);
 });
}

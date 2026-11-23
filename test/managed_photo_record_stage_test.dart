import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:saarthi_ai/windows_connect/managed_record_media.dart';
import 'package:saarthi_ai/windows_local_firestore.dart';
import 'package:saarthi_ai/windows_runtime_flags.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final db=FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile(
      'photo-cloudflare-${DateTime.now().microsecondsSinceEpoch}',
      identity:{'schoolId':school,'schoolSyncId':school},
    );
  });
  test('portrait original is owned by Cloudflare with metadata; no Google fileId at ACK',() async {
    final raw=Uint8List.fromList([1,2,3,4,5,6,7,8]);
    final opt=Uint8List.fromList([0xff,0xd8,0xff,0,0xff,0xd9]);
    final inline='data:image/png;base64,${base64Encode(raw)}';
    final item={
      'schoolId':school,'collection':'students_directory',
      'documentId':'student-original-photo-1',
      'operation':'set','operationId':'school-photo-original-operation-00001',
      'baseCloudRevision':'','data':{
        'schoolId':school,'studentId':'student-original-photo-1',
        'name':'Student','photoUrl':inline,
      },
    };
    final originalHash=sha256.convert(raw).toString();
    final fileHash=sha256.convert(opt).toString();
    final key=sha256.convert(utf8.encode(jsonEncode([
      school,item['collection'],item['documentId'],item['operationId'],fileHash,
    ]))).toString();
    final ticket=sha256.convert(utf8.encode(jsonEncode([school,key]))).toString();
    var sends=0;
    final stage=await stageManagedOriginalPhotoRecord(item,school,
      optimize:(b)async{
        expect(b,raw);
        return {'optimized':opt,'mimeType':'image/jpeg'};
      },
      request:(body)async{
        sends++;
        expect(body['action'],'managed/record/media/stage/resumable');
        expect(body['uploadKey'],key);
        expect(body['sha256'],fileHash);
        expect(body['record']['operationId'],item['operationId']);
        expect(body['record']['sourceHash'],originalHash);
        expect(body['record']['data']['photoSourceHash'],originalHash);
        expect(body['record']['data'].containsKey('photoUrl'),false);
        expect(body['record']['data'].containsKey('photoFileId'),false);
        if(body['operation']=='begin')return{
          'schoolId':school,'uploadResumableVersion':1,
          'uploadKey':key,'sha256':fileHash,'sizeBytes':opt.length,
          'offset':0,'committed':false};
        return{'success':true,'schoolId':school,'cloudflareAccepted':true,
          'cloudflareHandoffVersion':1,'driveState':'pending',
          'delivery':{'id':ticket,'lane':'file-$ticket'}};
      },
    );
    expect(sends,2);
    expect(stage?['sourceHash'],originalHash);
    expect(stage?['fileSha256'],fileHash);
    expect((stage?['delivery'] as Map)['id'],ticket);
    expect((item['data'] as Map)['photoUrl'],inline);
  });
  test('no photo and multiple mutable media never enter one-file early handoff',() async {
    Future<Map<String,dynamic>> forbidden(Map<String,dynamic> _)async{
      fail('No early Cloudflare request for absent or multi-media records');
    }
    final base={'schoolId':school,'collection':'students_directory',
      'documentId':'student-1','operation':'set',
      'operationId':'school-photo-original-operation-00001',
      'baseCloudRevision':''};
    expect(await stageManagedOriginalPhotoRecord({
      ...base,'data':{'schoolId':school,'name':'No photo'},
    },school,request:forbidden),isNull);
    final inline='data:image/jpeg;base64,${base64Encode([1,2,3])}';
    expect(await stageManagedOriginalPhotoRecord({
      ...base,'data':{'schoolId':school,
        'photoUrl':inline,'sealUrl':inline},
    },school,request:forbidden),isNull);
  });

  test('retry probes only signed original Drive photo proof, not a Cloudflare pending ticket', () async {
    const key='original-photo-upload-key',sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      name='photo_optimized_test.jpg',mime='image/jpeg',size=123;
    var reads=0;
    Future<Map<String,dynamic>> read(String action,Map<String,dynamic> args) async {
      reads++;
      expect(action,'managed/file/receipt');
      expect(args['uploadKey'],key);
      expect(args['sha256'],sha);
      expect(args['sizeBytes'],size);
      expect(args['name'],name);
      expect(args['mime'],mime);
      return {'success':true,'schoolId':school,'photoReceiptVersion':1,
        'uploadKey':key,'sha256':sha,'sizeBytes':size,'name':name,'mime':mime,
        'verified':true,'fileId':'verified-photo-id',
        'fileUrl':'https://drive.google.com/file/d/verified-photo-id/view'};
    }
    final proof=await verifyRetriedOriginalPhoto(school:school,uploadKey:key,
      sha256Hex:sha,sizeBytes:size,name:name,mime:mime,call:read);
    expect(proof?['fileId'],'verified-photo-id');
    expect(reads,1);
    final unknown=await verifyRetriedOriginalPhoto(school:school,uploadKey:key,
      sha256Hex:sha,sizeBytes:size,name:name,mime:mime,
      call:(_,__)async{'success':true,'schoolId':school,'photoReceiptVersion':1,
        'uploadKey':key,'sha256':sha,'sizeBytes':size,'name':name,'mime':mime,
        'verified':false,'status':'unknown'});
    expect(unknown,isNull,'Unknown must fall through to exact-key retry, never ACK');
  });

  test('retry receipt rejects wrong school, digest, Drive ID, or unverified proof',() async {
    const key='key',sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      name='photo.png',mime='image/png',size=10;
    final base={'success':true,'schoolId':school,'photoReceiptVersion':1,
      'uploadKey':key,'sha256':sha,'sizeBytes':size,'name':name,'mime':mime,
      'verified':true,'fileId':'photo-id',
      'fileUrl':'https://drive.google.com/file/d/photo-id/view'};
    for(final wrong in [
      {'schoolId':'vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'},
      {'sha256':'b'*64}, {'sizeBytes':9},
      {'verified':true,'fileId':'../outside'},
      {'verified':false,'status':'unknown'},
      {'fileUrl':'https://drive.google.com/file/d/wrong/view'},
      {'photoReceiptVersion':0},
    ]) {
      await expectLater(verifyRetriedOriginalPhoto(school:school,uploadKey:key,
        sha256Hex:sha,sizeBytes:size,name:name,mime:mime,
        call:(_,__)async=>{...base,...wrong}),throwsStateError);
    }
    await expectLater(verifyRetriedOriginalPhoto(school:school,uploadKey:key,
      sha256Hex:sha,sizeBytes:size,name:name,mime:mime,
      call:(_,__)async=>throw StateError('Original Google timeout')),
      throwsStateError,reason:'Provider timeout must retain durable original, never reupload blindly');
  });
}

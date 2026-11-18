import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
import 'package:flutter_test/flutter_test.dart';
import '../lib/mobile/atomic_portrait_delivery.dart';

void main(){
  const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const bundle='mobile-student-original-portrait-bundle-0001';
  const id='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
  const role='student';
  final image=img.Image(width:72,height:72);
  final bytes=Uint8List.fromList(img.encodeJpg(image,quality:82));
  final digest=sha256.convert(bytes).toString();
  final pointer={'bundleId':bundle,'id':id,'sha256':digest,
    'sizeBytes':bytes.length,'mime':'image/jpeg'};
  final response=<String,dynamic>{
    'success':true,'available':true,'mobileAtomicPortrait':true,
    'schoolId':school,'projectId':school,'bundleProtocol':1,
    'bundleId':bundle,'id':id,'kind':'photo','sha256':digest,
    'contentHash':digest,'mime':'image/jpeg',
    'sizeBytes':bytes.length,'ownerRole':role,
    'portraitRevision':'atomic-$bundle','base64':base64Encode(bytes),
  };
  test('signed same-person portrait is byte-identical and decodable',(){
    expect(base64Encode(AtomicPortraitDelivery.verify(
      school,role,pointer,response)),base64Encode(bytes));
  });
  test('foreign role, school, stale bundle, forged image and invalid MIME fail closed',(){
    for(final wrong in <Map<String,dynamic>>[
      {...response,'ownerRole':'teacher'},
      {...response,'schoolId':'vs-'+'c'*32},
      {...response,'projectId':'vs-'+'c'*32},
      {...response,'bundleId':'another-original-bundle-0001'},
      {...response,'portraitRevision':'wrong-revision'},
      {...response,'id':'c'*64},
      {...response,'sha256':'e'*64},
      {...response,'sizeBytes':bytes.length+1},
      {...response,'mime':'image/png'},
      {...response,'base64':base64Encode(Uint8List.fromList(
        [...bytes.sublist(0,bytes.length-2),0x00,0x00]))},
      {...response,'base64':'!!not-base64!!'},
      {...response,'available':false},
    ]){
      expect(()=>AtomicPortraitDelivery.verify(
        school,role,pointer,wrong),throwsStateError);
    }
  });
}

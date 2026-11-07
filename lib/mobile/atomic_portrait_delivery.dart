import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;

/// TEST-only portrait receiver. The broker authorizes the signed mobile
/// session; these checks bind the bytes to its published immutable school
/// bundle. No extra uploader, queue or Google Drive authority is created.
class AtomicPortraitDelivery {
  const AtomicPortraitDelivery._();

  static Uint8List verify(String school, String role, Map pointer, Map response) {
    final bundle=pointer['bundleId'],id=pointer['id'],digest=pointer['sha256'],
      mime=pointer['mime'],size=pointer['sizeBytes'];
    if(!RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school)||
       !{'student','teacher'}.contains(role)||
       bundle is! String||
       !RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(bundle)||
       id is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)||
       digest is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)||
       !{'image/jpeg','image/png','image/webp'}.contains(mime)||
       size is! int||size<12||size>40*1024||
       response['success']!=true||response['available']!=true||
       response['mobileAtomicPortrait']!=true||
       response['schoolId']!=school||response['projectId']!=school||
       response['bundleProtocol']!=1||response['bundleId']!=bundle||
       response['portraitRevision']!='atomic-$bundle'||
       response['kind']!='photo'||response['id']!=id||
       response['sha256']!=digest||response['contentHash']!=digest||
       response['mime']!=mime||response['sizeBytes']!=size||
       response['ownerRole']!=role||
       response['base64'] is! String)
      throw StateError('Published school portrait owner/proof is unverified.');
    late final Uint8List bytes;
    try{bytes=Uint8List.fromList(base64Decode(response['base64'] as String));}
    on FormatException{throw StateError('School portrait bytes cannot be decoded.');}
    if(bytes.length!=size||sha256.convert(bytes).toString()!=digest)
      throw StateError('Original portrait bytes differ from published SHA.');
    final jpeg=bytes.length>=4&&bytes[0]==0xff&&bytes[1]==0xd8&&
      bytes[2]==0xff&&bytes[bytes.length-2]==0xff&&bytes.last==0xd9;
    const pngMagic=<int>[137,80,78,71,13,10,26,10];
    final png=bytes.length>=8&&
      List.generate(8,(i)=>bytes[i]).join(',')==pngMagic.join(',');
    final webp=bytes.length>=20&&
      String.fromCharCodes(bytes.sublist(0,4))=='RIFF'&&
      String.fromCharCodes(bytes.sublist(8,12))=='WEBP';
    if(!((mime=='image/jpeg'&&jpeg)||(mime=='image/png'&&png)||
         (mime=='image/webp'&&webp)))
      throw StateError('Original portrait MIME is invalid.');
    final decoder=img.findDecoderForData(bytes);
    final header=decoder?.startDecode(bytes);
    if(header==null||header.width<=0||header.height<=0||
       header.width*header.height>20000000||
       decoder!.numFrames()!=1||decoder.decodeFrame(0)==null)
      throw StateError('Original portrait image is not decodable.');
    return bytes;
  }
}

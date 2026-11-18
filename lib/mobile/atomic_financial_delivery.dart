import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// TEST-only verified PDF delivery from the existing authenticated school
/// session, never a second document cache, queue or download authority.
class AtomicFinancialDelivery {
  const AtomicFinancialDelivery._();

  static Uint8List verify(String school,String kind,String documentId,
      Map<String,dynamic> response) {
    final limit=kind=='receipt'?30*1024:kind=='marksheet'?150*1024:0;
    final bundle=response['bundleId'],id=response['id'],hash=response['sha256'];
    if(!RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school)||
       limit==0||documentId.isEmpty||documentId.length>200||
       documentId.contains('/')||
       bundle is! String||!RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(bundle)||
       id is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)||
       hash is! String||!RegExp(r'^[a-f0-9]{64}$').hasMatch(hash)||
       response['success']!=true||response['available']!=true||
       response['mobileAtomicDocument']!=true||
       response['schoolId']!=school||response['projectId']!=school||
       response['bundleProtocol']!=1||response['kind']!=kind||
       response['documentId']!=documentId||response['mime']!='application/pdf'||
       response['contentHash']!=hash||
       response['documentRevision']!='atomic-$bundle'||
       response['base64'] is! String||response['sizeBytes'] is! int||
       (response['sizeBytes'] as int)<16||(response['sizeBytes'] as int)>limit) {
      throw StateError('Atomic school PDF identity did not verify.');
    }
    late final Uint8List bytes;
    try {bytes=Uint8List.fromList(base64Decode(response['base64'] as String));}
    on FormatException {throw StateError('Atomic school PDF bytes are invalid.');}
    if(bytes.length!=response['sizeBytes']||
       sha256.convert(bytes).toString()!=hash||
       String.fromCharCodes(bytes.take(5))!='%PDF-'||
       !latin1.decode(bytes.skip(bytes.length>2048?bytes.length-2048:0).toList())
         .contains('%%EOF')) {
      throw StateError('Atomic school PDF differs from published SHA-256.');
    }
    return bytes;
  }
}

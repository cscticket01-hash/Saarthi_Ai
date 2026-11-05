import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

/// Strict client-side verification of a school-bound, published ID PDF.
/// An ACK, file name or network success cannot substitute for the byte hash.
class AtomicCardDelivery {
  static Uint8List verify(String school, Map pointer, Map response) {
    final bundle=pointer['bundleId'],id=pointer['id'],sha=pointer['sha256'];
    if(!RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school) ||
       bundle is! String ||
       !RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(bundle) ||
       id is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(id) ||
       sha is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha) ||
       response['success']!=true || response['available']!=true ||
       response['mobileAtomicIdCard']!=true ||
       response['schoolId']!=school || response['projectId']!=school ||
       response['bundleProtocol']!=1 || response['bundleId']!=bundle ||
       response['id']!=id || response['kind']!='idCard' ||
       response['sha256']!=sha || response['contentHash']!=sha ||
       response['mime']!='application/pdf' ||
       response['documentRevision']!='atomic-$bundle' ||
       response['base64'] is! String ||
       response['sizeBytes'] is! int ||
       (response['sizeBytes'] as int)<16 ||
       (response['sizeBytes'] as int)>85*1024) {
      throw StateError('Atomic card identity and school proof did not verify.');
    }
    late final Uint8List bytes;
    try{bytes=Uint8List.fromList(base64Decode(response['base64'] as String));}
    on FormatException{throw StateError('Atomic card bytes failed decoding.');}
    if(bytes.length!=response['sizeBytes'] ||
       sha256.convert(bytes).toString()!=sha ||
       !String.fromCharCodes(bytes.take(5)).startsWith('%PDF-') ||
       !latin1.decode(bytes.skip(bytes.length>2048?bytes.length-2048:0).toList())
         .contains('%%EOF')) {
      throw StateError('Atomic card bytes do not match the published SHA-256.');
    }
    return bytes;
  }
}

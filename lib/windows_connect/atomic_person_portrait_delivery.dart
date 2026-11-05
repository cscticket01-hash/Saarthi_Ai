import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../windows_local_firestore.dart';
import 'atomic_bundle_pilot.dart';
import 'atomic_portrait_preflight.dart';
import 'managed_school_session.dart';
import 'school_drive_images.dart';

typedef AtomicPortraitRequest = Future<Map<String,dynamic>> Function(
    String action, Map<String,dynamic> body);

/// Signed, read-only TEST receiver for the original portrait already staged
/// with Person + ID Card in the existing school Durable Object. Never owns an
/// uploader, durable queue, Drive ACK, or an independent media revision.
class AtomicPersonPortraitDelivery {
  const AtomicPersonPortraitDelivery._();

  static Future<Uint8List?> bytes(Map<String,dynamic> person, {
    AtomicPortraitRequest? request,
    Future<Uint8List?> Function(String url)? driveImage,
  }) async {
    if(!AtomicBundlePilot.buildEnabled&&request==null)return null;
    final pointer=person['atomicPortrait'];
    final school=person['schoolId'],generation=person['mobileStableId'];
    if(pointer==null)return null;
    if(pointer is! Map||school is! String||
       !RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school)||
       generation is! String||generation.isEmpty||generation.length>200||
       !RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(pointer['bundleId']?.toString()??'')||
       !RegExp(r'^[A-Za-z0-9_-]{1,200}$').hasMatch(pointer['documentId']?.toString()??'')||
       !RegExp(r'^[a-f0-9]{64}$').hasMatch(pointer['id']?.toString()??'')||
       !RegExp(r'^[a-f0-9]{64}$').hasMatch(pointer['sha256']?.toString()??'')||
       !['student','teacher'].contains(pointer['role'])||
       !['image/jpeg','image/png','image/webp'].contains(pointer['mime'])||
       pointer['sizeBytes'] is! int||
       pointer['sizeBytes']<12||pointer['sizeBytes']>40*1024)
      throw StateError('Published school portrait identity is invalid.');
    final db=FirebaseFirestore.instance,profile=db.activeProfileId;
    void scope() {
      if(db.activeProfileId!=profile||
         db.activeProfileIdentity['schoolSyncId']!=school)
        throw StateError('School changed during atomic portrait download.');
    }
    scope();
    final role=pointer['role'] as String;
    final id=pointer['id'] as String,hash=pointer['sha256'] as String,
      mime=pointer['mime'] as String,size=pointer['sizeBytes'] as int,
      bundle=pointer['bundleId'] as String,
      documentId=pointer['documentId'] as String;
    final call=request??(action,body)=>
      ManagedSchoolSession.callForSchool(school,action,body);
    Uint8List verify(Uint8List data) {
      scope();
      if(data.length!=size||sha256.convert(data).toString()!=hash)
        throw StateError('Published portrait bytes changed.');
      AtomicPortraitPreflight.verifyStagedBytes(data,mime);
      return data;
    }

    // Immediate delivery comes from the same immutable, school-scoped file
    // lane. A transport miss after verified 24h cleanup may use Drive below.
    try {
      final result=await call('managed/live/bundle-media',{
        'liveProtocol':1,'bundleId':bundle,'kind':'photo','id':id,
      });
      scope();
      if(result['success']==true&&result['schoolId']==school&&
         result['bundleProtocol']==1&&result['bundleId']==bundle&&
         result['id']==id&&result['kind']=='photo'&&
         result['sha256']==hash&&result['sizeBytes']==size&&
         result['mime']==mime&&result['ownerRole']==role&&
         result['personId']==generation&&result['base64'] is String) {
        return verify(Uint8List.fromList(
          base64Decode(result['base64'] as String)));
      }
      throw StateError('Signed school portrait owner differs.');
    } catch (_) {
      scope();
      // Never fall back to an unsigned or guessed Drive ID. Only the current
      // signed document revision with the same immutable bundle and SHA can
      // authorize a verified archive file.
      final snapshot=await call('managed/live/read',{
        'liveProtocol':1,'collection':'documents','id':documentId,
      });
      scope();
      final row=snapshot['record'];
      if(snapshot['success']!=true||snapshot['schoolId']!=school||
         snapshot['liveProtocol']!=1||row is! Map||
         row['_syncDeleted']==true||row['bundleId']!=bundle||
         row['personId']!=generation||row['ownerRole']!=role||
         row['schoolId']!=school||row['documentKind']!='idCard'||
         row['bundleMedia'] is! List)
        throw StateError('Verified school portrait archive is unavailable.');
      final photos=(row['bundleMedia'] as List)
          .whereType<Map>().where((m)=>m['kind']=='photo'&&
             m['id']==id&&m['sha256']==hash&&m['mime']==mime&&
             m['sizeBytes']==size).toList();
      if(photos.length!=1||
         photos.single['fileId'] is! String||
         !RegExp(r'^[A-Za-z0-9_-]{1,200}$')
           .hasMatch(photos.single['fileId'] as String))
        throw StateError('Original portrait has no verified Drive file.');
      final url='https://drive.google.com/file/d/${photos.single['fileId']}/view';
      final bytes=await (driveImage??schoolImageBytes)(url);
      scope();
      if(bytes==null)throw StateError('Verified Drive portrait not available.');
      return verify(bytes);
    }
  }
}

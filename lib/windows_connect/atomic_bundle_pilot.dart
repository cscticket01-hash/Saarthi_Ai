import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;

import 'managed_school_session.dart';
import 'atomic_portrait_preflight.dart';
import '../school_media_budgets.dart';

typedef AtomicBundleRequest = Future<Map<String,dynamic>> Function(
  String action, Map<String,dynamic> body);

/// TEST-only, explicit publisher; the existing Windows outboxes remain
/// authoritative. No legacy operation is silently repackaged or ACKed here.
class AtomicBundlePilot {
  const AtomicBundlePilot._();
  static const buildEnabled=bool.fromEnvironment('SAARTHI_ATOMIC_BUNDLE_TEST');

  static String canonical(Object? value) {
    if(value is List)return '[${value.map(canonical).join(',')}]';
    if(value is Map){
      final keys=value.keys.map((k)=>k.toString()).toList()..sort();
      return '{${keys.map((key)=>'${jsonEncode(key)}:${canonical(value[key])}').join(',')}}';
    }
    return jsonEncode(value);
  }

  static Map<String,dynamic> manifest(String school,String bundleId,
      List<Map<String,dynamic>> media) {
    if(!RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school) ||
       !RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(bundleId)||
       media.isEmpty||media.length>2)throw StateError('Invalid TEST atomic manifest.');
    final value={'schoolId':school,'bundleId':bundleId,'media':media};
    return {'media':media,
      'mediaManifestHash':sha256.convert(utf8.encode(canonical(value))).toString()};
  }

  static Future<Map<String,dynamic>> stage({
    required String school,required String kind,
    required String uploadKey,required String name,required String mime,
    required Uint8List bytes,AtomicBundleRequest? request,
    bool isolatedTest=false,
  })async{
    final pdfLimit=SchoolMediaBudgets.pdfLimit(kind);
    final photo=kind=='photo';
    if((!buildEnabled&&request==null)||!isolatedTest||
       !RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school)||
       !RegExp(r'^[A-Za-z0-9_-]{1,150}$').hasMatch(uploadKey)||
       name.isEmpty||name.length>200||name.contains('/')||name.contains('\\')||
       !['idCard','photo','receipt','marksheet'].contains(kind)||
       (photo?!['image/jpeg','image/png','image/webp'].contains(mime):
         mime!='application/pdf')||
       bytes.isEmpty||bytes.length>(photo?40*1024:pdfLimit??0))
      throw StateError('TEST atomic staging is not admitted.');
    if(!photo){
      if(bytes.length<16||
         !String.fromCharCodes(bytes.take(5)).startsWith('%PDF-')||
         !latin1.decode(bytes.skip(bytes.length>2048?bytes.length-2048:0)
            .toList()).contains('%%EOF'))
        throw StateError('Unverified school PDF envelope.');
    }
    if (photo) {
      // Reject forged/truncated photo bytes before any Cloudflare upload.
      AtomicPortraitPreflight.verifyStagedBytes(bytes, mime);
    } else {
      // The shared school PDF budget applies to every document class.
      SchoolMediaBudgets.verifyGeneratedPdf(kind, bytes);
    }
    final hash=sha256.convert(bytes).toString(),
      id=sha256.convert(utf8.encode(jsonEncode([school,uploadKey]))).toString();
    final call=request??(action,body)=>
      ManagedSchoolSession.callForSchool(school,action,body);
    final result=await call('managed/live/bundle-stage',{
      'liveProtocol':1,'kind':kind,'mime':mime,
      'uploadKey':uploadKey,'name':name,'sha256':hash,
      'sizeBytes':bytes.length,'base64':base64Encode(bytes),
    });
    final proof=result['media'];
    if(result['success']!=true||result['schoolId']!=school||
       result['bundleProtocol']!=1||result['mediaReady']!=true||
       result['cloudflareAccepted']!=true||proof is! Map||
       proof['kind']!=kind||proof['id']!=id||
       proof['uploadKey']!=uploadKey||proof['sha256']!=hash||
       proof['mime']!=mime||proof['sizeBytes']!=bytes.length)
      throw StateError('School Cloudflare staging proof is incomplete.');
    return Map<String,dynamic>.from(proof);
  }

  /// TEST-only staging: reuses the existing quality-safe portrait optimizer.
  /// It neither owns nor ACKs a Windows queue; full Person+Photo+ID remains
  /// a separate release gate.
  static Future<Map<String,dynamic>> stagePortrait({
    required String school, required String uploadKey,
    required String name, required Uint8List original,
    AtomicBundleRequest? request, bool isolatedTest=false,
  }) async {
    if ((!buildEnabled && request == null) || !isolatedTest) {
      throw StateError('Atomic portrait preflight is TEST-only.');
    }
    final prepared = await compute(AtomicPortraitPreflight.prepare, original);
    // The normalized container may differ from the retained original.
    final stem = name.replaceFirst(
      RegExp(r'\.(jpe?g|png|webp)$', caseSensitive: false), '');
    final extension = prepared.mime == 'image/png' ? 'png'
        : prepared.mime == 'image/webp' ? 'webp' : 'jpg';
    return stage(
      school: school, kind: 'photo', uploadKey: uploadKey,
      name: '$stem.$extension', mime: prepared.mime, bytes: prepared.bytes,
      request: request, isolatedTest: isolatedTest,
    );
  }

  static Future<Map<String,dynamic>> publish({
    required String school,required String bundleId,
    required List<Map<String,dynamic>> operations,
    required List<Map<String,dynamic>> media,
    AtomicBundleRequest? request,bool isolatedTest=false,
  })async{
    if((!buildEnabled&&request==null)||!isolatedTest||operations.length!=2||
       media.isEmpty||media.length>2||media.first['kind']!='idCard'||
       (media.length==2&&media[1]['kind']!='photo')||
       !['students_directory','teachers_directory'].contains(operations[0]['collection'])||
       operations[1]['collection']!='documents'||
       operations.any((op)=>op['operation']!='write'||op['data'] is! Map||
        (op['data'] as Map)['schoolId']!=school||
        op['id'] is! String || op['operationId'] is! String||
        op['expectedRevision'] is! String))
      throw StateError('Unverified Person/Card TEST bundle.');
    final proof=manifest(school,bundleId,media);
    final call=request??(action,body)=>
      ManagedSchoolSession.callForSchool(school,action,body);
    final result=await call('managed/live/bundle-publish',{
      'liveProtocol':1,'confirmIsolatedBundleTest':true,
      'bundleId':bundleId,'media':proof['media'],
      'mediaManifestHash':proof['mediaManifestHash'],
      'operations':operations,
    });
    final acks=result['acknowledgements'];
    if(result['success']!=true||result['schoolId']!=school||
       result['bundleProtocol']!=1||result['bundleId']!=bundleId||
       result['cloudState']!='committed'||result['mediaReady']!=true||
       result['archiveReady'] is! bool||acks is! List||
       acks.length!=operations.length||
       acks.asMap().entries.any((entry)=>entry.value is! Map||
        (entry.value as Map)['operationId']!=operations[entry.key]['operationId']||
        (entry.value as Map)['cloudState']!='committed'))
      throw StateError('No verified atomic Cloudflare commit receipt.');
    // A cloud receipt is NOT a Drive ACK, nor a local outbox deletion.
    return Map<String,dynamic>.from(result);
  }
  /// Retry-safe, exact wire operation proof after transport timeout.
  /// The original outbox remains authoritative until a local CAS transition.
  static Future<Map<String,dynamic>> receipt({
    required String school,required String bundleId,
    required List<Map<String,dynamic>> operations,
    required List<Map<String,dynamic>> media,
    AtomicBundleRequest? request,bool isolatedTest=false,
  }) async {
    if((!buildEnabled&&request==null)||!isolatedTest||
       operations.length!=2 || media.isEmpty || media.length>2 ||
       media.first['kind']!='idCard' ||
       (media.length==2&&media[1]['kind']!='photo') ||
       !['students_directory','teachers_directory'].contains(operations[0]['collection']) ||
       operations[1]['collection']!='documents' ||
       operations.any((op)=>op['operationId'] is! String ||
        op['id'] is! String || op['expectedRevision'] is! String ||
        op['data'] is! Map || (op['data'] as Map)['schoolId']!=school)) {
      throw StateError('Invalid isolated atomic receipt identity.');
    }
    final proof=manifest(school,bundleId,media);
    final call=request??(action,body)=>
      ManagedSchoolSession.callForSchool(school,action,body);
    final response=await call('managed/live/bundle-receipt',{
      'liveProtocol':1,'bundleId':bundleId,
      'operations':operations,'media':media,
      'mediaManifestHash':proof['mediaManifestHash'],
    });
    if(response['success']!=true||response['schoolId']!=school||
       response['bundleProtocol']!=1 ||
       response['found'] is! bool) {
      throw StateError('Atomic replay receipt did not authenticate.');
    }
    if(response['found']==false){
      return {'found':false,'schoolId':school,'bundleProtocol':1};
    }
    final receipt=response['receipt'],backups=response['backups'];
    if(receipt is! Map || backups is! List ||
       receipt['schoolId']!=school || receipt['bundleId']!=bundleId ||
       receipt['cloudState']!='committed' ||
       receipt['mediaManifestHash']!=proof['mediaManifestHash'] ||
       receipt['mediaReady']!=true ||
       receipt['acknowledgements'] is! List ||
       (receipt['acknowledgements'] as List).length!=2 ||
       backups.length!=2 || response['driveVerified'] is! bool ||
       response['cloudState']!='committed' ||
       response['mediaReady']!=true){
      throw StateError('Atomic receipt does not match published records.');
    }
    for(var i=0;i<operations.length;i++){
      final ack=(receipt['acknowledgements'] as List)[i],backup=backups[i];
      if(ack is! Map || backup is! Map ||
         ack['operationId']!=operations[i]['operationId'] ||
         backup['operationId']!=operations[i]['operationId'] ||
         backup['id']!=operations[i]['id'] ||
         backup['collection']!=operations[i]['collection'] ||
         backup['recordRevision']!=ack['recordRevision'] ||
         ack['recordRevision'] is! String ||
         !(ack['recordRevision'] as String).startsWith('live-') ||
         backup['driveVerified'] is! bool ||
         (backup['driveVerified']==true &&
          (backup['backupState']!='verified' ||
           backup['driveRevision'] is! String ||
           (backup['driveRevision'] as String).isEmpty))){
        throw StateError('Atomic receipt operation proof differs.');
      }
    }
    if(response['driveVerified']==true &&
       backups.any((item)=>item is! Map || item['driveVerified']!=true)) {
      throw StateError('Drive backup status cannot advance partially.');
    }
    return Map<String,dynamic>.from(response);
  }

}

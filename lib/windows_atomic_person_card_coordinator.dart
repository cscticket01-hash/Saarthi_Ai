import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;

import 'windows_local_firestore.dart';
import 'windows_firebase_sync.dart';
import 'windows_connect/managed_school_session.dart';
import 'windows_connect/atomic_bundle_pilot.dart';
import 'windows_connect/atomic_portrait_preflight.dart';
import 'windows_connect/managed_record_media.dart';

/// Routes *existing* durable parent and PDF queues through one TEST-only
/// atomic publication owner. It never creates another outbox, modifies source
/// bytes, emits an invented Drive ACK or enables itself in release builds.
class WindowsAtomicPersonCardCoordinator {
  const WindowsAtomicPersonCardCoordinator._();

  static String bundleId(String school,String parentOp,String cardOp) =>
    'pb-${sha256.convert(utf8.encode(jsonEncode([school,parentOp,cardOp])))}';

  static String uploadKey(String school,String cardOp) =>
    'pdf-${sha256.convert(utf8.encode(jsonEncode([school,cardOp])))}';

  static String photoUploadKey(String school,String parentOp,String cardOp) =>
    'photo-${sha256.convert(utf8.encode(jsonEncode([school,parentOp,cardOp])))}';

  /// An unmodified, self-contained photo source can use the *same* original
  /// school file Durable Object as the card. Remote URLs, local paths and
  /// already bound Drive uploads remain on the existing safe legacy owner.
  static String? inlinePortraitSource(Map data) {
    final b=data['photoBase64'],u=data['photoUrl'];
    if(b is String&&b.trim().isNotEmpty)return b.trim();
    if(u is String&&u.trim().startsWith('data:image/'))return u.trim();
    return null;
  }

  static bool canStageOriginalPortrait(Map data) {
    final raw=inlinePortraitSource(data),b=data['photoBase64'],u=data['photoUrl'];
    if(b!=null&&b is! String||u!=null&&u is! String)return false;
    if(b is String&&b.trim().isNotEmpty&&
       u is String&&u.trim().isNotEmpty&&b.trim()!=u.trim())return false;
    if(u is String&&u.trim().isNotEmpty&&!u.trim().startsWith('data:image/'))
      return false;
    for(final key in const [
      'photoFileId','photoPath','photoUri','portraitBase64','portraitUrl',
      'portraitPath','imageBase64']) {
      final value=data[key];
      if(value!=null&&(value is! String||value.trim().isNotEmpty))return false;
    }
    // Do not accidentally omit embedded person images outside the one
    // original top-level photo field.
    for(final entry in data.entries) {
      if(const ['photoUrl','photoBase64','photoMimeType'].contains(entry.key))
        continue;
      if(hasUnstagedInlineMedia(entry.value))return false;
    }
    if(raw!=null&&raw.length>12*1024*1024)return false;
    return true;
  }

  static bool photoFreeWire(Object? wire) {
    if(wire==null)return true;
    if(wire is! Map||hasUnstagedInlineMedia(wire))return false;
    for(final key in const [
      'photoUrl','photoBase64','photoFileId','atomicPortrait']) {
      final value=wire[key];
      if(value!=null&&(value is! String||value.trim().isNotEmpty))
        return false;
    }
    return true;
  }

  static Uint8List originalPortraitBytes(String source) {
    if(source.length>12*1024*1024)
      throw const FormatException('School portrait source is too large.');
    final bytes=source.startsWith('data:image/')
      ? Uint8List.fromList(UriData.parse(source).contentAsBytes())
      : Uint8List.fromList(base64Decode(source));
    if(bytes.isEmpty||bytes.length>8*1024*1024)
      throw const FormatException('School portrait original is too large.');
    return bytes;
  }

  /// Non-photo nested media must never be hidden inside a record bundle.
  static bool hasUnstagedInlineMedia(Object? input,[int depth=0]){
    if(depth>12)return true;
    if(input is String)return input.trimLeft().startsWith('data:image/');
    if(input is Map){
      // Existing school records may hold raw base64, a Drive/HTTP URL or a
      // local portrait path instead of a data:image URI. None is proof that
      // the original photo was SHA-staged in this atomic manifest. Until the
      // photo owner is integrated, keep these saves on the legacy safe lane.
      const portraitKeys=<String>{
        'photobase64','photourl','photofileid','photopath','photouri',
        'portraitbase64','portraiturl','portraitpath','imagebase64',
      };
      for(final entry in input.entries){
        final key=entry.key.toString().toLowerCase();
        final value=entry.value;
        if(portraitKeys.contains(key)&&value!=null&&
           (value is! String||value.trim().isNotEmpty))return true;
        if(hasUnstagedInlineMedia(value,depth+1))return true;
      }
      return false;
    }
    if(input is List)return input.any(
      (value)=>hasUnstagedInlineMedia(value,depth+1));
    return false;
  }

  static bool matches(String school,Map<String,dynamic> parent,
      Map<String,dynamic> card) {
    final collection=parent['collection'],id=parent['documentId'];
    final data=parent['data'];
    final role=collection=='teachers_directory'?'teacher':'student';
    return RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school) &&
      {'students_directory','teachers_directory'}.contains(collection) &&
      parent['schoolId']==school && parent['operation']=='set' &&
      parent['createIntent']==true &&
      parent['baseCloudRevision']=='' && parent['priorDeletion']==null &&
      parent['fieldPatch']==null &&
      !{'conflict','needsAttention'}.contains(parent['syncState']) &&
      id is String && id.isNotEmpty && id.length<=200 &&
      parent['operationId'] is String &&
      RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(parent['operationId']) &&
      data is Map && data['schoolId']==school &&
      canStageOriginalPortrait(data) &&
      photoFreeWire(parent['wireData']) &&
      data['mobileStableId'] is String &&
      RegExp(r'^p-[a-f0-9]{32,64}
      card['schoolId']==school &&
      card['documentKind']=='idCard' && card['deleted']!=true &&
      card['baseCloudRevision']=='' &&
      !{'conflict','needsAttention','Synced'}.contains(card['syncState']) &&
      card['ownerRole']==role &&
      card['studentId']==id && card['personId']==data['mobileStableId'] &&
      card['documentRevision'] is String &&
      RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(card['documentRevision']) &&
      card['documentRevision']!=parent['operationId'] &&
      (card['optimizedMimeType']??card['mimeType'])=='application/pdf' &&
      (card['optimizedPath']??card['localPath']) is String &&
      ((card['optimizedPath']??card['localPath']) as String).isNotEmpty;
  }

  static Future<int> run(String school,{bool Function()? canAdmit}) async {
    if(!AtomicBundlePilot.buildEnabled)return 0;
    final db=FirebaseFirestore.instance,profile=db.activeProfileId;
    if(db.activeProfileIdentity['schoolSyncId']!=school||
       !await db.localPersistenceEnabled())
      throw StateError('TEST atomic queue requires a durable school profile.');
    void scope(){
      if(db.activeProfileId!=profile||
         db.activeProfileIdentity['schoolSyncId']!=school)
        throw StateError('School switched during isolated atomic sync.');
    }
    final parents=(await db.collection('_windows_firebase_outbox').get()).docs;
    final cards=(await db.collection('_windows_document_outbox').get()).docs;
    scope();
    var completed=0;
    for(final parentRef in parents){
      if(canAdmit?.call()==false)break;
      scope();
      var parent=parentRef.data();
      if(!{'students_directory','teachers_directory'}.contains(parent['collection']) ||
         parent['baseCloudRevision']!=''||
         parent['operation']!='set'||
         parent['atomicState']!=null&&!{'reserved','committed'}.contains(parent['atomicState']))
        continue;
      final matching=cards.where((row)=>matches(school,parent,row.data())).toList();
      if(matching.length!=1)continue;
      final cardRef=matching.single,card=cardRef.data();
      final id=parent['documentId'] as String;
      final parentCollection=parent['collection'] as String;
      final originalParent=(await db.collection(parentCollection).doc(id).get()).data();
      final originalCard=(await db.collection('_local_student_documents')
          .doc(cardRef.id).get()).data();
      scope();
      if(originalParent==null||originalCard==null||
         !canStageOriginalPortrait(originalParent)||
         inlinePortraitSource(originalParent)!=
           inlinePortraitSource(parent['data'] as Map)||
         originalCard['documentRevision']!=card['documentRevision']||
         originalCard['localPath']!=card['localPath']||
         originalParent['mobileStableId']!=(parent['data'] as Map)['mobileStableId'])
        continue;
      if(parent['atomicState']==null){
        // The normal outbox preparation owner binds the same immutable
        // Person snapshot; do not use an unprepared or changed wire request.
        if(canAdmit?.call()==false)return completed;
        final photoSource=inlinePortraitSource(parent['data'] as Map);
        final prepared=await WindowsFirebaseRemote.prepareQueuedRecord(
          parentRef.reference,parent,school,
          prepareData:photoSource==null?null:(source) async {
            // Reuse the original immutable outbox wire binding and the usual
            // non-photo media owner. Never Drive-upload the portrait before
            // the Cloudflare-first Person + Photo + Card transaction.
            final safe=Map<String,dynamic>.from(source)
              ..remove('photoBase64')
              ..remove('photoUrl')
              ..remove('photoMimeType');
            return prepareManagedRecord(safe,school,(action,body)=>
              ManagedSchoolSession.callForSchool(school,action,body));
          });
        scope();
        if(prepared==null)continue; // A verified cloud conflict owns it.
        parent=prepared;
        if(!matches(school,parent,card))continue;
      }
      final cardOp=card['documentRevision'] as String;
      final parentOp=parent['operationId'] as String;
      final boundId=bundleId(school,parentOp,cardOp);
      if(parent['atomicBundleId']!=null&&
          parent['atomicBundleId']!=boundId||
         card['atomicBundleId']!=null&&card['atomicBundleId']!=boundId ||
         parent['atomicState']!=card['atomicState'])
        throw StateError('Existing atomic pair has divergent original ownership.');
      final path=(card['optimizedPath']??card['localPath']) as String;
      final bytes=await File(path).readAsBytes();
      scope();
      if(bytes.isEmpty||bytes.length>85*1024)
        throw StateError('Original ID PDF exceeds atomic safety budget.');
      final pdfHash=sha256.convert(bytes).toString();
      if(card['contentHash'] is String&&card['contentHash']!=pdfHash)
        throw StateError('Original queued ID PDF changed before staging.');
      final key=uploadKey(school,cardOp);
      final source=inlinePortraitSource(parent['data'] as Map);
      final portrait=source==null?null:await compute(
        AtomicPortraitPreflight.prepare,originalPortraitBytes(source));
      scope();
      final photoKey=portrait==null?null:photoUploadKey(school,parentOp,cardOp);
      final media=<Map<String,dynamic>>[{
        'kind':'idCard','id':sha256.convert(utf8.encode(jsonEncode([school,key]))).toString(),
        'uploadKey':key,'sha256':pdfHash,'sizeBytes':bytes.length,
        'mime':'application/pdf',
      },if(portrait!=null){
        'kind':'photo',
        'id':sha256.convert(utf8.encode(jsonEncode([school,photoKey]))).toString(),
        'uploadKey':photoKey,'sha256':portrait.sha256,
        'sizeBytes':portrait.bytes.length,'mime':portrait.mime,
      }];
      final personData=parent['wireData'] is Map?
          Map<String,dynamic>.from(parent['wireData'] as Map):
          Map<String,dynamic>.from(parent['data'] as Map);
      if(personData['schoolId']!=school||personData['mobileStableId']!=originalParent['mobileStableId']||
         personData['_syncFieldPatch']!=null||!photoFreeWire(personData))
        throw StateError('Original Person wire snapshot is not an atomic create.');
      final childData=<String,dynamic>{
        'schoolId':school,'studentId':id,
        if(card['ownerRole']=='teacher')'teacherId':id,
        'ownerRole':card['ownerRole'],'personId':card['personId'],
        'documentKind':'idCard','documentId':cardRef.id,
        'documentRevision':cardOp,'contentHash':pdfHash,
        'sizeBytes':bytes.length,'mimeType':'application/pdf',
        'fileName':card['optimizedFileName']??card['fileName']??'$cardOp.pdf',
        if(card['inputRevision'] is String)'inputRevision':card['inputRevision'],
      };
      final ops=<Map<String,dynamic>>[
        {'collection':parentCollection,'id':id,'operation':'write',
         'operationId':parentOp,'expectedRevision':'','data':personData},
        {'collection':'documents','id':cardRef.id,'operation':'write',
         'operationId':cardOp,'expectedRevision':'','data':childData},
      ];
      if(parent['atomicState']==null){
        await db.markAtomicPersonCardOutbox(
          school:school,parentQueueId:parentRef.id,parentBefore:parent,
          documentId:cardRef.id,documentBefore:card,
          bundleId:boundId,state:'reserved');
        scope();
        parent=(await parentRef.reference.get()).data()!;
      }
      var currentCard=(await cardRef.reference.get()).data();
      scope();
      if(currentCard==null||currentCard['atomicBundleId']!=boundId||
         currentCard['documentRevision']!=cardOp)
        throw StateError('Atomic ID generation changed during stage.');
      if(canAdmit?.call()==false)return completed;
      var receipt=await AtomicBundlePilot.receipt(
        school:school,bundleId:boundId,operations:ops,media:media,
        isolatedTest:true);
      scope();
      if(receipt['found']==false){
        // This is the only media staging owner. A retry with an existing
        // receipt does not stage or independently upload the same PDF.
        if(canAdmit?.call()==false)return completed;
        final staged=await AtomicBundlePilot.stage(
          school:school,kind:'idCard',uploadKey:key,
          name:childData['fileName'] as String,mime:'application/pdf',
          bytes:Uint8List.fromList(bytes),isolatedTest:true);
        if(staged['sha256']!=media.first['sha256']||
           staged['id']!=media.first['id'])
          throw StateError('Atomic staged PDF identity changed.');
        if(portrait!=null) {
          if(canAdmit?.call()==false)return completed;
          final stagedPhoto=await AtomicBundlePilot.stage(
            school:school,kind:'photo',uploadKey:photoKey!,
            name:'photo_${portrait.sha256}.${portrait.mime=='image/png'?'png':portrait.mime=='image/webp'?'webp':'jpg'}',
            mime:portrait.mime,bytes:portrait.bytes,isolatedTest:true);
          scope();
          if(stagedPhoto['sha256']!=media[1]['sha256']||
             stagedPhoto['id']!=media[1]['id']||
             stagedPhoto['sizeBytes']!=media[1]['sizeBytes'])
            throw StateError('Original portrait Cloudflare staging proof differs.');
        }
        if(canAdmit?.call()==false)return completed;
        final published=await AtomicBundlePilot.publish(
          school:school,bundleId:boundId,operations:ops,
          media:media,isolatedTest:true);
        scope();
        final acknowledgements=published['acknowledgements'] as List;
        if(parent['atomicState']=='reserved'){
          await db.markAtomicPersonCardOutbox(
            school:school,parentQueueId:parentRef.id,parentBefore:parent,
            documentId:cardRef.id,documentBefore:currentCard,
            bundleId:boundId,state:'committed',
            parentCloudRevision:acknowledgements[0]['recordRevision'] as String,
            documentCloudRevision:acknowledgements[1]['recordRevision'] as String);
          scope();
        }
        receipt=await AtomicBundlePilot.receipt(
          school:school,bundleId:boundId,operations:ops,media:media,
          isolatedTest:true);
      }
      scope();
      if(receipt['found']!=true)throw StateError('Atomic publish not recovered.');
      final backups=(receipt['backups'] as List)
        .map((e)=>Map<String,dynamic>.from(e as Map)).toList();
      if(parent['atomicState']=='reserved'){
        final acks=(receipt['receipt'] as Map)['acknowledgements'] as List;
        final beforeParent=(await parentRef.reference.get()).data()!;
        final beforeCard=(await cardRef.reference.get()).data()!;
        if(beforeParent['atomicState']=='reserved'){
          await db.markAtomicPersonCardOutbox(
            school:school,parentQueueId:parentRef.id,parentBefore:beforeParent,
            documentId:cardRef.id,documentBefore:beforeCard,bundleId:boundId,
            state:'committed',
            parentCloudRevision:acks[0]['recordRevision'] as String,
            documentCloudRevision:acks[1]['recordRevision'] as String);
        }
      }
      if(receipt['driveVerified']!=true)continue;
      if(canAdmit?.call()==false)return completed;
      final remote=<Map<String,dynamic>>[];
      for(final op in ops){
        final answer=await ManagedSchoolSession.callForSchool(school,'managed/live/read',{
          'liveProtocol':1,'collection':op['collection'],'id':op['id']});
        scope();
        final record=answer['record'];
        if(answer['success']!=true||answer['schoolId']!=school||
           answer['liveProtocol']!=1||record is! Map||
           answer['recordRevision']!=backups[remote.length]['recordRevision']||
           record['_syncRevision']!=answer['recordRevision']||
           record['_syncOperationId']!=op['operationId'])
          throw StateError('Signed current live record differs from verified backup.');
        remote.add(Map<String,dynamic>.from(record));
      }
      final finalParent=(await parentRef.reference.get()).data();
      final finalCard=(await cardRef.reference.get()).data();
      scope();
      if(finalParent==null||finalCard==null)
        throw StateError('Atomic outbox was replaced before Drive receipt.');
      await db.finishVerifiedAtomicPersonCardOutbox(
        school:school,parentQueueId:parentRef.id,parentBefore:finalParent,
        parentLocalBefore:originalParent,documentId:cardRef.id,
        documentBefore:finalCard,documentLocalBefore:originalCard,
        bundleId:boundId,parentCloud:remote[0],documentCloud:remote[1],
        verifiedBackups:backups,cardSha256:pdfHash);
      scope();completed++;
    }
    return completed;
  }
}
).hasMatch(data['mobileStableId']) &&
      card['schoolId']==school &&
      card['documentKind']=='idCard' && card['deleted']!=true &&
      card['baseCloudRevision']=='' &&
      !{'conflict','needsAttention','Synced'}.contains(card['syncState']) &&
      card['ownerRole']==role &&
      card['studentId']==id && card['personId']==data['mobileStableId'] &&
      card['documentRevision'] is String &&
      RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(card['documentRevision']) &&
      card['documentRevision']!=parent['operationId'] &&
      (card['optimizedMimeType']??card['mimeType'])=='application/pdf' &&
      (card['optimizedPath']??card['localPath']) is String &&
      ((card['optimizedPath']??card['localPath']) as String).isNotEmpty;
  }

  static Future<int> run(String school,{bool Function()? canAdmit}) async {
    if(!AtomicBundlePilot.buildEnabled)return 0;
    final db=FirebaseFirestore.instance,profile=db.activeProfileId;
    if(db.activeProfileIdentity['schoolSyncId']!=school||
       !await db.localPersistenceEnabled())
      throw StateError('TEST atomic queue requires a durable school profile.');
    void scope(){
      if(db.activeProfileId!=profile||
         db.activeProfileIdentity['schoolSyncId']!=school)
        throw StateError('School switched during isolated atomic sync.');
    }
    final parents=(await db.collection('_windows_firebase_outbox').get()).docs;
    final cards=(await db.collection('_windows_document_outbox').get()).docs;
    scope();
    var completed=0;
    for(final parentRef in parents){
      if(canAdmit?.call()==false)break;
      scope();
      var parent=parentRef.data();
      if(!{'students_directory','teachers_directory'}.contains(parent['collection']) ||
         parent['baseCloudRevision']!=''||
         parent['operation']!='set'||
         parent['atomicState']!=null&&!{'reserved','committed'}.contains(parent['atomicState']))
        continue;
      final matching=cards.where((row)=>matches(school,parent,row.data())).toList();
      if(matching.length!=1)continue;
      final cardRef=matching.single,card=cardRef.data();
      final id=parent['documentId'] as String;
      final parentCollection=parent['collection'] as String;
      final originalParent=(await db.collection(parentCollection).doc(id).get()).data();
      final originalCard=(await db.collection('_local_student_documents')
          .doc(cardRef.id).get()).data();
      scope();
      if(originalParent==null||originalCard==null||
         !canStageOriginalPortrait(originalParent)||
         inlinePortraitSource(originalParent)!=
           inlinePortraitSource(parent['data'] as Map)||
         originalCard['documentRevision']!=card['documentRevision']||
         originalCard['localPath']!=card['localPath']||
         originalParent['mobileStableId']!=(parent['data'] as Map)['mobileStableId'])
        continue;
      if(parent['atomicState']==null){
        // The normal outbox preparation owner binds the same immutable
        // Person snapshot; do not use an unprepared or changed wire request.
        if(canAdmit?.call()==false)return completed;
        final photoSource=inlinePortraitSource(parent['data'] as Map);
        final prepared=await WindowsFirebaseRemote.prepareQueuedRecord(
          parentRef.reference,parent,school,
          prepareData:photoSource==null?null:(source) async {
            // Reuse the original immutable outbox wire binding and the usual
            // non-photo media owner. Never Drive-upload the portrait before
            // the Cloudflare-first Person + Photo + Card transaction.
            final safe=Map<String,dynamic>.from(source)
              ..remove('photoBase64')
              ..remove('photoUrl')
              ..remove('photoMimeType');
            return prepareManagedRecord(safe,school,(action,body)=>
              ManagedSchoolSession.callForSchool(school,action,body));
          });
        scope();
        if(prepared==null)continue; // A verified cloud conflict owns it.
        parent=prepared;
        if(!matches(school,parent,card))continue;
      }
      final cardOp=card['documentRevision'] as String;
      final parentOp=parent['operationId'] as String;
      final boundId=bundleId(school,parentOp,cardOp);
      if(parent['atomicBundleId']!=null&&
          parent['atomicBundleId']!=boundId||
         card['atomicBundleId']!=null&&card['atomicBundleId']!=boundId ||
         parent['atomicState']!=card['atomicState'])
        throw StateError('Existing atomic pair has divergent original ownership.');
      final path=(card['optimizedPath']??card['localPath']) as String;
      final bytes=await File(path).readAsBytes();
      scope();
      if(bytes.isEmpty||bytes.length>85*1024)
        throw StateError('Original ID PDF exceeds atomic safety budget.');
      final pdfHash=sha256.convert(bytes).toString();
      if(card['contentHash'] is String&&card['contentHash']!=pdfHash)
        throw StateError('Original queued ID PDF changed before staging.');
      final key=uploadKey(school,cardOp);
      final source=inlinePortraitSource(parent['data'] as Map);
      final portrait=source==null?null:await compute(
        AtomicPortraitPreflight.prepare,originalPortraitBytes(source));
      scope();
      final photoKey=portrait==null?null:photoUploadKey(school,parentOp,cardOp);
      final media=<Map<String,dynamic>>[{
        'kind':'idCard','id':sha256.convert(utf8.encode(jsonEncode([school,key]))).toString(),
        'uploadKey':key,'sha256':pdfHash,'sizeBytes':bytes.length,
        'mime':'application/pdf',
      },if(portrait!=null){
        'kind':'photo',
        'id':sha256.convert(utf8.encode(jsonEncode([school,photoKey]))).toString(),
        'uploadKey':photoKey,'sha256':portrait.sha256,
        'sizeBytes':portrait.bytes.length,'mime':portrait.mime,
      }];
      final personData=parent['wireData'] is Map?
          Map<String,dynamic>.from(parent['wireData'] as Map):
          Map<String,dynamic>.from(parent['data'] as Map);
      if(personData['schoolId']!=school||personData['mobileStableId']!=originalParent['mobileStableId']||
         personData['_syncFieldPatch']!=null||!photoFreeWire(personData))
        throw StateError('Original Person wire snapshot is not an atomic create.');
      final childData=<String,dynamic>{
        'schoolId':school,'studentId':id,
        if(card['ownerRole']=='teacher')'teacherId':id,
        'ownerRole':card['ownerRole'],'personId':card['personId'],
        'documentKind':'idCard','documentId':cardRef.id,
        'documentRevision':cardOp,'contentHash':pdfHash,
        'sizeBytes':bytes.length,'mimeType':'application/pdf',
        'fileName':card['optimizedFileName']??card['fileName']??'$cardOp.pdf',
        if(card['inputRevision'] is String)'inputRevision':card['inputRevision'],
      };
      final ops=<Map<String,dynamic>>[
        {'collection':parentCollection,'id':id,'operation':'write',
         'operationId':parentOp,'expectedRevision':'','data':personData},
        {'collection':'documents','id':cardRef.id,'operation':'write',
         'operationId':cardOp,'expectedRevision':'','data':childData},
      ];
      if(parent['atomicState']==null){
        await db.markAtomicPersonCardOutbox(
          school:school,parentQueueId:parentRef.id,parentBefore:parent,
          documentId:cardRef.id,documentBefore:card,
          bundleId:boundId,state:'reserved');
        scope();
        parent=(await parentRef.reference.get()).data()!;
      }
      var currentCard=(await cardRef.reference.get()).data();
      scope();
      if(currentCard==null||currentCard['atomicBundleId']!=boundId||
         currentCard['documentRevision']!=cardOp)
        throw StateError('Atomic ID generation changed during stage.');
      if(canAdmit?.call()==false)return completed;
      var receipt=await AtomicBundlePilot.receipt(
        school:school,bundleId:boundId,operations:ops,media:media,
        isolatedTest:true);
      scope();
      if(receipt['found']==false){
        // This is the only media staging owner. A retry with an existing
        // receipt does not stage or independently upload the same PDF.
        if(canAdmit?.call()==false)return completed;
        final staged=await AtomicBundlePilot.stage(
          school:school,kind:'idCard',uploadKey:key,
          name:childData['fileName'] as String,mime:'application/pdf',
          bytes:Uint8List.fromList(bytes),isolatedTest:true);
        if(staged['sha256']!=media.first['sha256']||
           staged['id']!=media.first['id'])
          throw StateError('Atomic staged PDF identity changed.');
        if(portrait!=null) {
          if(canAdmit?.call()==false)return completed;
          final stagedPhoto=await AtomicBundlePilot.stage(
            school:school,kind:'photo',uploadKey:photoKey!,
            name:'photo_${portrait.sha256}.${portrait.mime=='image/png'?'png':portrait.mime=='image/webp'?'webp':'jpg'}',
            mime:portrait.mime,bytes:portrait.bytes,isolatedTest:true);
          scope();
          if(stagedPhoto['sha256']!=media[1]['sha256']||
             stagedPhoto['id']!=media[1]['id']||
             stagedPhoto['sizeBytes']!=media[1]['sizeBytes'])
            throw StateError('Original portrait Cloudflare staging proof differs.');
        }
        if(canAdmit?.call()==false)return completed;
        final published=await AtomicBundlePilot.publish(
          school:school,bundleId:boundId,operations:ops,
          media:media,isolatedTest:true);
        scope();
        final acknowledgements=published['acknowledgements'] as List;
        if(parent['atomicState']=='reserved'){
          await db.markAtomicPersonCardOutbox(
            school:school,parentQueueId:parentRef.id,parentBefore:parent,
            documentId:cardRef.id,documentBefore:currentCard,
            bundleId:boundId,state:'committed',
            parentCloudRevision:acknowledgements[0]['recordRevision'] as String,
            documentCloudRevision:acknowledgements[1]['recordRevision'] as String);
          scope();
        }
        receipt=await AtomicBundlePilot.receipt(
          school:school,bundleId:boundId,operations:ops,media:media,
          isolatedTest:true);
      }
      scope();
      if(receipt['found']!=true)throw StateError('Atomic publish not recovered.');
      final backups=(receipt['backups'] as List)
        .map((e)=>Map<String,dynamic>.from(e as Map)).toList();
      if(parent['atomicState']=='reserved'){
        final acks=(receipt['receipt'] as Map)['acknowledgements'] as List;
        final beforeParent=(await parentRef.reference.get()).data()!;
        final beforeCard=(await cardRef.reference.get()).data()!;
        if(beforeParent['atomicState']=='reserved'){
          await db.markAtomicPersonCardOutbox(
            school:school,parentQueueId:parentRef.id,parentBefore:beforeParent,
            documentId:cardRef.id,documentBefore:beforeCard,bundleId:boundId,
            state:'committed',
            parentCloudRevision:acks[0]['recordRevision'] as String,
            documentCloudRevision:acks[1]['recordRevision'] as String);
        }
      }
      if(receipt['driveVerified']!=true)continue;
      if(canAdmit?.call()==false)return completed;
      final remote=<Map<String,dynamic>>[];
      for(final op in ops){
        final answer=await ManagedSchoolSession.callForSchool(school,'managed/live/read',{
          'liveProtocol':1,'collection':op['collection'],'id':op['id']});
        scope();
        final record=answer['record'];
        if(answer['success']!=true||answer['schoolId']!=school||
           answer['liveProtocol']!=1||record is! Map||
           answer['recordRevision']!=backups[remote.length]['recordRevision']||
           record['_syncRevision']!=answer['recordRevision']||
           record['_syncOperationId']!=op['operationId'])
          throw StateError('Signed current live record differs from verified backup.');
        remote.add(Map<String,dynamic>.from(record));
      }
      final finalParent=(await parentRef.reference.get()).data();
      final finalCard=(await cardRef.reference.get()).data();
      scope();
      if(finalParent==null||finalCard==null)
        throw StateError('Atomic outbox was replaced before Drive receipt.');
      await db.finishVerifiedAtomicPersonCardOutbox(
        school:school,parentQueueId:parentRef.id,parentBefore:finalParent,
        parentLocalBefore:originalParent,documentId:cardRef.id,
        documentBefore:finalCard,documentLocalBefore:originalCard,
        bundleId:boundId,parentCloud:remote[0],documentCloud:remote[1],
        verifiedBackups:backups,cardSha256:pdfHash);
      scope();completed++;
    }
    return completed;
  }
}

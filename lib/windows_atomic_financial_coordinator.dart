import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import 'windows_local_firestore.dart';
import 'windows_firebase_sync.dart';
import 'windows_connect/atomic_bundle_pilot.dart';
import 'windows_connect/managed_school_session.dart';

/// TEST-only financial original-queue coordinator. The already durable fee
/// payment, fee ledger and receipt queues remain the only local Save owners.
/// No independent Cloudflare/Drive uploader or retry queue is introduced.
class WindowsAtomicFinancialCoordinator {
  const WindowsAtomicFinancialCoordinator._();

  static String bundleId(String school,List<String> ids) =>
    'fb-${sha256.convert(utf8.encode(jsonEncode([school,...ids])))}';

  static String uploadKey(String school,String revision) =>
    'pdf-${sha256.convert(utf8.encode(jsonEncode([school,revision])))}';

  static bool matchesFee(String school,Map<String,dynamic> payment,
      Map<String,dynamic> ledger,Map<String,dynamic> doc) {
    final p=payment['data'],l=ledger['data'];
    final paymentId=payment['documentId'],docId=doc['documentId'];
    if(!RegExp(r'^vs-[a-f0-9]{32}$').hasMatch(school)||
       payment['schoolId']!=school||ledger['schoolId']!=school||
       doc['schoolId']!=school||payment['collection']!='fee_payments'||
       ledger['collection']!='fee_ledger'||
       payment['operation']!='set'||ledger['operation']!='set'||
       payment['createIntent']!=true||
       payment['baseCloudRevision']!=''||
       payment['priorDeletion']!=null||ledger['priorDeletion']!=null||
       payment['fieldPatch']!=null||ledger['fieldPatch']!=null||
       payment['operationId'] is! String||ledger['operationId'] is! String||
       paymentId is! String||paymentId.isEmpty||
       paymentId.length>200||p is! Map||l is! Map||
       p['schoolId']!=school||l['schoolId']!=school||
       p['paymentId']!=paymentId||p['receiptDocumentId']!=docId||
       p['studentId'] is! String||p['studentId'].isEmpty||
       p['month'] is! String||p['month'].isEmpty||
       l['studentId']!=p['studentId']||l['month']!=p['month']||
       l['lastPaymentId']!=paymentId||
       l['totalPaid']!=p['totalPaid']||l['expectedAmount']!=p['expectedAmount']||
       doc['documentKind']!='feeReceipt'||doc['deleted']==true||
       doc['baseCloudRevision']!=''||doc['studentId']!=p['studentId']||
       doc['ownerRole']!='student'||doc['personId'] is! String||
       doc['personId'].isEmpty||doc['documentRevision'] is! String||
       doc['contentHash'] is! String||
       !RegExp(r'^[a-f0-9]{64}$').hasMatch(doc['contentHash'])||
       (doc['optimizedMimeType']??doc['mimeType'])!='application/pdf'||
       (doc['optimizedPath']??doc['localPath']) is! String)
      return false;
    final ids=[payment['operationId'],ledger['operationId'],doc['documentRevision']];
    return ids.every((id)=>id is String&&
      RegExp(r'^[A-Za-z0-9_-]{16,100}$').hasMatch(id))&&
      ids.toSet().length==3 &&
      [payment,ledger,doc].every((r)=>r['atomicBundleId']==null||
        r['atomicState']=='reserved'||r['atomicState']=='committed');
  }

  static Future<int> run(String school,{bool Function()? canAdmit}) async {
    if(!AtomicBundlePilot.buildEnabled)return 0;
    final db=FirebaseFirestore.instance,profile=db.activeProfileId;
    if(db.activeProfileIdentity['schoolSyncId']!=school||
       !await db.localPersistenceEnabled())
      throw StateError('School financial atomic work needs durable local storage.');
    void scope(){
      if(db.activeProfileId!=profile||db.activeProfileIdentity['schoolSyncId']!=school)
        throw StateError('School changed during financial atomic sync.');
    }
    final rows=(await db.collection('_windows_firebase_outbox').get()).docs;
    final docs=(await db.collection('_windows_document_outbox').get()).docs;
    scope();
    var completed=0;
    for(final paymentRef in rows) {
      if(canAdmit?.call()==false)break;
      scope();
      var payment=paymentRef.data();
      if(payment['collection']!='fee_payments'||payment['operation']!='set'||
         payment['baseCloudRevision']!='')continue;
      final payData=payment['data'];
      if(payData is! Map||payData['receiptDocumentId'] is! String)continue;
      final pdfRows=docs.where((x)=>x.id==payData['receiptDocumentId']).toList();
      if(pdfRows.length!=1)continue;
      final documentRef=pdfRows.single;
      final document=documentRef.data();
      final ledgers=rows.where((row)=>row.data()['collection']=='fee_ledger'&&
        row.data()['data'] is Map&&
        row.data()['data']['lastPaymentId']==payment['documentId']&&
        matchesFee(school,payment,row.data(),document)).toList();
      if(ledgers.length!=1)continue;
      final ledgerRef=ledgers.single;
      var ledger=ledgerRef.data();
      final localRefs=[db.collection('fee_payments').doc(payment['documentId'] as String),
        db.collection('fee_ledger').doc(ledger['documentId'] as String)];
      final locals=<Map<String,dynamic>>[];
      for(final ref in localRefs){
        final entry=(await ref.get()).data();
        if(entry==null)throw StateError('Original fee or ledger Save missing.');
        locals.add(entry);
      }
      final localDoc=(await db.collection('_local_student_documents')
        .doc(documentRef.id).get()).data();
      scope();
      if(localDoc==null||localDoc['documentRevision']!=document['documentRevision']||
         localDoc['localPath']!=document['localPath']||
         locals[0]['paymentId']!=payment['documentId']||
         locals[1]['lastPaymentId']!=payment['documentId'])continue;
      if(payment['atomicState']==null){
        final preparedPayment=await WindowsFirebaseRemote.prepareQueuedRecord(
          paymentRef.reference,payment,school);
        scope();if(preparedPayment==null)continue;
        payment=preparedPayment;
      }
      if(ledger['atomicState']==null){
        final preparedLedger=await WindowsFirebaseRemote.prepareQueuedRecord(
          ledgerRef.reference,ledger,school);
        scope();if(preparedLedger==null)continue;
        ledger=preparedLedger;
      }
      if(!matchesFee(school,payment,ledger,document))continue;
      final ids=[payment['operationId'] as String,ledger['operationId'] as String,
        document['documentRevision'] as String];
      final key=uploadKey(school,ids.last),bundle=bundleId(school,ids);
      if([payment,ledger,document].any((row)=>
           row['atomicBundleId']!=null&&row['atomicBundleId']!=bundle)||
         payment['atomicState']!=ledger['atomicState']||
         ledger['atomicState']!=document['atomicState'])
        throw StateError('Original fee/ledger/PDF reservation diverged.');
      final path=(document['optimizedPath']??document['localPath']) as String;
      final bytes=await File(path).readAsBytes();
      scope();
      if(bytes.isEmpty||bytes.length>30*1024||
         sha256.convert(bytes).toString()!=document['contentHash'])
        throw StateError('Original receipt bytes changed or exceed 30 KiB.');
      final sha=document['contentHash'] as String;
      final fileId=sha256.convert(utf8.encode(jsonEncode([school,key]))).toString();
      final media=[<String,dynamic>{'kind':'receipt','id':fileId,
        'uploadKey':key,'sha256':sha,'sizeBytes':bytes.length,'mime':'application/pdf'}];
      Map<String,dynamic> record(Map<String,dynamic> outbox) =>
        Map<String,dynamic>.from(outbox['wireData'] is Map?
          outbox['wireData'] as Map:outbox['data'] as Map);
      final parent=record(payment),balance=record(ledger);
      if(parent['_syncFieldPatch']!=null||balance['_syncFieldPatch']!=null||
         parent['schoolId']!=school||balance['schoolId']!=school)
        throw StateError('Unverified financial patch cannot become an atomic write.');
      final child=<String,dynamic>{
        'schoolId':school,'studentId':document['studentId'],
        'personId':document['personId'],'ownerRole':'student',
        'documentKind':'feeReceipt','documentId':documentRef.id,
        'documentRevision':document['documentRevision'],
        'contentHash':sha,'mimeType':'application/pdf',
        'sizeBytes':bytes.length,'fileName':document['fileName']??'receipt.pdf',
      };
      final operations=<Map<String,dynamic>>[
        {'collection':'fee_payments','id':payment['documentId'],
         'operation':'write','operationId':ids[0],
         'expectedRevision':payment['baseCloudRevision']??'','data':parent},
        {'collection':'fee_ledger','id':ledger['documentId'],
         'operation':'write','operationId':ids[1],
         'expectedRevision':ledger['baseCloudRevision']??'','data':balance},
        {'collection':'documents','id':documentRef.id,
         'operation':'write','operationId':ids[2],
         'expectedRevision':'','data':child},
      ];
      List<Map<String,dynamic>> queued()=>[
        {'queueId':paymentRef.id,'before':payment},
        {'queueId':ledgerRef.id,'before':ledger},
      ];
      if(payment['atomicState']==null){
        await db.markAtomicFinancialOutbox(school:school,bundleId:bundle,
          parents:queued(),documentId:documentRef.id,documentBefore:document,
          state:'reserved');
        scope();
        payment=(await paymentRef.reference.get()).data()!;
        ledger=(await ledgerRef.reference.get()).data()!;
      }
      var currentDoc=(await documentRef.reference.get()).data()!;
      scope();
      if(currentDoc['atomicBundleId']!=bundle||
         currentDoc['documentRevision']!=ids[2])
        throw StateError('Original receipt changed during atomic reservation.');
      if(canAdmit?.call()==false)return completed;
      var receipt=await AtomicBundlePilot.receipt(
        school:school,bundleId:bundle,operations:operations,
        media:media,isolatedTest:true);
      scope();
      if(receipt['found']==false){
        final staged=await AtomicBundlePilot.stage(
          school:school,kind:'receipt',uploadKey:key,
          name:(document['optimizedFileName']??document['fileName']??'receipt.pdf') as String,
          mime:'application/pdf',bytes:Uint8List.fromList(bytes),isolatedTest:true);
        scope();
        if(staged['id']!=fileId||staged['sha256']!=sha)
          throw StateError('Original receipt Cloudflare staged proof changed.');
        final published=await AtomicBundlePilot.publish(
          school:school,bundleId:bundle,operations:operations,
          media:media,isolatedTest:true);
        scope();
        if(payment['atomicState']=='reserved'){
          await db.markAtomicFinancialOutbox(school:school,bundleId:bundle,
            parents:queued(),documentId:documentRef.id,documentBefore:currentDoc,
            state:'committed',cloudRevisions:[
              for(final ack in published['acknowledgements'] as List)
                (ack as Map)['recordRevision'] as String,
            ]);
          scope();
        }
        receipt=await AtomicBundlePilot.receipt(
          school:school,bundleId:bundle,operations:operations,
          media:media,isolatedTest:true);
      }
      scope();
      if(receipt['found']!=true)throw StateError('Financial atomic receipt lost.');
      if(payment['atomicState']=='reserved'){
        final ack=(receipt['receipt'] as Map)['acknowledgements'] as List;
        final currentPayment=(await paymentRef.reference.get()).data()!;
        final currentLedger=(await ledgerRef.reference.get()).data()!;
        final currentPDF=(await documentRef.reference.get()).data()!;
        scope();
        if(currentPayment['atomicState']=='reserved'){
          await db.markAtomicFinancialOutbox(school:school,bundleId:bundle,
            parents:[{'queueId':paymentRef.id,'before':currentPayment},
              {'queueId':ledgerRef.id,'before':currentLedger}],
            documentId:documentRef.id,documentBefore:currentPDF,
            state:'committed',cloudRevisions:[
              for(final entry in ack)
                (entry as Map)['recordRevision'] as String,
            ]);
          scope();
        }
      }
      if(receipt['driveVerified']!=true)continue;
      if(canAdmit?.call()==false)return completed;
      final backups=(receipt['backups'] as List)
        .map((e)=>Map<String,dynamic>.from(e as Map)).toList();
      final remote=<Map<String,dynamic>>[];
      for(final op in operations){
        final answer=await ManagedSchoolSession.callForSchool(school,
          'managed/live/read',{'liveProtocol':1,
            'collection':op['collection'],'id':op['id']});
        scope();
        final record=answer['record'];
        if(answer['success']!=true||answer['schoolId']!=school||
           answer['liveProtocol']!=1||record is! Map||
           answer['recordRevision']!=backups[remote.length]['recordRevision']||
           record['_syncRevision']!=answer['recordRevision']||
           record['_syncOperationId']!=op['operationId'])
          throw StateError('Financial signed Drive readback identity differs.');
        remote.add(Map<String,dynamic>.from(record));
      }
      final finalPayment=(await paymentRef.reference.get()).data()!;
      final finalLedger=(await ledgerRef.reference.get()).data()!;
      final finalPDF=(await documentRef.reference.get()).data()!;
      scope();
      await db.finishVerifiedAtomicFinancialOutbox(
        school:school,bundleId:bundle,
        parents:[{'queueId':paymentRef.id,'before':finalPayment},
          {'queueId':ledgerRef.id,'before':finalLedger}],
        parentLocalBefore:locals,documentId:documentRef.id,
        documentBefore:finalPDF,documentLocalBefore:localDoc,
        cloudRecords:remote,verifiedBackups:backups,pdfSha256:sha);
      scope();completed++;
    }
    return completed;
  }
}

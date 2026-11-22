import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../lib/cloudflare_record_handoff.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_drive_delivery_queue.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';

const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const other='vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const foreignTicket='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
String exactTicket(Map original) => sha256.convert(utf8.encode(jsonEncode([
  school,'managed_records',[
    original['collection'],original['documentId'],original['operationId'],
  ]
]))).toString();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db=FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile('staged-test-${DateTime.now().microsecondsSinceEpoch}',
      identity:{'schoolSyncId':school});
  });

  test('real records enter two-phase only with authenticated broker capability', () {
    final row={'schoolId':school,'collection':'school_calendar',
      'documentId':'event-1','operation':'set','operationId':'original-op-1234567890',
      'baseCloudRevision':'','data':{'title':'Real event'}};
    expect(eligibleForRecordHandoff(row,school,edgeDeliverySupported:false),false);
    expect(eligibleForRecordHandoff(row,school,edgeDeliverySupported:true),true);
    expect(eligibleForRecordHandoff({...row,'schoolId':other},school,edgeDeliverySupported:true),false);
    for(final collection in ['students_directory','teachers_directory',
      'fee_payments','fee_ledger','attendance_records','school_expenses']) {
      expect(eligibleForRecordHandoff({...row,'collection':collection},school,
        edgeDeliverySupported:true),true);
    }
    expect(eligibleForRecordHandoff({...row,'collection':'documents'},school,
      edgeDeliverySupported:true),false);
    expect(eligibleForRecordHandoff({...row,'operation':'delete'},school,
      edgeDeliverySupported:true),false);
    expect(eligibleForRecordHandoff({...row,'atomicBundleId':'owner-123'},school,
      edgeDeliverySupported:true),false);
    expect(eligibleForRecordHandoff({...row,'priorDeletion':{'operation':'delete'}},school,
      edgeDeliverySupported:true),false);
  });

  test('missing journal binding requires exact already accepted school ticket', () {
    const operation='journal-recovery-original-001';
    final original=<String,dynamic>{
      'schoolId':school,'collection':'school_calendar','documentId':'repair-calendar',
      'operation':'set','operationId':operation,'syncState':'cloudAccepted',
      'baseCloudRevision':'base','data':{'title':'Existing'},
    };
    final ticket=exactTicket(original);
    final accepted={...original,'cloudTicketId':ticket,'cloudTicketLane':'records'};
    final bound=acceptedCloudflareTicketBinding(accepted,school);
    expect(bound?['action'],'managed/records');
    expect(bound?['ticketId'],ticket);
    expect(bound?['originalOperationId'],operation);
    expect(acceptedCloudflareTicketBinding({...accepted,'cloudTicketId':foreignTicket},school),isNull);
    expect(acceptedCloudflareTicketBinding({...accepted,'schoolId':other},school),isNull);
    expect(acceptedCloudflareTicketBinding({...accepted,'syncState':'pending'},school),isNull);
    expect(acceptedCloudflareTicketBinding({...accepted,'priorDeletion':{}},school),isNull);
    expect(acceptedCloudflareTicketBinding({...accepted,'atomicBundleId':'owner'},school),isNull);
  });

  test('missing document receipt rebinds original file identity without collection field', () {
    const id='journal-document',op='document-generation-original-001';
    final content=List.filled(64,'a').join();
    final uploadKey=sha256.convert(utf8.encode('$id:$op')).toString();
    final ticket=sha256.convert(utf8.encode(jsonEncode([school,uploadKey]))).toString();
    final original=<String,dynamic>{
      'schoolId':school,'documentRevision':op,'contentHash':content,
      'cloudContentHash':content,'syncState':'cloudAccepted',
      'cloudTicketId':ticket,'cloudTicketLane':'file-$ticket','deleted':false,
    };
    final bound=acceptedCloudflareTicketBinding(original,school,queueId:id);
    expect(bound?['action'],'managed/document/stage/resumable');
    expect(bound?['id'],id);
    expect(bound?['fileSha256'],content);
    expect(bound?['ticketId'],ticket);
    expect(acceptedCloudflareTicketBinding({
      ...original,'cloudContentHash':List.filled(64,'b').join(),
    },school,queueId:id),isNull);
    expect(acceptedCloudflareTicketBinding({...original,'deleted':true},
      school,queueId:id),isNull);
    expect(acceptedCloudflareTicketBinding({...original,'cloudTicketId':foreignTicket},
      school,queueId:id),isNull);
  });

  test('missing school-scoped original record journal reconstructs through read-only broker status', () async {
    const id='untracked-calendar',op='untracked-record-operation-001';
    final original=<String,dynamic>{
      'schoolId':school,'collection':'school_calendar','documentId':id,
      'operation':'set','operationId':op,'baseCloudRevision':'',
      'syncState':'cloudAccepted','data':{'title':'Retained'},
    };
    final ticket=exactTicket(original);
    final ref=db.collection('_windows_firebase_outbox').doc('untracked-calendar-row');
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() => ref.set({
      ...original,'cloudTicketLane':'records','cloudTicketId':ticket,
    }));
    var reads=0;
    await WindowsDriveDeliveryQueue.poll(school,call:(action,body) async {
      reads++;
      expect(action,'managed/cloudflare/operation');
      expect(body['id'],ticket);
      expect(body['lane'],'records');
      return {'success':true,'schoolId':school,'cloudflareAccepted':true,
        'driveState':'verified','syncProtocol':2,'recordRevision':'provider-final-revision',
        'record':{'schoolId':school,'_syncRevision':'provider-final-revision',
          '_syncOperationId':op,'id':id}};
    });
    expect(reads,2,reason:'one authenticated reconstruction and one owner receipt read');
    expect((await ref.get()).exists,false);
    final history=await WindowsDriveDeliveryQueue.history(school);
    expect(history.single['state'],'completed');
  });

  test('missing document journal reconstructs from verified original with no bytes replay', () async {
    const id='untracked-document',op='untracked-document-operation-001';
    final content=List.filled(64,'a').join();
    final key=sha256.convert(utf8.encode('$id:$op')).toString();
    final ticket=sha256.convert(utf8.encode(jsonEncode([school,key]))).toString();
    final original=<String,dynamic>{
      'schoolId':school,'documentRevision':op,
      'contentHash':content,'cloudContentHash':content,
      'localPath':'/synthetic/does-not-need-reopening.pdf',
      'cloudTicketId':ticket,'cloudTicketLane':'file-$ticket',
      'syncState':'cloudAccepted','deleted':false,
    };
    final outbox=db.collection('_windows_document_outbox').doc(id);
    final local=db.collection('_local_student_documents').doc(id);
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() async {
      await outbox.set(original);
      await local.set(original);
    });
    var reads=0;
    await WindowsDriveDeliveryQueue.poll(school,call:(action,body) async {
      reads++;
      expect(action,'managed/cloudflare/operation');
      expect(body['id'],ticket);
      expect(body['lane'],'file-$ticket');
      return {'success':true,'schoolId':school,'cloudflareAccepted':true,
        'driveState':'verified','committed':true,
        'fileId':'original-drive-file','fileUrl':'https://drive.google.com/file/d/original-drive-file/view',
        'sha256':content,
        'documentRecord':{'id':id,'operationId':op,
          'contentHash':content,'fileId':'original-drive-file',
          'recordRevision':'original-document-record-revision'}};
    });
    expect(reads,2);
    expect((await outbox.get()).exists,false);
    expect((await local.get()).data()?['syncState'],'Synced');
    expect((await local.get()).data()?['cloudRecordRevision'],'original-document-record-revision');
  });

  test('authorized journal restores interrupted local handoff without another mutation', () async {
    const id='restart-calendar';
    const op='restart-original-operation-001';
    final original=<String,dynamic>{
      'schoolId':school,'collection':'school_calendar','documentId':id,
      'operation':'set','operationId':op,'baseCloudRevision':'',
      'syncState':'pending','data':{'title':'Retained original'},
    };
    final ref=db.collection('_windows_firebase_outbox').doc('restart-calendar-row');
    final ticket=exactTicket(original);
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() => ref.set(original));
    await WindowsDriveDeliveryQueue.retainEdge({
      'source':List.filled(64,'e').join(),'schoolId':school,
      'profileId':db.activeProfileId,'action':'managed/records',
      'collection':'school_calendar','id':id,'operation':'write',
      'originalOperationId':op,'handoffAuthorized':true,
      'proof':{'success':true,'schoolId':school,'edgeDeliveryVersion':1,
        'cloudflareAccepted':true,'driveState':'pending',
        'delivery':{'lane':'records','id':ticket}},
    });
    var sends=0;
    await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
      send:(_,__,___,____) async => fail('Legacy send is unsafe'),
      sendVersioned:(_) async {sends++;return 'unexpected';});
    expect(sends,0);
    final retained=(await ref.get()).data()!;
    expect(retained['operationId'],op);
    expect(retained['syncState'],'cloudAccepted');
    expect(retained['cloudTicketId'],ticket);
    expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty);
    await WindowsDriveDeliveryQueue.poll(school,call:(action,body) async {
      expect(action,'managed/cloudflare/operation');
      expect(body['id'],ticket);
      return {'success':true,'schoolId':school,'cloudflareAccepted':true,
        'driveState':'verified','syncProtocol':2,'recordRevision':'drive-restart-revision',
        'record':{'schoolId':school,'id':id,'_syncOperationId':op,
          '_syncRevision':'drive-restart-revision'}};
    });
    expect((await ref.get()).exists,false);
  });

  test('staged predecessor settles without deleting a newer local edit', () async {
    final record=db.collection('school_calendar').doc('ordered-calendar');
    await record.set({'title':'Original'});
    final initial=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    final original=initial.data(), ticket=exactTicket(original);
    await WindowsDriveDeliveryQueue.retainEdge({
      'source':List.filled(64,'f').join(),'schoolId':school,
      'profileId':db.activeProfileId,'action':'managed/records',
      'collection':'school_calendar','id':'ordered-calendar','operation':'write',
      'originalOperationId':original['operationId'],'handoffAuthorized':true,
      'proof':{'success':true,'schoolId':school,'edgeDeliveryVersion':1,
        'cloudflareAccepted':true,'driveState':'pending',
        'delivery':{'lane':'records','id':ticket}},
    });
    await db.recordOutboxCloudHandoff(initial.reference,original,ticketId:ticket);
    await record.set({'title':'Newer'});
    final newer=(await initial.reference.get()).data()!;
    expect(newer['operationId'],isNot(original['operationId']));
    expect(newer['priorCloudWrite']['operationId'],original['operationId']);
    var sends=0;
    await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
      send:(_,__,___,____) async => fail('Legacy send is unsafe'),
      sendVersioned:(_) async {sends++;return 'unexpected';});
    expect(sends,0);
    var settlements=0;
    await WindowsDriveDeliveryQueue.poll(school,onLocalSettlement:()=>settlements++,call:(action,body) async {
      expect(action,'managed/cloudflare/operation');
      expect(body['id'],ticket);
      return {'success':true,'schoolId':school,'cloudflareAccepted':true,
        'driveState':'verified','syncProtocol':2,'recordRevision':'drive-ordered-revision',
        'record':{'schoolId':school,'id':'ordered-calendar',
          '_syncOperationId':original['operationId'],'_syncRevision':'drive-ordered-revision'}};
    });
    expect(settlements,1);
    final retained=(await initial.reference.get()).data()!;
    expect(retained['operationId'],newer['operationId']);
    expect(retained['priorCloudWrite'],isNull);
    expect(retained['baseCloudRevision'],'drive-ordered-revision');
    expect((await record.get()).data()!['title'],'Newer');
    await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
      send:(_,__,___,____) async => fail('Legacy send is unsafe'),
      sendVersioned:(item) async {
        sends++;
        expect(item['operationId'],newer['operationId']);
        expect(item['baseCloudRevision'],'drive-ordered-revision');
        return 'drive-newer-revision';
      });
    expect(sends,1);
    expect((await initial.reference.get()).exists,false);
  });

  test('local save during in-flight record handoff preserves newer owner', () async {
    final record=db.collection('school_calendar').doc('inflight-calendar');
    await record.set({'title':'Original'});
    final initial=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    final original=initial.data(), ticket=exactTicket(original);
    await record.set({'title':'Newer'});
    final newer=(await initial.reference.get()).data()!;
    expect(await db.recordOutboxCloudHandoff(initial.reference,original,ticketId:ticket),true);
    final retained=(await initial.reference.get()).data()!;
    expect(retained['operationId'],newer['operationId']);
    expect(retained['priorCloudWrite']['operationId'],original['operationId']);
    expect(retained['syncState'],'pending');
    expect((await record.get()).data()!['title'],'Newer');
  });

  test('restart journal cannot grant ownership for foreign ticket or operation', () {
    final row={'schoolId':school,'collection':'school_calendar',
      'documentId':'event-1','operation':'set','operationId':'restart-operation-002',
      'baseCloudRevision':'','syncState':'pending','data':{'title':'Original'}};
    final journal={'schoolId':school,'edgeDeliveryVersion':1,
      'cloudflareAccepted':true,'handoffAuthorized':true,
      'action':'managed/records','state':'pending','lane':'records',
      'ticketId':exactTicket(row),'originalOperationId':row['operationId'],
      'collection':'school_calendar','id':'event-1','operation':'write'};
    expect(recoverableStagedRecordJournal(row,journal,school),true);
    expect(recoverableStagedRecordJournal(row,{...journal,'ticketId':foreignTicket},school),false);
    expect(recoverableStagedRecordJournal(row,{...journal,'handoffAuthorized':false},school),false);
    expect(recoverableStagedRecordJournal({...row,'operationId':'new-operation-0000003'},journal,school),false);
    expect(recoverableStagedRecordJournal({...row,'atomicBundleId':'owner'},journal,school),false);
  });

  test('a real student outbox cannot be silently made cloud-owned by a stray receipt', () async {
    await db.collection('students_directory').doc('real-student')
      .set({'schoolId':school,'name':'Real school record'});
    final row=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    final before=row.data();
    await expectLater(db.recordOutboxCloudHandoff(
      row.reference,before,ticketId:foreignTicket),throwsStateError);
    final after=(await row.reference.get()).data()!;
    expect(after['syncState'],before['syncState']);
    expect(after['operationId'],before['operationId']);
    expect(after['baseCloudRevision'],before['baseCloudRevision']);
    expect(after['data'],before['data']);
    expect((after['queuedAt'] as Timestamp).millisecondsSinceEpoch,
      (before['queuedAt'] as Timestamp).millisecondsSinceEpoch);
  });
  test('original CAS is retained at Cloudflare acceptance; only broker Drive proof retires it', () async {
    await db.collection('students_directory').doc('real-student-1')
      .set({'schoolId':school,'name':'Real student saved locally'});
    final row=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    final original=row.data();
    expect(original['operationId'],isA<String>());
    final ticket=exactTicket(original);

    await WindowsDriveDeliveryQueue.retainEdge({
      'source':'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'schoolId':school,'profileId':db.activeProfileId,
      'action':'managed/records','collection':'students_directory','id':'real-student-1',
      'operation':'write','originalOperationId':original['operationId'],
      'proof':{'success':true,'schoolId':school,
        'edgeDeliveryVersion':1,'cloudflareAccepted':true,
        'driveState':'pending','delivery':{'lane':'records','id':ticket}},
    });
    var mutationCalls=0;
    await WindowsPendingSchoolSync.flush(
      profileId:db.activeProfileId,
      send:(a,b,c,d) async => fail('Unexpected legacy send'),
      sendVersioned:(item) async {
        mutationCalls++;
        throw CloudflareRecordHandoff(
          school:school,collection:'students_directory',id:'real-student-1',
          operationId:original['operationId'],ticketId:ticket);
      },
    );
    expect(mutationCalls,1,reason:'one durable owner admission');
    final retained=(await row.reference.get()).data()!;
    expect(retained['syncState'],'cloudAccepted');
    expect(retained['operationId'],original['operationId']);
    expect(retained['baseCloudRevision'],original['baseCloudRevision']);
    expect(retained['data'],original['data']);
    expect((await WindowsDriveDeliveryQueue.history(school)).single['state'],'pending');

    var polls=0;
    await WindowsDriveDeliveryQueue.poll(school,call:(action,body) async {
      polls++;
      expect(action,'managed/cloudflare/operation');
      expect(body['lane'],'records');
      expect(body['id'],ticket);
      return {'success':true,'schoolId':school,
        'cloudflareAccepted':true,'driveState':'verified',
        'syncProtocol':2,'recordRevision':'drive-revision-001',
        'record':{'schoolId':school,'id':'real-student-1',
          '_syncRevision':'drive-revision-001',
          '_syncOperationId':original['operationId']}};
    });
    expect(polls,1,reason:'status read only, no duplicate record write');
    expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
    expect((await WindowsDriveDeliveryQueue.history(school)).single['state'],'completed');
  });

  test('staged delete is limited to independently safe calendar operations', () {
    final row={'schoolId':school,'collection':'school_calendar',
      'documentId':'calendar-delete-1','operation':'delete',
      'operationId':'delete-original-operation-01','baseCloudRevision':'old-revision-1'};
    bool eligible(Map item) => eligibleForStagedDelete(item,school,edgeDeliverySupported:true);
    expect(eligible(row),true);
    expect(eligibleForStagedDelete(row,school,edgeDeliverySupported:false),false);
    for(final c in ['students_directory','teachers_directory','documents',
        'fee_payments','attendance_records','school_notices']) {
      expect(eligible({...row,'collection':c}),false);
    }
    expect(eligible({...row,'schoolId':other}),false);
    expect(eligible({...row,'baseCloudRevision':''}),false);
    expect(eligible({...row,'priorDeletion':row}),false);
    expect(eligible({...row,'atomicBundleId':'owner'}),false);
    expect(eligible({...row,'requireCanonicalDeleteReceipt':true}),false);
  });

  test('calendar delete requires exact complete provider tombstone proof', () async {
    const id='calendar-delete-2',op='delete-original-operation-02';
    final original=<String,dynamic>{
      'schoolId':school,'collection':'school_calendar','documentId':id,
      'operation':'delete','operationId':op,'baseCloudRevision':'base-01',
      'syncState':'pending',
    };
    final ticket=exactTicket(original);
    final ref=db.collection('_windows_firebase_outbox').doc('calendar-delete-row');
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() => ref.set(original));
    final journal={
      'source':'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      'schoolId':school,'profileId':db.activeProfileId,
      'action':'managed/records','collection':'school_calendar','id':id,
      'operation':'delete','originalOperationId':op,
      'proof':{'success':true,'schoolId':school,'edgeDeliveryVersion':1,
        'cloudflareAccepted':true,'driveState':'pending',
        'delivery':{'lane':'records','id':ticket}},
    };
    await WindowsDriveDeliveryQueue.retainEdge(journal);
    final live=(await ref.get()).data()!;
    expect(await db.recordOutboxCloudHandoff(ref,live,ticketId:ticket),true);
    final accepted=(await ref.get()).data()!;
    final proof=<String,dynamic>{
      'success':true,'schoolId':school,'cloudflareAccepted':true,
      'driveState':'verified','syncProtocol':2,'recordRevision':'delete-revision-02',
      'deleteEverywhereVersion':1,'driveDeletionComplete':true,
      'firebaseDeletionComplete':true,
      'record':{'schoolId':school,'id':id,'_syncDeleted':true,
        '_syncRevision':'delete-revision-02','_syncOperationId':op,
        '_syncErasePlan':{'complete':true}},
    };
    final binding={...journal,'ticketId':ticket};
    expect(verifiedStagedRecordFinal(accepted,binding,proof,school),true);
    expect(verifiedStagedRecordFinal(accepted,binding,
      {...proof,'firebaseDeletionComplete':false},school),false);
    expect(verifiedStagedRecordFinal(accepted,binding,
      {...proof,'driveDeletionComplete':false},school),false);
    expect(verifiedStagedRecordFinal(accepted,binding,
      {...proof,'record':{...proof['record'] as Map,'_syncErasePlan':{'complete':false}}},school),false);
    expect(verifiedStagedRecordFinal(accepted,binding,
      {...proof,'record':{...proof['record'] as Map,'_syncOperationId':'wrong-operation'}},school),false);
    expect(verifiedStagedRecordFinal(accepted,binding,
      {...proof,'recordRevision':'cf-stage-only'},school),false);
    // Only canonical provider proof may retire the pending delete through the
    // existing receipt journal. Staging alone leaves the original intact.
    expect((await ref.get()).data()?['syncState'],'cloudAccepted');
    await WindowsDriveDeliveryQueue.poll(school,call:(action,body) async {
      expect(action,'managed/cloudflare/operation');
      expect(body['id'],ticket);
      return proof;
    });
    expect((await ref.get()).exists,false);
    expect((await WindowsDriveDeliveryQueue.history(school)).single['state'],'completed');
  });

  test('edge receipt status is independent of slow live status and honors provider deadline', () async {
    final journal=db.collection(WindowsDriveDeliveryQueue.collection);
    final ticket=List.filled(64,'d').join();
    const operation='live-operation-00000001';
    final now=DateTime.utc(2026,11,22,12);
    final deadline=now.add(const Duration(minutes:2)).millisecondsSinceEpoch;
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() async {
      await journal.doc('live-receipt').set({
        'schoolId':school,'liveProtocol':1,'operationId':operation,
        'recordRevision':'live-revision-01','state':'pending','nextPollAt':0,
      });
      await journal.doc('edge-receipt').set({
        'schoolId':school,'edgeDeliveryVersion':1,'operationId':'edge-operation-00000001',
        'ticketId':ticket,'lane':'records','state':'pending','nextPollAt':0,
      });
    });
    final liveRelease=Completer<void>(), edgeEntered=Completer<void>();
    final poll=WindowsDriveDeliveryQueue.poll(school,clock:()=>now,call:(action,body)async{
      if(action=='managed/live/operationReceipt') {
        await liveRelease.future;
        return {'success':true,'schoolId':school,'liveProtocol':1,
          'operationId':operation,'found':true,'receipt':{
            'schoolId':school,'operationId':operation,'recordRevision':'live-revision-01',
            'backupState':'pending',
          }};
      }
      expect(action,'managed/cloudflare/operation');
      expect(body['id'],ticket);
      edgeEntered.complete();
      return {'success':true,'schoolId':school,'cloudflareAccepted':true,
        'driveState':'pending','delivery':{'lane':'records','id':ticket},
        'deliveryStatus':{'state':'retry','retryAtMillis':deadline}};
    });
    try {
      await edgeEntered.future.timeout(const Duration(seconds:5));
      expect(liveRelease.isCompleted,false);
    } finally {
      liveRelease.complete();
      await poll;
    }
    final edge=(await journal.doc('edge-receipt').get()).data()!;
    expect(edge['nextPollAt'],deadline);
    expect(edge['state'],'pending');
    var edgePolls=0;
    await WindowsDriveDeliveryQueue.poll(school,
      clock:()=>now.add(const Duration(seconds:1)),
      call:(action,body) async {
        if(action=='managed/cloudflare/operation')edgePolls++;
        return {};
      });
    expect(edgePolls,0,reason:'provider retry deadline must not be bypassed');
  });

  test('invalid final revision does not retire accepted original', () async {
    await db.collection('school_calendar').doc('event-2')
      .set({'schoolId':school,'syntheticTest':true,'title':'Synthetic test'});
    final row=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    final original=row.data();
    final ticket=exactTicket(original);
    await WindowsDriveDeliveryQueue.retainEdge({
      'source':'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      'schoolId':school,'profileId':db.activeProfileId,
      'action':'managed/records','collection':'school_calendar','id':'event-2',
      'operation':'write','originalOperationId':original['operationId'],
      'proof':{'success':true,'schoolId':school,'edgeDeliveryVersion':1,
        'cloudflareAccepted':true,'driveState':'pending',
        'delivery':{'lane':'records','id':ticket}},
    });
    await db.recordOutboxCloudHandoff(row.reference,original,ticketId:ticket);
    await WindowsDriveDeliveryQueue.poll(school,call:(action,body) async => {
      'success':true,'schoolId':school,'cloudflareAccepted':true,
      'driveState':'verified','syncProtocol':2,'recordRevision':'',
    });
    expect((await row.reference.get()).data()?['syncState'],'cloudAccepted');
    expect((await WindowsDriveDeliveryQueue.history(school)).single['state'],'pending');
  });
  test('authorized document replay recovers local CAS before final provider settlement', () async {
    const id='restart-document';
    const op='document-restart-operation-001';
    final hash=List.filled(64,'a').join();
    final original=<String,dynamic>{'schoolId':school,'documentId':id,
      'documentRevision':op,'contentHash':hash,'localPath':'synthetic-local-path',
      'syncState':'pending'};
    final journal=<String,dynamic>{'source':List.filled(64,'b').join(),
      'schoolId':school,'profileId':db.activeProfileId,
      'action':'managed/document/stage/resumable','collection':'documents',
      'id':id,'originalOperationId':op,'operation':'write',
      'handoffAuthorized':true,'fileSha256':hash};
    final ticket=exactSidecarTicket(journal,school)!;
    final ref=db.collection('_windows_document_outbox').doc(id);
    final local=db.collection('_local_student_documents').doc(id);
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() async {
      await ref.set(original);await local.set(original);
    });
    await WindowsDriveDeliveryQueue.retainEdge({...journal,
      'proof':{'success':true,'schoolId':school,'edgeDeliveryVersion':1,
        'cloudflareAccepted':true,'driveState':'verified','committed':true,
        'fileId':'real-file','delivery':{'lane':'file-$ticket','id':ticket}}});
    final retained=(await db.collection(WindowsDriveDeliveryQueue.collection).get()).docs.single.data();
    expect(retained['state'],'pending');
    expect(retained['providerVerifiedAwaitingLocalCas'],true);
    expect(recoverableStagedDocumentJournal(original,retained,school,id),true);
    expect(recoverableStagedDocumentJournal({...original,'contentHash':'wrong'},retained,school,id),false);
    expect(recoverableStagedDocumentJournal({...original,'documentRevision':'replacement-generation'},retained,school,id),false);
    await WindowsDriveDeliveryQueue.poll(school,call:(action,body) async {
      expect(body['id'],ticket);
      return {'success':true,'schoolId':school,'cloudflareAccepted':true,
        'driveState':'verified','committed':true,'fileId':'real-file',
        'fileUrl':'https://drive.google.com/file/d/real-file/view',
        'documentRecord':{'id':id,'operationId':op,'fileId':'real-file',
          'recordRevision':'canonical-document-revision','contentHash':hash}};
    });
    expect((await ref.get()).exists,false);
    expect((await local.get()).data()?['syncState'],'Synced');
    expect((await local.get()).data()?['cloudRecordRevision'],'canonical-document-revision');
  });

  test('exact original portrait file and person record must BOTH verify before local ACK', () {
    const ticket='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const fileHash='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    const rawHash='cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
    final original={
      'schoolId':school,'collection':'students_directory',
      'documentId':'student-portrait-original','operationId':'photo-original-operation-00000001',
      'operation':'set','syncState':'cloudAccepted','atomicBundleId':null,
      'data':{'schoolId':school},'cloudTicketId':ticket,
      'cloudTicketLane':'file-$ticket',
      'cloudMediaSourceHash':rawHash,'cloudMediaFileSha256':fileHash,
    };
    final journal={'ticketId':ticket,'schoolId':school,
      'action':'managed/record/media/stage/resumable',
      'collection':'students_directory','id':'student-portrait-original',
      'originalOperationId':'photo-original-operation-00000001'};
    final proof={'success':true,'schoolId':school,'cloudflareAccepted':true,
      'driveState':'verified','committed':true,'fileId':'realDrivePhotoId',
      'sha256':fileHash,
      'mediaRecord':{'collection':'students_directory','id':'student-portrait-original',
        'operationId':'photo-original-operation-00000001',
        'fileId':'realDrivePhotoId','recordRevision':'real-revision-1',
        'sourceHash':rawHash,'fileSha256':fileHash}};
    expect(verifiedStagedPhotoRecordFinal(original,journal,proof,school),true);
    expect(verifiedStagedPhotoRecordFinal(original,journal,{
      ...proof,'fileId':'substituted-file',
    },school),false);
    expect(verifiedStagedPhotoRecordFinal({
      ...original,'cloudMediaSourceHash':'0'*64,
    },journal,proof,school),false);
    expect(verifiedStagedPhotoRecordFinal(original,journal,{
      ...proof,'mediaRecord':{...proof['mediaRecord'] as Map,
        'recordRevision':'cf-unverified'}
    },school),false);
    expect(verifiedStagedPhotoRecordFinal(original,journal,proof,other),false);
  });
  test('immutable original photo outbox is never cleared before exact file and record proof', () async {
    final raw='data:image/jpeg;base64,${base64Encode(utf8.encode('original portrait'))}';
    const op='photo-original-operation-00000001',docId='school-photo-person-01';
    const fileHash='dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
    final rawHash=sha256.convert(utf8.encode('original portrait')).toString();
    final original={
      'schoolId':school,'collection':'students_directory',
      'documentId':docId,'operation':'set','operationId':op,
      'baseCloudRevision':'','syncState':'pending',
      'data':{'schoolId':school,'studentId':docId,'photoUrl':raw},
    };
    final ref=db.collection('_windows_firebase_outbox').doc('photo-op-row');
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(
      ()=>ref.set(original));
    final live=(await ref.get()).data()!;
    final key=sha256.convert(utf8.encode(jsonEncode([
      school,'students_directory',docId,op,fileHash,
    ]))).toString();
    final ticket=sha256.convert(utf8.encode(jsonEncode([school,key]))).toString();
    await expectLater(db.recordOutboxCloudHandoff(ref,live,
      ticketId:ticket,lane:'file-$ticket',mediaSourceHash:'0'*64,
      mediaFileSha256:fileHash),throwsStateError);
    expect((await ref.get()).data()?['syncState'],'pending');
    await WindowsDriveDeliveryQueue.retainEdge({
      'source':'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
      'schoolId':school,'profileId':db.activeProfileId,
      'action':'managed/record/media/stage/resumable',
      'collection':'students_directory','id':docId,
      'operation':'write','originalOperationId':op,
      'handoffAuthorized':true,'fileSha256':fileHash,'mediaSourceHash':rawHash,
      'proof':{'success':true,'schoolId':school,'edgeDeliveryVersion':1,
        'cloudflareAccepted':true,'driveState':'pending',
        'delivery':{'lane':'file-$ticket','id':ticket}},
    });
    var resends=0;
    await WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,
      send:(_,__,___,____)async=>fail('Unexpected legacy send'),
      sendVersioned:(_)async{resends++;return 'unexpected';});
    expect(resends,0);
    expect((await ref.get()).data()?['syncState'],'cloudAccepted');
    expect((await ref.get()).data()?['cloudTicketLane'],'file-$ticket');
    var polls=0;
    await WindowsDriveDeliveryQueue.poll(school,call:(action,body)async{
      polls++;
      expect(action,'managed/cloudflare/operation');
      expect(body['lane'],'file-$ticket');
      return{'success':true,'schoolId':school,
        'cloudflareAccepted':true,'driveState':'verified',
        'committed':true,'fileId':'verifiedOriginalPhoto','sha256':fileHash,
        'mediaRecord':{'collection':'students_directory','id':docId,
          'operationId':op,'recordRevision':'google-record-revision-01',
          'fileId':'verifiedOriginalPhoto','sourceHash':rawHash,
          'fileSha256':fileHash}};
    });
    expect(polls,1);
    expect((await ref.get()).data(),isNull,
      reason:'only verified Google photo AND exact record retire local outbox');
  });
}

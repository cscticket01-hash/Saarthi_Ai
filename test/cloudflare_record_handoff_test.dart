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

  test('Delete Everywhere is Cloudflare-accepted immediately, but final ACK requires Drive and Firebase cleanup', () async {
    final original=<String,dynamic>{
      'schoolId':school,'collection':'teachers_directory','documentId':'teacher-delete',
      'operation':'delete','operationId':'original-delete-owner-2026111901',
      'baseCloudRevision':'real-prior-revision','syncState':'pending',
    };
    expect(eligibleForRecordHandoff(original,school,
      edgeDeliverySupported:true),true);
    expect(eligibleForRecordHandoff({...original,'baseCloudRevision':''},school,
      edgeDeliverySupported:true),false);
    expect(eligibleForRecordHandoff({...original,'priorDeletion':{'operation':'delete'}},
      school,edgeDeliverySupported:true),false);
    expect(eligibleForRecordHandoff({...original,'collection':'students_directory'},
      school,edgeDeliverySupported:true),false,
      reason:'Student delete requires a verified immutable generation');
    expect(eligibleForRecordHandoff({...original,'collection':'students_directory',
      'deletedStudentGeneration':'p-'+('a'*32)},school,edgeDeliverySupported:true),true);
    final ref=db.collection('_windows_firebase_outbox').doc('original-delete');
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(() => ref.set(original));
    final before=(await ref.get()).data()!;
    final ticket=exactTicket(original);
    expect(await db.recordOutboxCloudHandoff(ref,before,ticketId:ticket),true);
    final accepted=(await ref.get()).data()!;
    expect(accepted['syncState'],'cloudAccepted');
    expect(accepted['cloudTicketId'],ticket);
    expect(accepted['operationId'],original['operationId']);
    final journal={'ticketId':ticket,'schoolId':school,'action':'managed/records',
      'collection':original['collection'],'id':original['documentId'],
      'originalOperationId':original['operationId']};
    final record={'schoolId':school,'id':original['documentId'],
      '_syncDeleted':true,'_syncRevision':'new-signed-drive-revision',
      '_syncOperationId':original['operationId'],
      '_syncErasePlan':{'complete':true}};
    final proof={'success':true,'schoolId':school,
      'cloudflareAccepted':true,'driveState':'verified',
      'syncProtocol':2,'recordRevision':'new-signed-drive-revision',
      'deleteEverywhereVersion':1,'driveDeletionComplete':true,
      'firebaseDeletionComplete':true,'record':record};
    expect(verifiedStagedRecordFinal(accepted,journal,proof,school),true);
    expect(verifiedStagedRecordFinal(accepted,journal,{
      ...proof,'firebaseDeletionComplete':false},school),false);
    expect(verifiedStagedRecordFinal(accepted,journal,{
      ...proof,'driveDeletionComplete':false},school),false);
    expect(verifiedStagedRecordFinal(accepted,journal,{
      ...proof,'record':{...record,'_syncErasePlan':{'complete':false}}},school),false);
    expect(verifiedStagedRecordFinal(accepted,journal,{
      ...proof,'record':{...record,'_syncOperationId':'different-delete-id'}},school),false);
    expect(verifiedStagedRecordFinal(accepted,journal,proof,other),false);
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
      'proof':{'success':true,'schoolId':school,'edgeDeliveryVersion':1,
        'cloudflareAccepted':true,'driveState':'pending',
        'delivery':{'lane':'file-$ticket','id':ticket}},
    });
    final bound=await db.recordOutboxCloudHandoff(ref,live,
      ticketId:ticket,lane:'file-$ticket',
      mediaSourceHash:rawHash,mediaFileSha256:fileHash);
    expect(bound,true);
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

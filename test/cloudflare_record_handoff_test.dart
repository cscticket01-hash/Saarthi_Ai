import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../lib/cloudflare_record_handoff.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_drive_delivery_queue.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';

const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const other='vs-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const ticket='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db=FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile('staged-test-${DateTime.now().microsecondsSinceEpoch}',
      identity:{'schoolSyncId':school});
  });

  test('canary is explicitly disabled for real schools, documents, deletes and fees', () {
    final row={'schoolId':school,'collection':'school_calendar',
      'documentId':'event-1','operation':'set','operationId':'original-op-1234567890',
      'baseCloudRevision':'','data':{'syntheticTest':true}};
    expect(eligibleForRecordHandoff(row,school),false);
    expect(eligibleForRecordHandoff(row,school,enabledTestSchool:school),true);
    expect(eligibleForRecordHandoff(row,school,enabledTestSchool:other),false);
    for(final collection in ['students_directory','documents','fee_payments']) {
      expect(eligibleForRecordHandoff({...row,'collection':collection},school,
        enabledTestSchool:school),false);
    }
    expect(eligibleForRecordHandoff({...row,'operation':'delete'},school,
      enabledTestSchool:school),false);
    expect(eligibleForRecordHandoff({...row,'data':{'syntheticTest':false}},school,
      enabledTestSchool:school),false);
  });

  test('a real student outbox cannot be silently made cloud-owned by a stray receipt', () async {
    await db.collection('students_directory').doc('real-student')
      .set({'schoolId':school,'name':'Real school record'});
    final row=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    final before=row.data();
    await expectLater(db.recordOutboxCloudHandoff(
      row.reference,before,ticketId:ticket),throwsStateError);
    final after=(await row.reference.get()).data()!;
    expect(after['syncState'],before['syncState']);
    expect(after['operationId'],before['operationId']);
    expect(after['baseCloudRevision'],before['baseCloudRevision']);
    expect(after['data'],before['data']);
    expect((after['queuedAt'] as Timestamp).millisecondsSinceEpoch,
      (before['queuedAt'] as Timestamp).millisecondsSinceEpoch);
  });
  test('original CAS is retained at Cloudflare acceptance; only broker Drive proof retires it', () async {
    await db.collection('school_calendar').doc('event-1')
      .set({'schoolId':school,'syntheticTest':true,'title':'Synthetic test'});
    final row=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    final original=row.data();
    expect(original['operationId'],isA<String>());

    await WindowsDriveDeliveryQueue.retainEdge({
      'source':'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      'schoolId':school,'profileId':db.activeProfileId,
      'action':'managed/records','collection':'school_calendar','id':'event-1',
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
          school:school,collection:'school_calendar',id:'event-1',
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
        'record':{'schoolId':school,'id':'event-1',
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
}

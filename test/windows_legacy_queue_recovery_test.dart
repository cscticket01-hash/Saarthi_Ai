import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/platform/platform_config.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_pending_school_sync.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_sync_comparison.dart';
import '../lib/windows_sync_conflict_review.dart';
import '../lib/windows_sync_projection.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final db=FirebaseFirestore.instance;
  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key:jsonEncode({
      'managed':true,'schoolId':school,'uid':'synthetic-recovery','folderId':'managed',
      'projectId':platformProjectId,'firebaseRefreshToken':'synthetic',
      'endpoint':'https://unreachable.example/school-cloud',
    })});
    await WindowsRuntimeFlags.setLocalStorageEnabled(false);
    await db.switchProfile('legacy-${DateTime.now().microsecondsSinceEpoch}',
      identity:{'schoolId':school,'schoolSyncId':school});
  });
  Future<QueryDocumentSnapshot<Map<String,dynamic>>> legacy({String? category}) async {
    await db.collection('students_directory').doc('Class 11_Roll_5').set({
      'name':'Synthetic student','mobileStableId':'p-${'a'*32}','parentContact':'9876543210',
    });
    final row=(await db.collection('_windows_firebase_outbox').get()).docs.single;
    await row.reference.update({'syncState':'needsAttention','lastError':'Original retained legacy failure',
      if(category!=null)'failureCategory':category});
    return (await db.collection('_windows_firebase_outbox').get()).docs.single;
  }
  Future<void> flush(Future<String> Function(Map<String,dynamic>) send,{bool diagnose=false}) =>
    WindowsPendingSchoolSync.flush(profileId:db.activeProfileId,send:(a,b,c,d)async{},
      sendVersioned:send,diagnoseUnclassified:diagnose);

  test('manual diagnosis sends exact original request; ordinary sync leaves unknown row retained', () async {
    final row=await legacy(), original=(await db.collection('_windows_firebase_outbox').get()).docs.single.data();
    await flush((_)async=>throw StateError('Background must not send'));
    expect(migrationJsonValue((await row.reference.get()).data()),migrationJsonValue(original));
    await flush((item)async {
      expect(migrationJsonValue(item),migrationJsonValue(original));
      expect(item['baseCloudRevision'],'');
      return 'verified-server-ack';
    },diagnose:true);
    expect((await row.reference.get()).exists,false);
    expect((await db.collection('_windows_sync_receipts').get()).docs.single.data()['operationId'],original['operationId']);
  });
  for(final example in [
    [409,'RECORD_REVISION_CONFLICT','conflict'],
    [403,'SCRIPT_PERMISSION_DENIED','needsAttention'],
    [502,'SCRIPT_LEGACY_RECORD_REVIEW_REQUIRED','needsAttention'],
  ]) {
    test('legacy diagnosis retains data and exact code for ${example[1]}', () async {
      final row=await legacy(), original=row.data();
      try {
        await flush((_)async=>throw CentralCloudException(example[0] as int,'school_cloud','private response',
          diagnosticCode:example[1] as String),diagnose:true);
      } catch(_) {}
      final retained=(await row.reference.get()).data()!;
      expect(retained['operationId'],original['operationId']);
      expect(retained['baseCloudRevision'],original['baseCloudRevision']);
      expect(retained['data'],original['data']);
      expect(retained['syncState'],example[2]);
      expect(retained['failureCode'],example[1]);
      expect(retained['failureHttpStatus'],example[0]);
      expect(retained['retryCount'],1);
      expect(documentFailureExplanation(retained),isNot(contains('private response')));
      expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty);
    });
  }
  test('manual diagnosis still respects known authorization and invalid operation identity', () async {
    final row=await legacy(category:'authorization');
    await flush((_)async=>throw StateError('Known authorization cannot auto-retry'),diagnose:true);
    expect((await row.reference.get()).data()?['failureCategory'],'authorization');
    await row.reference.update({'failureCategory':FieldValue.delete(),'operationId':'invalid'});
    await flush((_)async=>throw StateError('Invalid original identity cannot send'),diagnose:true);
    expect((await row.reference.get()).data()?['operationId'],'invalid');
    await row.reference.update({'operationId':'synthetic-operation-123','operation':'update'});
    await flush((_)async=>throw StateError('An old partial update cannot be replayed as a full write'),diagnose:true);
    expect((await row.reference.get()).data()?['syncState'],'needsAttention');
  });
  test('late diagnostic response cannot replace a newer local Save', () async {
    final row=await legacy();
    final original=row.data();
    try {
      await flush((_)async {
        await db.collection('students_directory').doc('Class 11_Roll_5').update({'name':'New local edit'});
        throw CentralCloudException(409,'school_cloud','conflict',diagnosticCode:'RECORD_REVISION_CONFLICT');
      },diagnose:true);
    } catch(_) {}
    final current=(await row.reference.get()).data()!;
    expect(current['operationId'],isNot(original['operationId']));
    expect(current['data']['name'],'New local edit');
    expect(current['failureCode'],isNull);
    expect((await db.collection('_windows_sync_receipts').get()).docs,isEmpty);
  });
  test('same record binds missing payload school ID and normalizes exact timestamp envelopes', () {
    final time=DateTime.utc(2026,10,25,10,16,54,550);
    final queued={'schoolId':school,'collection':'teachers_directory','operation':'set',
      'data':{'teacherId':'T1','name':'Same','schedule':{'Monday':Timestamp.fromDate(time)}}};
    final cloud={'schoolId':school,'id':'T1','teacherId':'T1','name':'Same',
      'schedule':{'Monday':{'__vsTimestamp':time.toIso8601String()}},
      'updatedAt':{'__vsTimestamp':'2026-10-25T11:00:00.000Z'},'_syncRevision':'verified'};
    expect(compareSyncVersions(queued,cloud),'identical');
    expect(recordDifferenceFields(queued,cloud),isEmpty);
    expect(compareSyncVersions({...queued,'data':{...(queued['data'] as Map),'schoolId':'foreign'}},cloud),'differs');
    expect(compareSyncVersions(queued,{...cloud,'teacherId':'T2'}),isNot('identical'));
    expect(recordDifferenceFields(queued,{...cloud,'name':'Changed'}),['name']);
    expect(syncPayloadHash({'paidAt':time}),syncPayloadHash({'paidAt':Timestamp.fromDate(time)}));
    expect(syncPayloadHash({'paidAt':time}),isNot(syncPayloadHash({'paidAt':time.add(const Duration(days:1))})));
    expect(syncPayloadHash({'paidAt':{'__vsTimestamp':time.toIso8601String(),'extra':true}}),
      isNot(syncPayloadHash({'paidAt':time})));
    expect(syncPayloadHash({'paidAt':{'__vsTimestamp':'invalid'}}),
      isNot(syncPayloadHash({'paidAt':time})));
  });
  testWidgets('real conflict review recognizes missing payload school ID and names actual changed fields', (tester) async {
    final item=<String,dynamic>{'id':'review','documentId':'review','collection':'teachers_directory',
      'schoolId':school,'syncState':'conflict','operation':'set','operationId':'synthetic-operation-123',
      '_queueCollection':'_windows_firebase_outbox','data':{'teacherId':'T1','name':'Same'}};
    Future<void> open(String cloudName) async {
      await tester.pumpWidget(MaterialApp(home:Builder(builder:(context)=>Scaffold(body:
        TextButton(onPressed:()=>showWindowsConflictReview(context,item,queueReader:(_,__)async=>item,
          cloudReader:(_)async=>{'schoolId':school,'syncProtocol':2,'records':{'review':{
            'schoolId':school,'teacherId':'T1','name':cloudName,'_syncRevision':'verified'}}}),
          child:const Text('Open'))))));
      await tester.tap(find.text('Open'));await tester.pumpAndSettle();
      await tester.tap(find.text('Verify cloud version'));await tester.pumpAndSettle();
    }
    await open('Same');
    expect(find.textContaining('Cloud verification: identical.'),findsOneWidget);
    expect(find.text('Record already synced'),findsOneWidget);
    await tester.tap(find.text('Close'));await tester.pumpAndSettle();
    await open('Different');
    expect(find.text('Differing fields: name'),findsOneWidget);
    expect(find.text('Record already synced'),findsNothing);
    expect(tester.takeException(),isNull);
    await tester.pumpWidget(const SizedBox());
  });
}

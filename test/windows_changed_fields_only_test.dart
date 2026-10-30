import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../lib/platform/platform_config.dart';
import '../lib/windows_connect/central_school_cloud.dart';
import '../lib/windows_local_firestore.dart';
import '../lib/windows_runtime_flags.dart';
import '../lib/windows_firebase_sync.dart';
import '../lib/windows_sync_recovery.dart';
import '../lib/windows_record_change_policy.dart';
import '../lib/windows_document_templates.dart';
import '../lib/windows_student_id_cards.dart';
import '../lib/windows_sync_dependencies.dart';
import '../lib/windows_backend_bridge.dart';
import '../lib/school_qr_link.dart';

void main(){
  TestWidgetsFlutterBinding.ensureInitialized();
  const school='vs-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  const endpoint='https://saarthi-oauth-staging.onrender.com/school-cloud';
  final db=FirebaseFirestore.instance;
  Map<String,dynamic> person(String revision)=>{'id':'S1','schoolId':school,'name':'Ananya',
    'mobileStableId':'p-${sha256.convert(utf8.encode('c'*32))}','mobileLinkToken':'c'*32,'mobileIdentityVersion':1,
    'teacherId':'teacher-1','class':'4','rollNo':'2','parentContact':'9999999999','salary':100,
    '_syncRevision':revision,'_syncOperationId':'cloud-operation-$revision'};
  String qr(String role)=>SchoolLink.encodeCompact({'app':'VIDYA_SAARTHI','v':2,'managed':true,
    'schoolId':school,'centralEndpoint':endpoint,'firebaseProjectId':platformProjectId,
    'type':role,'personId':'S1','linkToken':'c'*32});
  Future<QueryDocumentSnapshot<Map<String,dynamic>>> queued()async=>(await db.collection('_windows_firebase_outbox').get()).docs.single;
  setUp(()async{
    FlutterSecureStorage.setMockInitialValues({});
    await WindowsRuntimeFlags.setLocalStorageEnabled(true);
    final dir=await Directory.systemTemp.createTemp('changed-fields-only-');
    await db.changeLocalStorageLocation(dir.path);
    await db.switchProfile('delta-${DateTime.now().microsecondsSinceEpoch}',identity:{'schoolId':school,'schoolSyncId':school});
    WindowsFirebaseRemote.recordFieldPatchSupported=true;
    WindowsFirebaseRemote.recordPointReadSupported=true;
  });
  tearDown(()async{WindowsFirebaseRemote.recordFieldPatchSupported=false;WindowsFirebaseRemote.recordPointReadSupported=false;await db.resetVolatileSession();});
  for(final collection in ['students_directory','teachers_directory']) {
    test('$collection sends only photo through media preparation and frozen wire',()async{
      final ref=db.collection(collection).doc('S1');await db.applySyncedDocument(ref,person('r1'));
      await ref.update({'photoUrl':'data:image/png;base64,AQID'});
      final q=await queued();var preparations=0;
      final prepared=await WindowsFirebaseRemote.prepareQueuedRecord(q.reference,q.data(),school,prepareData:(data)async{
        preparations++;expect(data.keys,['photoUrl']);
        return {'schoolId':school,'photoUrl':'https://drive.google.com/file/d/new-photo/view','photoFileId':'new-photo','photoSourceHash':'abc'};
      });
      expect(preparations,1);expect(prepared!['wireMode'],'fieldPatch1');
      expect((prepared['wireData']['_syncFieldPatch']['set'] as Map).keys,unorderedEquals(['photoUrl','photoFileId','photoSourceHash']));
      expect(prepared['operationId'],q.data()['operationId']);expect(prepared['baseCloudRevision'],'r1');
    });
  }
  test('missing baseline record recovers from original local revision across multiple offline edits',()async{
    final ref=db.collection('students_directory').doc('S1');await db.applySyncedDocument(ref,person('r1'));
    final key=base64Url.encode(utf8.encode(r'students_directory\nS1')).replaceAll('=','');
    await db.collection('_windows_sync_baselines').doc(key).delete();
    await ref.update({'name':'Corrected'});await ref.update({'salary':200});
    final item=(await queued()).data();
    expect(item['baseCloudRevision'],'r1');expect(item['fieldPatchBase']['name'],'Ananya');
    expect((item['fieldPatch']['set'] as Map).keys,unorderedEquals(['name','salary']));
  });
  test('old unbound edit reconstructs a delta only from the matching authenticated revision',()async{
    final ref=db.collection('teachers_directory').doc('S1');await db.applySyncedDocument(ref,person('r1'));
    await ref.update({'name':'Corrected'});final q=await queued();await q.reference.update({'fieldPatch':FieldValue.delete()});
    final item=(await q.reference.get()).data()!;
    final prepared=await WindowsFirebaseRemote.prepareQueuedRecord(q.reference,item,school,
      readRecord:(_,__)async=>{'schoolId':school,'syncProtocol':2,'pointRead':true,'records':{'S1':person('r1')}},
      prepareData:(data)async{expect(data.keys,['name']);return {'schoolId':school,...data};});
    expect(prepared!['wireMode'],'fieldPatch1');expect(prepared['operationId'],item['operationId']);
  });
  test('unsupported patch capability never converts a registered edit into snapshot upload',()async{
    final ref=db.collection('teachers_directory').doc('S1');await db.applySyncedDocument(ref,person('r1'));
    await ref.update({'name':'Corrected'});final q=await queued();WindowsFirebaseRemote.recordFieldPatchSupported=false;
    await expectLater(WindowsFirebaseRemote.prepareQueuedRecord(q.reference,q.data(),school,
      prepareData:(_)async=>fail('No full-record/media preparation allowed')),throwsA(isA<FieldDeltaUnavailable>()));
    expect((await q.reference.get()).data()?['wireData'],isNull);
  });
  test('edits after verified recreation are deltas, while a fresh generation retains lifecycle protection',(){
    final base={...person('r1'),'replacesStudentGeneration':'old-person','_syncRecreatesDeletedRevision':'old-delete'};
    expect(buildRecordFieldPatch('students_directory',base,{...base,'name':'Corrected'})?['set'],{'name':'Corrected'});
    expect(buildRecordFieldPatch('students_directory',base,{...base,'replacesStudentGeneration':'different'}),isNull);
  });
  for(final role in ['student','teacher']) {
    test('$role card identity ignores salary and unused profile data but follows visible fields',()async{
      final profile={'schoolName':'School','address':'Main Road','license':'one','gpsRadius':50};
      final base=person('r1');final design=role=='student'?studentIdTemplateId:0;
      final first=await WindowsDocumentTemplates.inputRevisions(base,profile,design,qr(role));
      final unrelated=await WindowsDocumentTemplates.inputRevisions({...base,'salary':200},
        {...profile,'license':'two','gpsRadius':100},design,qr(role));
      expect(first.visual,unrelated.visual);expect(first.legacy,isNot(unrelated.legacy));
      final changed=await WindowsDocumentTemplates.inputRevisions({...base,'name':'New name'},profile,design,qr(role));
      expect(first.visual,isNot(changed.visual));
      final photo=await WindowsDocumentTemplates.inputRevisions({...base,'photoUrl':'data:image/png;base64,AQID'},profile,design,qr(role));
      expect(first.visual,isNot(photo.visual));
    });
  }
  test('legacy published card survives a nonvisual edit without rendering, uploading, or changing registration',()async{
    FlutterSecureStorage.setMockInitialValues({CentralSchoolCloud.key:jsonEncode({'managed':true,'schoolId':school,
      'uid':'owner','projectId':platformProjectId,'endpoint':endpoint})});
    final before=person('r1'),after={...person('r2'),'salary':200};
    final profile={'schoolName':'School','address':'Main Road'};
    await WindowsLocalFirestoreSyncControl.runWithoutSyncTracking(()async{
      await db.collection('school_config').doc('school_profile_cache').set(profile);
      await db.applySyncedDocument(db.collection('students_directory').doc('S1'),after);
    });
    final old=await WindowsDocumentTemplates.inputRevisions(before,profile,studentIdTemplateId,qr('student'));
    final id=WindowsBackendBridge.publishedIdCardOwnerIdForPerson('student','S1',before);
    await db.collection('_local_student_documents').doc(id).set({'schoolId':school,'studentId':'S1',
      'personId':before['mobileStableId'],'ownerRole':'student','documentKind':'idCard','inputRevision':old.legacy,'syncState':'Synced'});
    await WindowsSyncDependencies.retain(school,'students_directory','S1','r2',previousRecord:before);
    await WindowsDocumentTemplates.publishChangedIdCards(affectedPeople:{'studentId':{'S1'}},
      readInventory:()async=>fail('No cloud/PDF publication for unchanged visible content'));
    final retained=(await db.collection('_local_student_documents').doc(id).get()).data()!;
    expect(retained['inputRevision'],old.legacy);expect(retained['visualInputRevision'],old.visual);
    expect((await db.collection('_windows_document_outbox').get()).docs,isEmpty);
    expect((await db.collection('_windows_firebase_outbox').get()).docs,isEmpty);
    expect((await db.collection('students_directory').doc('S1').get()).data()?['mobileLinkToken'],before['mobileLinkToken']);
  });
}
